import Foundation
import simd

/// Compact Blender export: GSCABIN1, little-endian UInt32 count, then four float4s per vertex.
enum CabinAsset {
    enum LoadError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let reason): return reason }
        }
    }

    static func loadBundledVertices() -> [CabinVertex]? {
        guard let url = Bundle.module.url(forResource: "cabin", withExtension: "mesh", subdirectory: "Cabin") else {
            print("Cabin asset missing; using procedural cabin")
            return nil
        }
        do {
            let vertices = try loadVertices(from: url)
            print("Loaded Blender cabin: \(vertices.count / 3) triangles, \(vertices.count * 64) vertex bytes")
            return vertices
        } catch {
            print("Cabin asset rejected (\(error)); using procedural cabin")
            return nil
        }
    }

    /// Public within the executable so diagnostics can validate an export before packaging it.
    static func loadVertices(from url: URL) throws -> [CabinVertex] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [CabinVertex] {
        guard data.count >= 12, data.prefix(8).elementsEqual("GSCABIN1".utf8) else {
            throw LoadError.invalid("invalid header")
        }
        return try data.withUnsafeBytes { bytes in
            func word(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            let count = Int(word(8))
            guard count > 0, count < 2_000_000, count.isMultiple(of: 3) else {
                throw LoadError.invalid("invalid triangle vertex count: \(count)")
            }
            let (payloadLength, overflow) = count.multipliedReportingOverflow(by: 64)
            let (expectedLength, headerOverflow) = payloadLength.addingReportingOverflow(12)
            guard !overflow, !headerOverflow, data.count == expectedLength else {
                throw LoadError.invalid("vertex payload length mismatch")
            }
            var vertices: [CabinVertex] = []
            vertices.reserveCapacity(count)
            for index in 0..<count {
                let base = 12 + index * 64
                func vector(_ offset: Int) throws -> SIMD4<Float> {
                    let value = SIMD4<Float>(
                        Float(bitPattern: word(base + offset)),
                        Float(bitPattern: word(base + offset + 4)),
                        Float(bitPattern: word(base + offset + 8)),
                        Float(bitPattern: word(base + offset + 12)))
                    guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite else {
                        throw LoadError.invalid("non-finite component at vertex \(index)")
                    }
                    return value
                }
                vertices.append(try CabinVertex(position: vector(0), normal: vector(16),
                                                color: vector(32), detail: vector(48)))
            }
            return vertices
        }
    }
}
