import Foundation
import Metal
import simd
import WEKit

/// Vertex attribute streams a draw can supply. Attribute *locations* match
/// `ShaderPreprocessor.attributeLocations`, which is what `finalize` pins into
/// the GLSL and therefore what SPIRV-Cross emits as `[[attribute(n)]]`.
public struct VertexLayout: Hashable {
    public struct Attribute: Hashable {
        public let location: Int
        public let format: MTLVertexFormat
        public let offset: Int
        public init(location: Int, format: MTLVertexFormat, offset: Int) {
            self.location = location; self.format = format; self.offset = offset
        }
    }

    public let attributes: [Attribute]
    public let stride: Int
    public let name: String

    public init(name: String, attributes: [Attribute], stride: Int) {
        self.name = name; self.attributes = attributes; self.stride = stride
    }

    /// position float3 + texcoord float2, 20 bytes, used by every image/effect quad.
    public static let quad = VertexLayout(
        name: "quad",
        attributes: [
            Attribute(location: 0, format: .float3, offset: 0),
            Attribute(location: 1, format: .float2, offset: 12),
        ],
        stride: 20)

    /// The `.mdl` vertex: position, the two skinning attributes, texture
    /// coordinate, normal and signed tangent.
    ///
    /// Older 52 byte model vertices omit the final two fields, so the parser
    /// supplies the flat-sheet defaults. Newer 80 byte vertices carry them.
    public static let puppet = VertexLayout(
        name: "puppet",
        attributes: [
            Attribute(location: 0, format: .float3, offset: 0),
            Attribute(location: 11, format: .uint4, offset: 12),
            Attribute(location: 12, format: .float4, offset: 28),
            Attribute(location: 1, format: .float2, offset: 44),
            Attribute(location: 3, format: .float3, offset: 52),
            // a_Tangent4 is not in the fixed semantic table, so finalize assigns 13.
            Attribute(location: 13, format: .float4, offset: 64),
        ],
        stride: 80)

    /// Sprite particles: see `genericparticle.vert`. The shader reads the particle's
    /// rotation, size, velocity and lifetime out of the spare texcoord channels, so the
    /// layout is fixed at 80 bytes with these exact offsets.
    public static let particle = VertexLayout(
        name: "particle",
        attributes: [
            Attribute(location: 0, format: .float3, offset: 0),    // a_Position
            Attribute(location: 1, format: .float4, offset: 16),   // a_TexCoordVec4
            Attribute(location: 2, format: .float4, offset: 32),   // a_Color
            Attribute(location: 6, format: .float4, offset: 48),   // a_TexCoordVec4C1
            Attribute(location: 7, format: .float2, offset: 64),   // a_TexCoordC2
        ],
        stride: 80)
}

/// Buffer indices. SPIRV-Cross puts the default uniform block at buffer 0, so
/// vertex/instance streams live at the top of the range.
public enum BufferIndex {
    public static let uniforms = 0
    public static let zeroFill = 29
    public static let vertices = 30
}

public struct BlendState: Hashable {
    public let mode: WEBlendMode
    public let writesAlpha: Bool
    public init(mode: WEBlendMode, writesAlpha: Bool) { self.mode = mode; self.writesAlpha = writesAlpha }
}

public struct SamplerKey: Hashable {
    public let nearest: Bool
    public let clamp: Bool
    public let border: Bool
    public let hasMips: Bool
    public init(nearest: Bool, clamp: Bool, border: Bool = false, hasMips: Bool) {
        self.nearest = nearest; self.clamp = clamp; self.border = border; self.hasMips = hasMips
    }
    public static let linearClamp = SamplerKey(nearest: false, clamp: true, hasMips: false)
}

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case libraryCompilation(String)
    case pipelineCreation(String)
    case missingFunction(String)
    case resourceCreation(String)

    public var description: String {
        switch self {
        case .noDevice: return "no Metal device available"
        case .libraryCompilation(let s): return "MSL compile failed: \(s)"
        case .pipelineCreation(let s): return "pipeline creation failed: \(s)"
        case .missingFunction(let s): return "missing Metal function \(s)"
        case .resourceCreation(let s): return "could not create \(s)"
        }
    }
}

