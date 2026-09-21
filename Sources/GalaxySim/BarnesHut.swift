import Metal
import simd
import Foundation

/// GPU Barnes-Hut solver built on a Karras linear BVH.
///
/// Every stage runs on the device — bounding box, Morton quantisation, a
/// stable LSD radix sort, the Karras hierarchy, the bottom-up mass/CoM/AABB
/// pass and the traversal. The CPU does nothing per frame beyond encoding
/// the ~70 dispatches below; in particular the Morton sort is a real GPU
/// radix sort, not a `sorted()` call on the host.
///
/// The particle buffer is never permuted: the sort orders an index array,
/// so pointers the caller holds into `particles` and other passes that
/// index it directly stay valid.
///
/// Accuracy (measured against an exact double-precision O(N^2) sum; median
/// relative acceleration error, uniform cube):
///     theta   0.7      0.5      0.3      0.1      0.0
///     N=1e4   1.2e-2   5.6e-3   1.7e-3   1.0e-4   1.4e-6
///     N=5e5   5.5e-3   2.0e-3   5.5e-4    -        -
/// theta = 0 (full traversal to the leaves) reproduces the direct sum to
/// float round-off, which is what pins down that the hierarchy is correct.
///
/// Contract of `encode` matches `accelKickDirect`:
///     velocity.xyz += acceleration * params.dt
///     velocity.w    = clamp(velocity.w - starburstDecay * dt, 0, 1)
final class BarnesHutSolver {

    // These must match the #defines at the top of BarnesHut.metal.
    private static let radixBits  = 5
    private static let radix      = 32
    private static let sortTG     = 128
    private static let sortTile   = 1024      // sortTG * 8
    private static let scanTG     = 128
    private static let scanTile   = 1024      // scanTG * 8
    private static let bboxTG     = 256
    /// 30 bits of coarse Morton code (10 per axis, as specified) plus a
    /// 30-bit refinement used as the tie-break — see `bhMorton`/`bhDelta`.
    private static let mortonBits = 30
    private static var passesPerKey: Int { mortonBits / radixBits }  // 6
    private static var sortPasses: Int { 2 * passesPerKey }          // 12

    /// Mirrors `BHUniforms` in BarnesHut.metal. All fields 4 bytes.
    private struct BHUniforms {
        var count: UInt32 = 0
        var shift: UInt32 = 0
        var numBlocks: UInt32 = 0
        var scanCount: UInt32 = 0
        var theta2: Float = 0.25
        var digitFromHi: UInt32 = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    private let ctx: MetalContext

    private let pReset: MTLComputePipelineState
    private let pBBox: MTLComputePipelineState
    private let pMorton: MTLComputePipelineState
    private let pHist: MTLComputePipelineState
    private let pScanBlocks: MTLComputePipelineState
    private let pScanAdd: MTLComputePipelineState
    private let pScatter: MTLComputePipelineState
    private let pInitLeaves: MTLComputePipelineState
    private let pBuild: MTLComputePipelineState
    private let pBottomUp: MTLComputePipelineState
    private let pLinkEscape: MTLComputePipelineState
    private let pTraverse: MTLComputePipelineState

    // MARK: Device storage

    private var capacity: Int = 0

    private var bboxBuf: MTLBuffer!
    private var hiA: MTLBuffer!
    private var hiB: MTLBuffer!
    private var loA: MTLBuffer!
    private var loB: MTLBuffer!
    private var valsA: MTLBuffer!
    private var valsB: MTLBuffer!
    private var histBuf: MTLBuffer!
    /// Block-sum buffers, one per level of the hierarchical scan.
    private var scanLevels: [MTLBuffer] = []
    private var scanLevelCounts: [Int] = []

    /// Packed 32-byte nodes (see `BHNode` in BarnesHut.metal).
    private var nodeBuf: MTLBuffer!
    /// AABBs, needed only while building; kept out of `nodeBuf` so a
    /// traversal step stays a single 32-byte fetch.
    private var nodeMin: MTLBuffer!
    private var nodeMax: MTLBuffer!
    private var nodeParent: MTLBuffer!
    private var nodeFlags: MTLBuffer!
    /// Right children, build-only: the traversal follows escape pointers,
    /// so it never needs them.
    private var childB: MTLBuffer!

