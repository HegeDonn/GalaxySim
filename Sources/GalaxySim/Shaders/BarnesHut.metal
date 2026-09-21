// ===================================================================
//  Barnes-Hut on the GPU, as a Karras linear BVH (LBVH) over Morton
//  codes. Everything runs on the device; the CPU only encodes.
//
//  Pipeline per step:
//      bhReset          -> clear the atomic bounding box
//      bhBBox           -> threadgroup reduction + atomic min/max
//      bhMorton         -> 30-bit (10/axis) Morton key, plus a 30-bit
//                          refinement used only to break ties, plus the
//                          identity payload
//      bhRadixHist      -\
//      bhScanBlocks      |  12 x LSD radix passes, 5-bit digits, stable
//      bhScanAdd         |  (2 x 30 key bits == 12 * 5)
//      bhRadixScatter   -/
//      bhInitLeaves     -> leaf CoM/AABB, clear flags and parents
//      bhBuildInternal  -> Karras determineRange / findSplit
//      bhBottomUp       -> atomic-counter merge of mass, CoM, AABB
//      bhLinkEscape     -> preorder escape pointers ("ropes")
//      accelKickBarnesHut -> per-particle traversal + velocity kick
//
//  This file is concatenated after Common.metal and Physics.metal, so
//  Particle, SimParams and softenedAccel() are already in scope.
// ===================================================================

// ---- tunables (Swift side mirrors these; keep them in sync) --------
#define BH_SORT_BITS   5u
#define BH_RADIX       32u
#define BH_SORT_TG     128u
#define BH_SORT_IPT    8u
#define BH_SORT_TILE   1024u          // BH_SORT_TG * BH_SORT_IPT
#define BH_SCAN_TG     128u
#define BH_SCAN_IPT    8u
#define BH_SCAN_TILE   1024u          // BH_SCAN_TG * BH_SCAN_IPT
#define BH_BBOX_TG     256u
#define BH_INVALID     0xFFFFFFFFu

// Hard cap on the traversal walk, as a multiple of the node count.
//
// The traversal is stackless: it follows child/escape pointers, so a
// well-formed tree is visited in preorder and terminates after at most
// 2N-1 steps with no stack at all. This cap exists purely so that a
// corrupt tree can never hang the GPU; it is never reached in practice.
#define BH_WALK_BUDGET(n)  (4u * (n))

struct BHUniforms {
    uint  count;        // particle count N
    uint  shift;        // radix digit shift for the current sort pass
    uint  numBlocks;    // number of sort tiles
    uint  scanCount;    // element count for the current scan level
    float theta2;       // theta^2
    uint  digitFromHi;  // radix pass reads its digit from the hi key (1) or lo (0)
    float pad1;
    float pad2;
};

/// One tree node, 32 bytes, so a traversal step is a single contiguous
/// fetch instead of five scattered ones. Leaves live at node index
/// (N-1 + leafSlot) and store their particle index in `aux.z`.
struct BHNode {
    float4 com;   // xyz centre of mass, w total mass
    float4 aux;   // x size, y 2*|com - aabbCentre|,
                  // z childA (internal) or particle index (leaf),
                  // w escape pointer: the node to jump to when this one is
                  //   accepted or finished. See bhLinkEscape.
};

// -------------------------------------------------------------------
//  Order-preserving float <-> uint, so atomic min/max on uint gives a
//  correct min/max on float (negatives included).
// -------------------------------------------------------------------
inline uint bhFloatToOrdered(float f) {
    uint i = as_type<uint>(f);
    return (i & 0x80000000u) ? ~i : (i | 0x80000000u);
}
inline float bhOrderedToFloat(uint u) {
    uint i = (u & 0x80000000u) ? (u & 0x7FFFFFFFu) : ~u;
    return as_type<float>(i);
}

// The library is compiled with fast math, where isfinite() is not
// dependable. A plain magnitude window rejects infinities and absurd
// values without relying on NaN semantics.
inline bool bhSane(float3 p) {
    return (p.x > -1.0e30f && p.x < 1.0e30f)
        && (p.y > -1.0e30f && p.y < 1.0e30f)
        && (p.z > -1.0e30f && p.z < 1.0e30f);
}

