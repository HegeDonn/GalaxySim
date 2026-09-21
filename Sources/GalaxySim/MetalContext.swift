import Metal
import Foundation

/// Device + queue + the runtime-compiled shader library.
///
/// The .metal sources ship as package resources and are concatenated and
/// compiled at launch. That costs a few hundred ms of startup but keeps
/// the build a plain `swift build` with no metallib step, and makes shader
/// iteration a matter of editing a file.
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    /// Order matters: Common defines the structs the others rely on.
    static let shaderOrder = ["Common", "Physics", "BarnesHut", "Relativity", "Render", "Explorer", "CosmicWeb", "Cabin", "Ship"]

    init() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw SimError.noDevice
        }
        guard let q = dev.makeCommandQueue() else {
            throw SimError.noQueue
        }
        device = dev
        queue = q

        var source = ""
        for name in MetalContext.shaderOrder {
            guard let url = Bundle.module.url(forResource: name,
                                              withExtension: "metal",
                                              subdirectory: "Shaders")
                    ?? Bundle.module.url(forResource: name, withExtension: "metal")
            else { throw SimError.missingShader(name) }
            source += try String(contentsOf: url, encoding: .utf8) + "\n"
        }

        let opts = MTLCompileOptions()
        opts.mathMode = .fast
        library = try dev.makeLibrary(source: source, options: opts)
    }

    func function(_ name: String) throws -> MTLFunction {
        guard let f = library.makeFunction(name: name) else {
            throw SimError.missingFunction(name)
        }
        return f
    }

    func computePipeline(_ name: String) throws -> MTLComputePipelineState {
        try device.makeComputePipelineState(function: function(name))
    }
}

enum SimError: LocalizedError {
    case noDevice
    case noQueue
    case missingShader(String)
    case missingFunction(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:              return "No Metal device available."
        case .noQueue:               return "Could not create a Metal command queue."
        case .missingShader(let n):  return "Shader resource \(n).metal not found in bundle."
        case .missingFunction(let n): return "Shader function \(n) not found in library."
        }
    }
}