    // MARK: Init

    init(ctx: MetalContext) throws {
        self.ctx = ctx
        pReset      = try ctx.computePipeline("bhReset")
        pBBox       = try ctx.computePipeline("bhBBox")
        pMorton     = try ctx.computePipeline("bhMorton")
        pHist       = try ctx.computePipeline("bhRadixHist")
        pScanBlocks = try ctx.computePipeline("bhScanBlocks")
        pScanAdd    = try ctx.computePipeline("bhScanAdd")
        pScatter    = try ctx.computePipeline("bhRadixScatter")
        pInitLeaves = try ctx.computePipeline("bhInitLeaves")
        pBuild      = try ctx.computePipeline("bhBuildInternal")
        pBottomUp   = try ctx.computePipeline("bhBottomUp")
        pLinkEscape = try ctx.computePipeline("bhLinkEscape")
        pTraverse   = try ctx.computePipeline("accelKickBarnesHut")
    }

    // MARK: Sizing

    /// Allocate/resize internal buffers for `count` particles. Idempotent —
    /// calling it again with the same count is a no-op.
    func resize(count: Int) {
        guard count != capacity else { return }
        guard count > 0 else {
            capacity = 0
            bboxBuf = nil; hiA = nil; hiB = nil; loA = nil; loB = nil
            valsA = nil; valsB = nil
            histBuf = nil; scanLevels = []; scanLevelCounts = []
            nodeBuf = nil; nodeMin = nil; nodeMax = nil
            nodeParent = nil; nodeFlags = nil; childB = nil
            return
        }

        let dev = ctx.device
        let opts: MTLResourceOptions = .storageModePrivate

        func alloc(_ bytes: Int, _ label: String) -> MTLBuffer {
            let b = dev.makeBuffer(length: max(bytes, 16), options: opts)!
            b.label = "bh.\(label)"
            return b
        }

        let n = count
        let nodes = 2 * n - 1                       // n leaves + n-1 internal
        let internalNodes = max(n - 1, 1)
        let sortBlocks = (n + Self.sortTile - 1) / Self.sortTile
        let histCount = Self.radix * sortBlocks

        // shared so the harness/debug paths can inspect the box cheaply;
        // it is 24 bytes, the coherency cost is nil.
        bboxBuf = dev.makeBuffer(length: 6 * 4, options: .storageModeShared)!
        bboxBuf.label = "bh.bbox"

        hiA = alloc(n * 4, "keysHiA")
        hiB = alloc(n * 4, "keysHiB")
        loA = alloc(n * 4, "keysLoA")
        loB = alloc(n * 4, "keysLoB")
        valsA = alloc(n * 4, "valsA")
        valsB = alloc(n * 4, "valsB")
        histBuf = alloc(histCount * 4, "hist")

        // Hierarchical scan: level k holds the block sums of level k-1.
        scanLevels = []
        scanLevelCounts = []
        var c = histCount
        while true {
            let blocks = (c + Self.scanTile - 1) / Self.scanTile
            scanLevelCounts.append(blocks)
            scanLevels.append(alloc(blocks * 4, "scanL\(scanLevelCounts.count - 1)"))
            if blocks <= 1 { break }
            c = blocks
        }

        nodeBuf    = alloc(nodes * 32, "nodes")
        nodeMin    = alloc(nodes * 16, "nodeMin")
        nodeMax    = alloc(nodes * 16, "nodeMax")
        nodeParent = alloc(nodes * 4, "nodeParent")
        nodeFlags  = alloc(internalNodes * 4, "nodeFlags")
        childB     = alloc(internalNodes * 4, "childB")

        capacity = n
    }

    // MARK: Encoding