/// Device-wide Metal resources shared by every wallpaper being rendered:
/// pipeline/sampler caches, the utility shaders (blit/present) and scratch buffers.
public final class RenderContext {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let supportsBC: Bool

    private var pipelineCache: [String: MTLRenderPipelineState] = [:]
    private var libraryCache: [String: MTLLibrary] = [:]
    private var samplerCache: [SamplerKey: MTLSamplerState] = [:]
    private let lock = NSRecursiveLock()

    /// 64 zero bytes, bound to any vertex attribute a shader declares but we do not supply.
    public let zeroBuffer: MTLBuffer
    private var utilityLibrary: MTLLibrary!
    private var blitPipelines: [String: MTLRenderPipelineState] = [:]

    /// Shared instance on the system default device.
    public static let shared: RenderContext? = try? RenderContext()

    public init(device: MTLDevice? = nil) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        self.device = dev
        guard let queue = dev.makeCommandQueue() else { throw RenderError.resourceCreation("command queue") }
        self.commandQueue = queue
        if #available(macOS 11.0, *) { supportsBC = dev.supportsBCTextureCompression } else { supportsBC = true }
        guard let zero = dev.makeBuffer(length: 64, options: .storageModeShared) else {
            throw RenderError.resourceCreation("zero buffer")
        }
        memset(zero.contents(), 0, 64)
        zero.label = "mirage.zeroFill"
        self.zeroBuffer = zero
        self.utilityLibrary = try makeLibrary(source: RenderContext.utilitySource, key: "utility")
    }

    // MARK: Libraries & pipelines

    public func makeLibrary(source: String, key: String) throws -> MTLLibrary {
        lock.lock(); defer { lock.unlock() }
        if let lib = libraryCache[key] { return lib }
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }
        do {
            let lib = try device.makeLibrary(source: source, options: options)
            libraryCache[key] = lib
            return lib
        } catch {
            throw RenderError.libraryCompilation("\(error)\n\(ShaderCompiler.numbered(source))")
        }
    }

    /// Pipeline for a compiled WE shader program.
    public func pipeline(program: ShaderCompiler.Program, layout: VertexLayout, pixelFormat: MTLPixelFormat,
                         blend: BlendState, label: String) throws -> MTLRenderPipelineState {
        // The identity of a program is its compiler cache key. Hashing the MSL
        // here instead would re-hash roughly 20 KB per pass per frame, which
        // measured as the largest single piece of CPU work in the frame.
        let identity = program.cacheKey.isEmpty
            ? ShaderCompiler.hash(program.vertex.msl) + ShaderCompiler.hash(program.fragment.msl)
            : program.cacheKey
        let key = [
            identity, layout.name, String(pixelFormat.rawValue),
            blend.mode.rawValue, blend.writesAlpha ? "a" : "-",
        ].joined(separator: "|")
        lock.lock(); defer { lock.unlock() }
        if let p = pipelineCache[key] { return p }

        // Only reached once per distinct pipeline, so the hashes here are free.
        let vertexHash = ShaderCompiler.hash(program.vertex.msl)
        let fragmentHash = ShaderCompiler.hash(program.fragment.msl)
        let vlib = try makeLibrary(source: program.vertex.msl, key: "v\(vertexHash)")
        let flib = try makeLibrary(source: program.fragment.msl, key: "f\(fragmentHash)")
        guard let vfn = vlib.makeFunction(name: program.vertex.entryPoint) else {
            throw RenderError.missingFunction(program.vertex.entryPoint)
        }
        guard let ffn = flib.makeFunction(name: program.fragment.entryPoint) else {
            throw RenderError.missingFunction(program.fragment.entryPoint)
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.vertexDescriptor = RenderContext.vertexDescriptor(for: program, layout: layout)
        guard let attachment = desc.colorAttachments[0] else {
            throw RenderError.pipelineCreation("missing color attachment")
        }
        attachment.pixelFormat = pixelFormat
        RenderContext.configure(attachment, blend: blend)
        do {
            let state = try device.makeRenderPipelineState(descriptor: desc)
            pipelineCache[key] = state
            return state
        } catch {
            throw RenderError.pipelineCreation("\(label): \(error)")
        }
    }

    /// Builds a vertex descriptor covering exactly the attributes the shader declares.
    /// Attributes we do not supply are fed from a constant zero buffer so Metal's
    /// "all stage_in attributes must be described" rule is satisfied.
    static func vertexDescriptor(for program: ShaderCompiler.Program, layout: VertexLayout) -> MTLVertexDescriptor {
        let desc = MTLVertexDescriptor()
        var usesVertexBuffer = false
        var usesZeroBuffer = false
        for input in program.vertex.inputs {
            guard input.location >= 0, input.location < 31 else { continue }
            if let attr = layout.attributes.first(where: { $0.location == input.location }) {
                desc.attributes[attr.location].format = attr.format
                desc.attributes[attr.location].offset = attr.offset
                desc.attributes[attr.location].bufferIndex = BufferIndex.vertices
                usesVertexBuffer = true
            } else {
                desc.attributes[input.location].format = RenderContext.zeroFormat(for: input)
                desc.attributes[input.location].offset = 0
                desc.attributes[input.location].bufferIndex = BufferIndex.zeroFill
                usesZeroBuffer = true
            }
        }
        if usesVertexBuffer {
            desc.layouts[BufferIndex.vertices].stride = layout.stride
            desc.layouts[BufferIndex.vertices].stepFunction = .perVertex
            desc.layouts[BufferIndex.vertices].stepRate = 1
        }
        if usesZeroBuffer {
            desc.layouts[BufferIndex.zeroFill].stride = 16
            desc.layouts[BufferIndex.zeroFill].stepFunction = .constant
            // Metal requires stepRate == 0 for a constant step function.
            desc.layouts[BufferIndex.zeroFill].stepRate = 0
        }
        return desc
    }

    private static func zeroFormat(for input: ShaderCompiler.VertexInput) -> MTLVertexFormat {
        switch (input.baseType, max(1, min(4, input.vecSize))) {
        case ("uint", 1): return .uint
        case ("uint", 2): return .uint2
        case ("uint", 3): return .uint3
        case ("uint", 4): return .uint4
        case ("int", 1): return .int
        case ("int", 2): return .int2
        case ("int", 3): return .int3
        case ("int", 4): return .int4
        case (_, 1): return .float
        case (_, 2): return .float2
        case (_, 3): return .float3
        default: return .float4
        }
    }

    /// Blend equations matching lwe's `CPass::setupRenderFramebuffer`.
    static func configure(_ attachment: MTLRenderPipelineColorAttachmentDescriptor, blend: BlendState) {
        attachment.writeMask = blend.writesAlpha ? .all : [.red, .green, .blue]
        switch blend.mode {
        case .disabled:
            attachment.isBlendingEnabled = false
        case .normal:
            // GL: glBlendFunc(GL_ONE, GL_ZERO), replace, but still "enabled".
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .zero
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .zero
        case .translucent:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .one
        }
    }

    // MARK: Samplers

    public func sampler(_ key: SamplerKey) -> MTLSamplerState? {
        lock.lock(); defer { lock.unlock() }
        if let s = samplerCache[key] { return s }
        let desc = MTLSamplerDescriptor()
        desc.minFilter = key.nearest ? .nearest : .linear
        desc.magFilter = key.nearest ? .nearest : .linear
        desc.mipFilter = key.hasMips ? (key.nearest ? .nearest : .linear) : .notMipmapped
        let address: MTLSamplerAddressMode = key.clamp ? .clampToEdge : (key.border ? .clampToBorderColor : .repeat)
        desc.sAddressMode = address
        desc.tAddressMode = address
        desc.rAddressMode = address
        if key.border { desc.borderColor = .transparentBlack }
        desc.maxAnisotropy = key.nearest ? 1 : 8
        desc.normalizedCoordinates = true
        desc.lodMinClamp = 0
        desc.lodMaxClamp = .greatestFiniteMagnitude
        guard let state = device.makeSamplerState(descriptor: desc) else { return nil }
        samplerCache[key] = state
        return state
    }

    // MARK: Utility passes (our own MSL, not WE shaders)

    public struct BlitParams {
        public var uvScale: SIMD2<Float> = SIMD2(1, 1)
        public var uvOffset: SIMD2<Float> = SIMD2(0, 0)
        public var flipY: Bool = false
        public var opacity: Float = 1
        public init() {}
        public init(uvScale: SIMD2<Float>, uvOffset: SIMD2<Float>, flipY: Bool, opacity: Float = 1) {
            self.uvScale = uvScale; self.uvOffset = uvOffset; self.flipY = flipY; self.opacity = opacity
        }
    }

    private struct BlitUniforms {
        var uvScale: SIMD2<Float>
        var uvOffset: SIMD2<Float>
        var flip: Float
        var opacity: Float
        var pad: SIMD2<Float> = .zero
    }

    public func blitPipeline(pixelFormat: MTLPixelFormat, blend: BlendState = BlendState(mode: .disabled, writesAlpha: true)) throws -> MTLRenderPipelineState {
        let key = "\(pixelFormat.rawValue)|\(blend.mode.rawValue)|\(blend.writesAlpha)"
        lock.lock(); defer { lock.unlock() }
        if let p = blitPipelines[key] { return p }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "mirage.blit"
        desc.vertexFunction = utilityLibrary.makeFunction(name: "mirage_blit_vertex")
        desc.fragmentFunction = utilityLibrary.makeFunction(name: "mirage_blit_fragment")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        RenderContext.configure(desc.colorAttachments[0], blend: blend)
        let state = try device.makeRenderPipelineState(descriptor: desc)
        blitPipelines[key] = state
        return state
    }

    /// Draws `source` over the whole of the current render target.
    @discardableResult
    public func encodeBlit(_ encoder: MTLRenderCommandEncoder, source: MTLTexture,
                           pipeline: MTLRenderPipelineState, params: BlitParams) -> Bool {
        guard let sampler = sampler(.linearClamp) else { return false }
        var uniforms = BlitUniforms(uvScale: params.uvScale, uvOffset: params.uvOffset,
                                    flip: params.flipY ? 1 : 0, opacity: params.opacity)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<BlitUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlitUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return true
    }

    private static let utilitySource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BlitUniforms {
        float2 uvScale;
        float2 uvOffset;
        float  flip;
        float  opacity;
        float2 pad;
    };

    struct BlitVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Full-target quad as a triangle strip: (-1,-1) (1,-1) (-1,1) (1,1).
    vertex BlitVertexOut mirage_blit_vertex(uint vid [[vertex_id]],
                                            constant BlitUniforms &u [[buffer(0)]]) {
        float2 corner = float2((vid & 1) == 0 ? -1.0 : 1.0, (vid & 2) == 0 ? -1.0 : 1.0);
        BlitVertexOut out;
        out.position = float4(corner, 0.0, 1.0);
        // Metal render targets and textures both have their origin at the top-left,
        // so uv.y follows clip-space y downwards.
        float2 uv = float2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5);
        if (u.flip > 0.5) { uv.y = 1.0 - uv.y; }
        out.uv = uv * u.uvScale + u.uvOffset;
        return out;
    }

    fragment float4 mirage_blit_fragment(BlitVertexOut in [[stage_in]],
                                         constant BlitUniforms &u [[buffer(0)]],
                                         texture2d<float> source [[texture(0)]],
                                         sampler samp [[sampler(0)]]) {
        float4 color = source.sample(samp, in.uv);
        color *= u.opacity;
        return color;
    }
    """
}