// -------------------------------------------------------------------
//  1. Bounding box
// -------------------------------------------------------------------
kernel void bhReset(device atomic_uint *bbox [[buffer(0)]],
                    uint gid [[thread_position_in_grid]])
{
    if (gid < 3u) {
        // min slots start at +max
        atomic_store_explicit(&bbox[gid], 0xFFFFFFFFu, memory_order_relaxed);
    } else if (gid < 6u) {
        // max slots start at -max
        atomic_store_explicit(&bbox[gid], 0u, memory_order_relaxed);
    }
}

kernel void bhBBox(device const Particle *particles [[buffer(0)]],
                   constant BHUniforms  &u         [[buffer(1)]],
                   device atomic_uint   *bbox      [[buffer(2)]],
                   uint gid [[thread_position_in_grid]],
                   uint lid [[thread_position_in_threadgroup]])
{
    threadgroup float3 tlo[BH_BBOX_TG];
    threadgroup float3 thi[BH_BBOX_TG];

    float3 lo = float3( 3.0e38f);
    float3 hi = float3(-3.0e38f);
    if (gid < u.count) {
        float3 p = particles[gid].position.xyz;
        if (bhSane(p)) { lo = p; hi = p; }
    }
    tlo[lid] = lo;
    thi[lid] = hi;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint s = BH_BBOX_TG / 2u; s > 0u; s >>= 1) {
        if (lid < s) {
            tlo[lid] = min(tlo[lid], tlo[lid + s]);
            thi[lid] = max(thi[lid], thi[lid + s]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (lid == 0u) {
        float3 a = tlo[0], b = thi[0];
        atomic_fetch_min_explicit(&bbox[0], bhFloatToOrdered(a.x), memory_order_relaxed);
        atomic_fetch_min_explicit(&bbox[1], bhFloatToOrdered(a.y), memory_order_relaxed);
        atomic_fetch_min_explicit(&bbox[2], bhFloatToOrdered(a.z), memory_order_relaxed);
        atomic_fetch_max_explicit(&bbox[3], bhFloatToOrdered(b.x), memory_order_relaxed);
        atomic_fetch_max_explicit(&bbox[4], bhFloatToOrdered(b.y), memory_order_relaxed);
        atomic_fetch_max_explicit(&bbox[5], bhFloatToOrdered(b.z), memory_order_relaxed);
    }
}

// -------------------------------------------------------------------
//  2. Morton codes
// -------------------------------------------------------------------
inline uint bhExpandBits(uint v) {          // 10 bits -> spread over 30
    v = (v * 0x00010001u) & 0xFF0000FFu;
    v = (v * 0x00000101u) & 0x0F00F00Fu;
    v = (v * 0x00000011u) & 0xC30C30C3u;
    v = (v * 0x00000005u) & 0x49249249u;
    return v;
}

kernel void bhMorton(device const Particle *particles [[buffer(0)]],
                     constant BHUniforms  &u         [[buffer(1)]],
                     device const uint    *bbox      [[buffer(2)]],
                     device uint          *keysHi    [[buffer(3)]],
                     device uint          *keysLo    [[buffer(4)]],
                     device uint          *vals      [[buffer(5)]],
                     uint gid [[thread_position_in_grid]])
{
    if (gid >= u.count) return;

    float3 lo = float3(bhOrderedToFloat(bbox[0]),
                       bhOrderedToFloat(bbox[1]),
                       bhOrderedToFloat(bbox[2]));
    float3 hi = float3(bhOrderedToFloat(bbox[3]),
                       bhOrderedToFloat(bbox[4]),
                       bhOrderedToFloat(bbox[5]));
    float3 ext = max(hi - lo, float3(1.0e-6f));

    float3 p = particles[gid].position.xyz;
    if (!bhSane(p)) p = lo;
    float3 t = (p - lo) / ext;

    // 20 bits per axis. max(...,0) first, then a uint min, so a NaN cannot
    // escape the range. 2^20 is well inside float's 24-bit mantissa, so the
    // quantisation is exact and therefore deterministic.
    uint3 q = min(uint3(max(t * 1048576.0f, float3(0.0f))), uint3(1048575u));

    // The HIGH half is exactly the specified 30-bit / 10-bit-per-axis Morton
    // code: interleaving is prefix-preserving, so the top 30 bits of a 60-bit
    // code are the code you get from the top 10 bits of each coordinate.
    uint3 qh = q >> 10;
    uint3 ql = q & 1023u;
    keysHi[gid] = (bhExpandBits(qh.x) << 2) | (bhExpandBits(qh.y) << 1) | bhExpandBits(qh.z);
    keysLo[gid] = (bhExpandBits(ql.x) << 2) | (bhExpandBits(ql.y) << 1) | bhExpandBits(ql.z);
    vals[gid] = gid;
}

// -------------------------------------------------------------------
//  3. GPU LSD radix sort — 5-bit digits, 6 passes, stable.
//
//     Stability matters twice over: it makes the sort deterministic and
//     it leaves equal Morton codes in ascending particle-index order,
//     which is exactly what the Karras tie-break below assumes.
// -------------------------------------------------------------------

// Per-tile digit histogram, written digit-major so that one global
// exclusive scan over the whole array yields each (digit, tile) start.
kernel void bhRadixHist(device const uint   *keys [[buffer(0)]],
                        constant BHUniforms &u    [[buffer(1)]],
                        device uint         *hist [[buffer(2)]],
                        uint lid [[thread_position_in_threadgroup]],
                        uint bid [[threadgroup_position_in_grid]])
{
    threadgroup atomic_uint lh[BH_RADIX];
    if (lid < BH_RADIX) atomic_store_explicit(&lh[lid], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint base = bid * BH_SORT_TILE;
    for (uint i = 0u; i < BH_SORT_IPT; ++i) {
        uint idx = base + i * BH_SORT_TG + lid;
        if (idx < u.count) {
            uint d = (keys[idx] >> u.shift) & (BH_RADIX - 1u);
            atomic_fetch_add_explicit(&lh[d], 1u, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (lid < BH_RADIX) {
        hist[lid * u.numBlocks + bid] = atomic_load_explicit(&lh[lid], memory_order_relaxed);
    }
}

// Exclusive scan of one 1024-element tile, in place, emitting the tile
// total to blockSums. Reads the whole tile into threadgroup memory
// before writing anything, so in == out is safe.
kernel void bhScanBlocks(device const uint   *inBuf     [[buffer(0)]],
                         device uint         *outBuf    [[buffer(1)]],
                         device uint         *blockSums [[buffer(2)]],
                         constant BHUniforms &u         [[buffer(3)]],
                         uint lid [[thread_position_in_threadgroup]],
                         uint bid [[threadgroup_position_in_grid]])
{
    threadgroup uint tile[BH_SCAN_TILE];
    threadgroup uint partial[BH_SCAN_TG];

    uint base = bid * BH_SCAN_TILE;
    uint s0   = lid * BH_SCAN_IPT;
    for (uint i = 0u; i < BH_SCAN_IPT; ++i) {
        uint idx = base + s0 + i;
        tile[s0 + i] = (idx < u.scanCount) ? inBuf[idx] : 0u;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint sum = 0u;
    for (uint i = 0u; i < BH_SCAN_IPT; ++i) {
        uint v = tile[s0 + i];
        tile[s0 + i] = sum;
        sum += v;
    }
    partial[lid] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Hillis-Steele inclusive scan over the 128 per-thread totals
    for (uint off = 1u; off < BH_SCAN_TG; off <<= 1) {
        uint v = (lid >= off) ? partial[lid - off] : 0u;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        partial[lid] += v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint blockBase = (lid == 0u) ? 0u : partial[lid - 1u];
    uint total     = partial[BH_SCAN_TG - 1u];

    for (uint i = 0u; i < BH_SCAN_IPT; ++i) {
        uint idx = base + s0 + i;
        if (idx < u.scanCount) outBuf[idx] = tile[s0 + i] + blockBase;
    }
    if (lid == 0u) blockSums[bid] = total;
}

kernel void bhScanAdd(device uint         *data    [[buffer(0)]],
                      device const uint   *offsets [[buffer(1)]],
                      constant BHUniforms &u       [[buffer(2)]],
                      uint lid [[thread_position_in_threadgroup]],
                      uint bid [[threadgroup_position_in_grid]])
{
    uint add = offsets[bid];
    if (add == 0u) return;                 // uniform across the threadgroup
    uint base = bid * BH_SCAN_TILE + lid * BH_SCAN_IPT;
    for (uint i = 0u; i < BH_SCAN_IPT; ++i) {
        uint idx = base + i;
        if (idx < u.scanCount) data[idx] += add;
    }
}

// Stable scatter. Each thread owns BH_SORT_IPT *contiguous* elements, so
// walking them in order gives stable ranks for free once the per-thread,
// per-digit counts have been exclusive-scanned across the tile.
kernel void bhRadixScatter(device const uint   *hiIn    [[buffer(0)]],
                           device const uint   *loIn    [[buffer(1)]],
                           constant BHUniforms &u       [[buffer(2)]],
                           device const uint   *offsets [[buffer(3)]],
                           device uint         *hiOut   [[buffer(4)]],
                           device uint         *loOut   [[buffer(5)]],
                           device const uint   *valsIn  [[buffer(6)]],
                           device uint         *valsOut [[buffer(7)]],
                           uint lid [[thread_position_in_threadgroup]],
                           uint bid [[threadgroup_position_in_grid]])
{
    threadgroup uint counts[BH_RADIX * BH_SORT_TG];   // 32 x 128 = 16 KB
    threadgroup uint partial[BH_SORT_TG];
    threadgroup uint rowStart[BH_RADIX];

    const uint CHUNK = (BH_RADIX * BH_SORT_TG) / BH_SORT_TG;   // == BH_RADIX

    uint base = bid * BH_SORT_TILE + lid * BH_SORT_IPT;

    uint myHi[BH_SORT_IPT];
    uint myLo[BH_SORT_IPT];
    uint myVal[BH_SORT_IPT];
    uint myDig[BH_SORT_IPT];
    bool live[BH_SORT_IPT];

    // Each thread owns column `lid` of every digit row, so no barrier is
    // needed between clearing and incrementing.
    for (uint d = 0u; d < BH_RADIX; ++d) counts[d * BH_SORT_TG + lid] = 0u;

    for (uint i = 0u; i < BH_SORT_IPT; ++i) {
        uint idx = base + i;
        live[i] = (idx < u.count);
        myDig[i] = 0u;
        if (live[i]) {
            uint kh = hiIn[idx], kl = loIn[idx];
            myHi[i] = kh;
            myLo[i] = kl;
            myVal[i] = valsIn[idx];
            uint d = ((u.digitFromHi != 0u ? kh : kl) >> u.shift) & (BH_RADIX - 1u);
            myDig[i] = d;
            counts[d * BH_SORT_TG + lid] += 1u;
        } else {
            myHi[i] = 0u;
            myLo[i] = 0u;
            myVal[i] = 0u;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Exclusive scan of counts[0 .. BH_RADIX*BH_SORT_TG)
    uint start = lid * CHUNK;
    uint sum = 0u;
    for (uint i = 0u; i < CHUNK; ++i) {
        uint v = counts[start + i];
        counts[start + i] = sum;
        sum += v;
    }
    partial[lid] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint off = 1u; off < BH_SORT_TG; off <<= 1) {
        uint v = (lid >= off) ? partial[lid - off] : 0u;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        partial[lid] += v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint blockBase = (lid == 0u) ? 0u : partial[lid - 1u];
    for (uint i = 0u; i < CHUNK; ++i) counts[start + i] += blockBase;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // counts[d * TG + 0] is now the number of tile elements with digit < d
    if (lid < BH_RADIX) rowStart[lid] = counts[lid * BH_SORT_TG];
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint i = 0u; i < BH_SORT_IPT; ++i) {
        if (!live[i]) continue;
        uint d   = myDig[i];
        uint pos = counts[d * BH_SORT_TG + lid];
        counts[d * BH_SORT_TG + lid] = pos + 1u;   // private to this thread
        uint dst = offsets[d * u.numBlocks + bid] + (pos - rowStart[d]);
        hiOut[dst]   = myHi[i];
        loOut[dst]   = myLo[i];
        valsOut[dst] = myVal[i];
    }
}

// -------------------------------------------------------------------
//  4. Tree layout
//     node index  [0, N-1)        -> internal nodes
//     node index  [N-1, 2N-1)     -> leaves, leaf k == node (N-1+k)
// -------------------------------------------------------------------

kernel void bhInitLeaves(device const Particle *particles [[buffer(0)]],
                         constant BHUniforms   &u         [[buffer(1)]],
                         device const uint     *sortedIdx [[buffer(2)]],
                         device BHNode         *nodes     [[buffer(3)]],
                         device float4         *nodeMin   [[buffer(4)]],
                         device float4         *nodeMax   [[buffer(5)]],
                         device uint           *nodeFlags [[buffer(6)]],
                         device uint           *nodeParent[[buffer(7)]],
                         uint gid [[thread_position_in_grid]])
{
    uint n = u.count;
    if (gid >= n) return;

    uint p  = sortedIdx[gid];
    float4 pp = particles[p].position;
    float3 x  = pp.xyz;
    if (!bhSane(x)) x = float3(0.0f);

    uint node = (n - 1u) + gid;
    nodes[node].com  = float4(x, pp.w);
    // a leaf is a point: zero size, zero centroid offset, particle id in z
    nodes[node].aux  = float4(0.0f, 0.0f, as_type<float>(p), as_type<float>(BH_INVALID));
    nodeMin[node]    = float4(x, 0.0f);
    nodeMax[node]    = float4(x, 0.0f);
    nodeParent[node] = BH_INVALID;

    if (gid + 1u < n) {                   // gid < n-1: an internal node
        nodeFlags[gid]  = 0u;
        nodeParent[gid] = BH_INVALID;     // the root keeps this value
    }
}

// Karras's delta: length of the common prefix of the keys of leaves i and j,
// over the concatenation  [ 30-bit Morton | 30-bit refinement | index ]
// laid out as three 32-bit blocks.
//
// Duplicate Morton codes are the whole reason for the second and third
// blocks. Without a tie-break Karras's determineRange/findSplit cannot pick
// a split point among equal keys and the tree comes out broken; the index
// block guarantees every key is distinct, so a valid tree always exists.
// The refinement block sits in front of it so that ties are resolved
// *spatially* rather than by buffer slot — see bhMorton.
inline int bhDelta(device const uint *keysHi, device const uint *keysLo,
                   uint n, int i, int j)
{
    if (j < 0 || j >= (int)n) return -1;
    uint a = keysHi[i], b = keysHi[j];
    if (a != b) return (int)clz(a ^ b);
    a = keysLo[i]; b = keysLo[j];
    if (a != b) return 32 + (int)clz(a ^ b);
    return 64 + (int)clz((uint)i ^ (uint)j);
}

kernel void bhBuildInternal(constant BHUniforms &u          [[buffer(0)]],
                            device const uint   *keysHi     [[buffer(1)]],
                            device const uint   *keysLo     [[buffer(2)]],
                            device BHNode       *nodes      [[buffer(3)]],
                            device uint         *nodeParent [[buffer(4)]],
                            device uint         *childB     [[buffer(5)]],
                            uint gid [[thread_position_in_grid]])
{
    uint n = u.count;
    if (n < 2u || gid + 1u >= n) return;      // n-1 internal nodes
    int i = (int)gid;

    // ---- determineRange -------------------------------------------
    int d = (bhDelta(keysHi, keysLo, n, i, i + 1) - bhDelta(keysHi, keysLo, n, i, i - 1)) > 0 ? 1 : -1;
    int dmin = bhDelta(keysHi, keysLo, n, i, i - d);

    int lmax = 2;
    while (bhDelta(keysHi, keysLo, n, i, i + lmax * d) > dmin) lmax <<= 1;

    int l = 0;
    for (int t = lmax >> 1; t >= 1; t >>= 1) {
        if (bhDelta(keysHi, keysLo, n, i, i + (l + t) * d) > dmin) l += t;
    }
    int j = i + l * d;

    // ---- findSplit -------------------------------------------------
    int dnode = bhDelta(keysHi, keysLo, n, i, j);
    int s = 0;
    for (int t = (l + 1) >> 1; ; t = (t + 1) >> 1) {
        if (bhDelta(keysHi, keysLo, n, i, i + (s + t) * d) > dnode) s += t;
        if (t <= 1) break;
    }
    int gamma = i + s * d + min(d, 0);

    uint lo = (uint)min(i, j), hiIdx = (uint)max(i, j);
    uint left  = ((uint)gamma       == lo)    ? (n - 1u + (uint)gamma)        : (uint)gamma;
    uint right = ((uint)(gamma + 1) == hiIdx) ? (n - 1u + (uint)(gamma + 1))  : (uint)(gamma + 1);

    nodes[gid].aux.z = as_type<float>(left);
    nodes[gid].aux.w = as_type<float>(BH_INVALID);  // bhLinkEscape fills this in
    childB[gid]       = right;         // only the build needs the right child
    nodeParent[left]  = gid;
    nodeParent[right] = gid;
}

// -------------------------------------------------------------------
//  5. Bottom-up mass / centre of mass / AABB.
//
//  One thread per leaf walks up; an atomic counter per internal node
//  makes the FIRST arrival bail out and the SECOND do the merge, so both
//  children are guaranteed complete. Release/acquire device fences pair
//  the child writes with the sibling's reads.
// -------------------------------------------------------------------
kernel void bhBottomUp(constant BHUniforms &u          [[buffer(0)]],
                       device const uint   *nodeParent [[buffer(1)]],
                       device BHNode       *nodes      [[buffer(2)]],
                       device float4       *nodeMin    [[buffer(3)]],
                       device float4       *nodeMax    [[buffer(4)]],
                       device atomic_uint  *nodeFlags  [[buffer(5)]],
                       device const uint   *childB     [[buffer(6)]],
                       uint gid [[thread_position_in_grid]])
{
    uint n = u.count;
    if (n < 2u || gid >= n) return;

    uint node = nodeParent[(n - 1u) + gid];
    while (node != BH_INVALID) {
        // publish whatever this thread wrote for the child it came from.
        // MSL only exposes relaxed and seq_cst, so seq_cst plays both the
        // release and the acquire half of the handshake here.
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst,
                            thread_scope_device);
        uint prev = atomic_fetch_add_explicit(&nodeFlags[node], 1u,
                                              memory_order_relaxed);
        if (prev == 0u) return;            // first arrival: sibling isn't ready
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst,
                            thread_scope_device);

        float4 aux = nodes[node].aux;
        uint a = as_type<uint>(aux.z);
        uint b = childB[node];

        float4 ca = nodes[a].com;
        float4 cb = nodes[b].com;
        float  m  = ca.w + cb.w;
        // Massless (test) particles: fall back to the midpoint so the node
        // still has a sane position. It contributes no acceleration anyway.
        float3 com = (m > 0.0f) ? (ca.xyz * ca.w + cb.xyz * cb.w) / m
                                : (ca.xyz + cb.xyz) * 0.5f;

        float3 lo = min(nodeMin[a].xyz, nodeMin[b].xyz);
        float3 hi = max(nodeMax[a].xyz, nodeMax[b].xyz);
        nodeMin[node] = float4(lo, 0.0f);
        nodeMax[node] = float4(hi, 0.0f);

        float3 ext = hi - lo;
        float  size = max(ext.x, max(ext.y, ext.z));
        // Barnes (1994) safety term. A radix-tree node can be long and thin
        // with its centre of mass right at one end, and a bare size/distance
        // test then badly under-opens it. Charging 2*|com - centre| onto the
        // size is a conservative, sqrt-free way to buy that back:
        //   (size + 2d)/r <= theta  ==>  size/(r - d) <= theta  for theta <= 1.
        float  off = 2.0f * length(com - 0.5f * (lo + hi));

        nodes[node].com = float4(com, m);
        nodes[node].aux = float4(size, off, aux.z, aux.w);

        node = nodeParent[node];
    }
}

// -------------------------------------------------------------------
//  5b. Escape ("rope") pointers.
//
//  escape(node) is the node to visit next once `node` has been accepted
//  or fully consumed — i.e. the preorder successor of node's whole
//  subtree. With childA being the preorder successor of an opened node,
//  that turns traversal into a pointer walk with no stack at all.
//
//      escape(root)      = INVALID
//      escape(childA(p)) = childB(p)
//      escape(childB(p)) = escape(p)
//
//  Each thread resolves its own node by walking up while it is a right
//  child. The climb is bounded by the tree depth (<= 92, one level per
//  key bit), so this can neither run long nor loop.
// -------------------------------------------------------------------
kernel void bhLinkEscape(constant BHUniforms &u          [[buffer(0)]],
                         device BHNode       *nodes      [[buffer(1)]],
                         device const uint   *nodeParent [[buffer(2)]],
                         device const uint   *childB     [[buffer(3)]],
                         uint gid [[thread_position_in_grid]])
{
    uint n = u.count;
    if (n < 2u || gid >= 2u * n - 1u) return;

    uint esc = BH_INVALID;
    uint cur = gid;
    // The climb is bounded by the tree depth, which is bounded by the key
    // length: 30 Morton bits + 30 refinement bits + up to 32 index bits.
    for (uint step = 0u; step < 128u; ++step) {
        uint par = nodeParent[cur];
        if (par == BH_INVALID) { esc = BH_INVALID; break; }
        if (as_type<uint>(nodes[par].aux.z) == cur) { esc = childB[par]; break; }
        cur = par;                       // we were the right child: keep climbing
    }
    nodes[gid].aux.w = as_type<float>(esc);
}

// -------------------------------------------------------------------
//  6. Traversal + velocity kick.
//
//  Same contract as accelKickDirect: velocity.xyz += acc * dt, and the
//  starburst temperature cools by the same amount.
// -------------------------------------------------------------------
kernel void accelKickBarnesHut(device Particle      *particles  [[buffer(0)]],
                               constant SimParams   &prm        [[buffer(1)]],
                               constant BHUniforms  &u          [[buffer(2)]],
                               device const BHNode  *nodes      [[buffer(3)]],
                               device const uint    *sortedIdx  [[buffer(4)]],
                               uint tid [[thread_position_in_grid]])
{
    uint n = u.count;
    if (tid >= n) return;

    // Walk the particles in Morton order rather than buffer order. Adjacent
    // threads then sit next to each other in space and visit almost the same
    // nodes, which is worth several times the raw traversal cost in cache
    // hits and SIMD coherence. Only the single position read and the single
    // velocity write are scattered.
    uint gid = sortedIdx[tid];
    device Particle &p = particles[gid];
    float3 pos  = p.position.xyz;
    float  eps2 = prm.softening * prm.softening;
    float  th2  = u.theta2;
    float3 acc  = float3(0.0f);

    if (n > 1u) {
        uint leafBase = n - 1u;
        uint node = 0u;                       // root internal node
        // Hard bound on the walk. A well-formed tree visits at most 2N-1
        // nodes; this only exists so a corrupt tree cannot hang the GPU.
        uint budget = BH_WALK_BUDGET(n);

        while (node != BH_INVALID && budget-- != 0u) {
            BHNode nd = nodes[node];          // one 32-byte fetch

            float3 dv = nd.com.xyz - pos;
            float  d2 = dot(dv, dv);

            if (node >= leafBase) {           // leaf == exactly one particle
                // never let a particle pull on itself (it would contribute
                // exactly zero anyway, with d == 0, but be explicit)
                if (as_type<uint>(nd.aux.z) != gid) {
                    acc += softenedAccel(dv, nd.com.w, eps2);
                }
                node = as_type<uint>(nd.aux.w);
                continue;
            }

            float s = nd.aux.x + nd.aux.y;    // size + 2*centroid offset

            // open when s / d > theta  <=>  s^2 > theta^2 * d^2
            if (s * s <= th2 * d2) {
                acc += softenedAccel(dv, nd.com.w, eps2);
                node = as_type<uint>(nd.aux.w);   // skip the subtree
            } else {
                node = as_type<uint>(nd.aux.z);   // descend: childA is next
            }
        }
    }

    p.velocity.xyz += acc * prm.dt;
    p.velocity.w = clamp(p.velocity.w - prm.starburstDecay * prm.dt, 0.0f, 1.0f);
}