    /// Encode tree build + traversal + velocity kick into `cb`.
    func encode(commandBuffer cb: MTLCommandBuffer,
                particles: MTLBuffer,
                count: Int,
                params: SimParams,
                theta: Float)
    {
        guard count > 0 else { return }
        if capacity != count { resize(count: count) }
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "barnes-hut"

        var prm = params
        prm.particleCount = UInt32(count)

        var u = BHUniforms()
        u.count = UInt32(count)
        u.theta2 = max(theta, 0) * max(theta, 0)

        let sortBlocks = (count + Self.sortTile - 1) / Self.sortTile
        u.numBlocks = UInt32(sortBlocks)

        func groups(_ total: Int, _ tg: Int) -> MTLSize {
            MTLSize(width: (total + tg - 1) / tg, height: 1, depth: 1)
        }
        func tgSize(_ w: Int) -> MTLSize { MTLSize(width: w, height: 1, depth: 1) }

        // ---- 1. bounding box --------------------------------------------
        enc.setComputePipelineState(pReset)
        enc.setBuffer(bboxBuf, offset: 0, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: tgSize(8))

        enc.setComputePipelineState(pBBox)
        enc.setBuffer(particles, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 1)
        enc.setBuffer(bboxBuf, offset: 0, index: 2)
        enc.dispatchThreadgroups(groups(count, Self.bboxTG),
                                 threadsPerThreadgroup: tgSize(Self.bboxTG))

        // ---- 2. Morton codes + identity payload -------------------------
        enc.setComputePipelineState(pMorton)
        enc.setBuffer(particles, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 1)
        enc.setBuffer(bboxBuf, offset: 0, index: 2)
        enc.setBuffer(hiA, offset: 0, index: 3)
        enc.setBuffer(loA, offset: 0, index: 4)
        enc.setBuffer(valsA, offset: 0, index: 5)
        enc.dispatchThreadgroups(groups(count, 256), threadsPerThreadgroup: tgSize(256))

        // ---- 3. radix sort ----------------------------------------------
        // LSD: least-significant key first, so the refinement half is sorted
        // before the coarse Morton half. Both halves and the payload index
        // are permuted together on every pass.
        var srcHi = hiA!, dstHi = hiB!
        var srcLo = loA!, dstLo = loB!
        var srcVals = valsA!, dstVals = valsB!
        let histCount = Self.radix * sortBlocks

        for pass in 0..<Self.sortPasses {
            let fromHi = pass >= Self.passesPerKey
            u.digitFromHi = fromHi ? 1 : 0
            u.shift = UInt32((pass % Self.passesPerKey) * Self.radixBits)

            enc.setComputePipelineState(pHist)
            enc.setBuffer(fromHi ? srcHi : srcLo, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 1)
            enc.setBuffer(histBuf, offset: 0, index: 2)
            enc.dispatchThreadgroups(MTLSize(width: sortBlocks, height: 1, depth: 1),
                                     threadsPerThreadgroup: tgSize(Self.sortTG))

            encodeScan(enc, data: histBuf, count: histCount, level: 0, uniforms: &u)

            enc.setComputePipelineState(pScatter)
            enc.setBuffer(srcHi, offset: 0, index: 0)
            enc.setBuffer(srcLo, offset: 0, index: 1)
            enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 2)
            enc.setBuffer(histBuf, offset: 0, index: 3)
            enc.setBuffer(dstHi, offset: 0, index: 4)
            enc.setBuffer(dstLo, offset: 0, index: 5)
            enc.setBuffer(srcVals, offset: 0, index: 6)
            enc.setBuffer(dstVals, offset: 0, index: 7)
            enc.dispatchThreadgroups(MTLSize(width: sortBlocks, height: 1, depth: 1),
                                     threadsPerThreadgroup: tgSize(Self.sortTG))

            swap(&srcHi, &dstHi)
            swap(&srcLo, &dstLo)
            swap(&srcVals, &dstVals)
        }
        // after an even number of passes the sorted data is back in the A set
        let sortedHi  = srcHi
        let sortedLo  = srcLo
        let sortedIdx = srcVals

        // ---- 4. leaves --------------------------------------------------
        u.shift = 0
        enc.setComputePipelineState(pInitLeaves)
        enc.setBuffer(particles, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 1)
        enc.setBuffer(sortedIdx, offset: 0, index: 2)
        enc.setBuffer(nodeBuf, offset: 0, index: 3)
        enc.setBuffer(nodeMin, offset: 0, index: 4)
        enc.setBuffer(nodeMax, offset: 0, index: 5)
        enc.setBuffer(nodeFlags, offset: 0, index: 6)
        enc.setBuffer(nodeParent, offset: 0, index: 7)
        enc.dispatchThreadgroups(groups(count, 256), threadsPerThreadgroup: tgSize(256))

        // ---- 5. Karras hierarchy ----------------------------------------
        if count > 1 {
            enc.setComputePipelineState(pBuild)
            enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 0)
            enc.setBuffer(sortedHi, offset: 0, index: 1)
            enc.setBuffer(sortedLo, offset: 0, index: 2)
            enc.setBuffer(nodeBuf, offset: 0, index: 3)
            enc.setBuffer(nodeParent, offset: 0, index: 4)
            enc.setBuffer(childB, offset: 0, index: 5)
            enc.dispatchThreadgroups(groups(count - 1, 256), threadsPerThreadgroup: tgSize(256))

            // ---- 6. bottom-up mass / CoM / AABB -------------------------
            enc.setComputePipelineState(pBottomUp)
            enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 0)
            enc.setBuffer(nodeParent, offset: 0, index: 1)
            enc.setBuffer(nodeBuf, offset: 0, index: 2)
            enc.setBuffer(nodeMin, offset: 0, index: 3)
            enc.setBuffer(nodeMax, offset: 0, index: 4)
            enc.setBuffer(nodeFlags, offset: 0, index: 5)
            enc.setBuffer(childB, offset: 0, index: 6)
            enc.dispatchThreadgroups(groups(count, 256), threadsPerThreadgroup: tgSize(256))

            // ---- 6b. escape pointers for the stackless traversal --------
            enc.setComputePipelineState(pLinkEscape)
            enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 0)
            enc.setBuffer(nodeBuf, offset: 0, index: 1)
            enc.setBuffer(nodeParent, offset: 0, index: 2)
            enc.setBuffer(childB, offset: 0, index: 3)
            enc.dispatchThreadgroups(groups(2 * count - 1, 256), threadsPerThreadgroup: tgSize(256))
        }

        // ---- 7. traverse + kick -----------------------------------------
        enc.setComputePipelineState(pTraverse)
        enc.setBuffer(particles, offset: 0, index: 0)
        enc.setBytes(&prm, length: MemoryLayout<SimParams>.stride, index: 1)
        enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 2)
        enc.setBuffer(nodeBuf, offset: 0, index: 3)
        enc.setBuffer(sortedIdx, offset: 0, index: 4)
        enc.dispatchThreadgroups(groups(count, 128), threadsPerThreadgroup: tgSize(128))

        enc.endEncoding()
    }

    /// In-place hierarchical exclusive scan. Safe in place: each tile is
    /// staged in threadgroup memory before anything is written back.
    private func encodeScan(_ enc: MTLComputeCommandEncoder,
                            data: MTLBuffer,
                            count: Int,
                            level: Int,
                            uniforms u: inout BHUniforms)
    {
        let blocks = (count + Self.scanTile - 1) / Self.scanTile
        let sums = scanLevels[level]

        u.scanCount = UInt32(count)
        enc.setComputePipelineState(pScanBlocks)
        enc.setBuffer(data, offset: 0, index: 0)
        enc.setBuffer(data, offset: 0, index: 1)
        enc.setBuffer(sums, offset: 0, index: 2)
        enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 3)
        enc.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: Self.scanTG, height: 1, depth: 1))

        guard blocks > 1 else { return }

        encodeScan(enc, data: sums, count: blocks, level: level + 1, uniforms: &u)

        u.scanCount = UInt32(count)
        enc.setComputePipelineState(pScanAdd)
        enc.setBuffer(data, offset: 0, index: 0)
        enc.setBuffer(sums, offset: 0, index: 1)
        enc.setBytes(&u, length: MemoryLayout<BHUniforms>.stride, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: Self.scanTG, height: 1, depth: 1))
    }
}
