import Foundation
import Metal
import simd
import WEKit

// MARK: - Render target scopes

/// Wallpaper Engine addresses framebuffers by name, resolved innermost-first:
/// the effect's own FBOs, then the object's layer composites, then the scene.
public final class TargetScope {
    public let name: String
    public let parent: TargetScope?
    private var targets: [String: MTLTexture] = [:]

    public init(name: String, parent: TargetScope?) {
        self.name = name
        self.parent = parent
    }

    public func register(_ name: String, _ texture: MTLTexture) { targets[name] = texture }

    public func resolve(_ name: String) -> MTLTexture? {
        targets[name] ?? parent?.resolve(name)
    }

    public var localNames: [String] { Array(targets.keys) }
}

// MARK: - Texture references

/// One entry in a slot's resolution chain.
public enum TextureSlotEntry {
    case asset(GPUTexture)
    /// `_rt_*` / `_alias_*`, resolved through the pass's scope every frame.
    case target(String)
    /// A `bind` naming `"previous"`, or an empty slot: use `previousInput ?? input`.
    case passInput
}

/// Where a pass reads from / writes to.
public enum LayerSurface: Equatable {
    case objectTexture
    case compositeA
    case compositeB
    case named(String)
    case scene
}

// MARK: - Compiled pass

public final class CompiledPass {
    public let shaderName: String
    public let source: ShaderProgramSource
    public let program: ShaderCompiler.Program
    public var blending: WEBlendMode
    /// The blending the material declared, before `relocateBlending` moved the
    /// first pass's onto the last. Re-wiring a different subset has to start
    /// from this or the original mode is lost after the first pass.
    public var baseBlending: WEBlendMode = .normal
    /// The render target this pass writes, if it names one.
    public var targetName: String?
    public let depthTest: Bool
    public let depthWrite: Bool
    public let cull: Bool
    public let combos: [String: Int]
    public let scope: TargetScope

    /// Slot → chain, highest priority first.
    public var slots: [Int: [TextureSlotEntry]] = [:]
    /// Constants resolved from annotation defaults, material and effect override.
    public var constants: [String: ShaderValue] = [:]
    /// Constants bound to user properties, re-evaluated each frame.
    public var boundConstants: [(uniform: String, value: DynamicValue)] = []

    // Wiring, decided by the setup state machine.
    public var destination: LayerSurface = .compositeA
    public var input: LayerSurface = .objectTexture
    public var previousInput: LayerSurface?
    public var isFirst = false
    public var isFinalCandidate = false
    public var isLastOfObject = false
    /// The effect this pass belongs to (nil for the object's own material passes),
    /// so per-frame `visible` can skip it.
    public var effectIndex: Int?

    var uniformWriterVertex: UniformWriter?
    var uniformWriterFragment: UniformWriter?

    init(shaderName: String, source: ShaderProgramSource, program: ShaderCompiler.Program,
         blending: WEBlendMode, depthTest: Bool, depthWrite: Bool, cull: Bool,
         combos: [String: Int], scope: TargetScope) {
        self.shaderName = shaderName
        self.source = source
        self.program = program
        self.blending = blending
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.cull = cull
        self.combos = combos
        self.scope = scope
        self.uniformWriterVertex = program.vertex.uniforms.map(UniformWriter.init(block:))
        self.uniformWriterFragment = program.fragment.uniforms.map(UniformWriter.init(block:))
    }
}

// MARK: - Image layer

/// One `image` object of a scene: its geometry, its layer framebuffers and the
/// ordered chain of passes that produce its contribution to the scene.
public final class ImageLayer {
    public let object: WESceneObject
    public let model: WEModel
    public let objectScope: TargetScope
    /// Every pass that compiled, including those belonging to effects that are
    /// currently switched off.
    public private(set) var allPasses: [CompiledPass] = []
    /// The passes actually drawn this frame, wired for the active effects.
    public private(set) var passes: [CompiledPass] = []
    /// One `visible` value per effect, index-aligned with `CompiledPass.effectIndex`.
    var effectVisibility: [DynamicValue] = []
    private var activeEffectMask: [Bool] = []
    /// How many of this layer's effects are currently on.
    var activeEffectCount: Int { activeEffectMask.filter { $0 }.count }
    /// A layer that exists only to run effects over what is behind it.
    var isPassthroughLayer = false
    public private(set) var size: SIMD2<Float>
    public private(set) var texture: GPUTexture?
    public private(set) var contentRatio: SIMD2<Float>
    public let isPassthrough: Bool
    public let isFullscreen: Bool
    public let alignment: String
    public private(set) var diagnostics: [String] = []
    /// True when the material's slot-0 texture could not be loaded (e.g. a video texture).
    public var missingTexture = false

    public var compositeA: MTLTexture?
    public var compositeB: MTLTexture?

    /// Per-frame state.
    public var rect = LayerRect(left: 0, right: 0, yHigh: 0, yLow: 0)
    public var screenMatrix = matrix_identity_float4x4

    /// A skinned mesh that replaces this layer's quad on one pass.
    public final class PuppetBinding {
        public let model: PuppetModel
        public let vertexBuffer: MTLBuffer
        public let indexBuffer: MTLBuffer
        public let indexCount: Int
        /// One clock per animation layer, advanced by that layer's own rate.
        public var times: [Double]
        public var boneMatrices: [simd_float4x4]
        public let modelCenter: SIMD2<Float>
        public let modelExtent: SIMD2<Float>

        public let cropOffset: SIMD2<Float>

        public init(model: PuppetModel, vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, indexCount: Int,
                    cropOffset: SIMD2<Float> = SIMD2(0, 0)) {
            self.cropOffset = cropOffset
            self.model = model
            self.vertexBuffer = vertexBuffer
            self.indexBuffer = indexBuffer
            self.indexCount = indexCount
            self.times = []
            self.boneMatrices = [simd_float4x4](repeating: matrix_identity_float4x4, count: model.bones.count)
            let space = model.modelSpace
            self.modelCenter = space.center
            self.modelExtent = space.extent
        }
    }

    public var puppet: PuppetBinding?
    /// The one pass that draws the mesh rather than the quad.
    public var puppetPassIndex: Int?
    /// `screenMatrix` folded with the mesh's own space.
    public var puppetMatrix = matrix_identity_float4x4

    /// True when this pass draws the skinned mesh.
    public func drawsPuppet(_ pass: CompiledPass) -> Bool {
        guard puppet != nil, let index = puppetPassIndex, index < passes.count else { return false }
        return passes[index] === pass
    }
    public var copyMatrix = matrix_identity_float4x4

    init(object: WESceneObject, model: WEModel, size: SIMD2<Float>, texture: GPUTexture?,
         objectScope: TargetScope, isPassthrough: Bool, isFullscreen: Bool, alignment: String) {
        self.object = object
        self.model = model
        self.size = size
        self.texture = texture
        self.objectScope = objectScope
        self.isPassthrough = isPassthrough
        self.isFullscreen = isFullscreen
        self.alignment = alignment
        self.contentRatio = texture.map { t -> SIMD2<Float> in
            t.isAnimated ? SIMD2(1, 1) : t.contentRatio
        } ?? SIMD2(1, 1)
    }

    func append(_ pass: CompiledPass) {
        pass.baseBlending = pass.blending
        allPasses.append(pass)
        passes.append(pass)
    }

    /// Re-derives the drawn passes from which effects are on.
    ///
    /// Returns false when the mask is unchanged, which is the common case: this
    /// runs every frame so that a property or a script can switch an effect on
    /// or off without the wallpaper being reloaded.
    @discardableResult
    func setActiveEffects(_ mask: [Bool]) -> Bool {
        guard mask != activeEffectMask else { return false }
        activeEffectMask = mask
        passes = allPasses.filter { pass in
            guard let effect = pass.effectIndex else { return true }
            return effect < mask.count ? mask[effect] : true
        }
        relocateBlending()
        wirePasses()
        return true
    }
    func note(_ message: String) { diagnostics.append(message) }

    /// lwe moves the first pass's blending onto the last pass and makes the first opaque.
    func relocateBlending() {
        // Start from what each material declared: this is re-run whenever the
        // active set changes, and moving an already-moved mode would lose it.
        for pass in passes { pass.blending = pass.baseBlending }
        guard passes.count > 1 else { return }
        let first = passes[0].blending
        passes[passes.count - 1].blending = first
        passes[0].blending = .normal
    }

    /// Wires destinations, inputs and the ping-pong, mirroring `CImage::setupPasses`.
    func wirePasses() {
        var main = LayerSurface.compositeA
        var sub = LayerSurface.compositeB
        var drawTo = main
        var asInput = LayerSurface.objectTexture
        var inTargetSequence = false
        var effectInput: LayerSurface?

        for (index, pass) in passes.enumerated() {
            let prevDrawTo = drawTo
            pass.isFirst = index == 0
            pass.isLastOfObject = index == passes.count - 1

            var writesToTarget = false
            pass.isFinalCandidate = false
            if let targetName = pass.targetName {
                if scopeResolves(targetName, in: pass.scope) {
                    if !inTargetSequence {
                        effectInput = asInput
                        inTargetSequence = true
                    }
                    drawTo = .named(targetName)
                    writesToTarget = true
                } else {
                    note("render target not found: \(targetName)")
                }
            }
            if !writesToTarget && pass.isLastOfObject {
                pass.isFinalCandidate = true
            }
            pass.destination = drawTo
            pass.input = asInput
            pass.previousInput = inTargetSequence ? effectInput : nil

            if writesToTarget {
                asInput = drawTo
                drawTo = prevDrawTo
            } else {
                drawTo = prevDrawTo
                // ping-pong
                drawTo = sub
                asInput = main
                swap(&main, &sub)
                inTargetSequence = false
                effectInput = nil
            }
        }
    }


    private func scopeResolves(_ name: String, in scope: TargetScope) -> Bool {
        scope.resolve(name) != nil
    }

    // MARK: Per-frame geometry

    public func updateGeometry(transform: ResolvedTransform, sceneWidth: Float, sceneHeight: Float,
                               projection: simd_float4x4, parallax: SIMD2<Float>) {
        var origin = transform.origin
        if isFullscreen {
            origin = SIMD3(sceneWidth / 2, sceneHeight / 2, 0)
        }
        rect = SceneGeometry.rect(origin: origin, size: size, scale: transform.scale,
                                  alignment: alignment, sceneWidth: sceneWidth, sceneHeight: sceneHeight)
        screenMatrix = SceneGeometry.screenMatrix(projection: projection, rect: rect,
                                                  angle: transform.angle, parallax: parallax)
        copyMatrix = isPassthrough ? screenMatrix : SceneGeometry.copyMatrix(size: size)
        if let puppet {
            // The mesh is skinned in its own space, so the transform reaches it
            // as a matrix rather than baked into the vertices.
            puppetMatrix = screenMatrix * SceneGeometry.meshMatrix(rect: rect,
                                                                    modelCenter: puppet.modelCenter,
                                                                    modelExtent: puppet.modelExtent)
        }
    }

    /// Vertices for a pass, given whether its final-pass redirect is active this frame.
    public func vertices(for pass: CompiledPass, drawsToScene: Bool) -> [QuadVertex] {
        if drawsToScene {
            // The final pass keeps whichever texcoords are current: the copy set only
            // when it is also the first pass.
            return SceneGeometry.sceneQuad(rect, uvRatio: pass.isFirst ? contentRatio : nil)
        }
        if pass.isFirst {
            if isPassthrough {
                return isFullscreen ? SceneGeometry.fullscreenPassthroughQuad
                                    : SceneGeometry.passthroughCopyQuad(rect)
            }
            return SceneGeometry.copyQuad(size: size, ratio: contentRatio)
        }
        return SceneGeometry.effectQuad
    }

    /// Text layers re-rasterise as their string changes, so the layer's texture and
    /// size are replaced in place rather than rebuilding the whole layer.
    func replaceTexture(_ texture: GPUTexture?, size: SIMD2<Float>) {
        self.texture = texture
        self.size = size
        self.contentRatio = texture.map { $0.isAnimated ? SIMD2(1, 1) : $0.contentRatio } ?? SIMD2(1, 1)
    }

    public func matrix(for pass: CompiledPass, drawsToScene: Bool) -> simd_float4x4 {
        if drawsPuppet(pass) { return puppetMatrix }
        if drawsToScene { return screenMatrix }
        if pass.isFirst { return copyMatrix }
        return matrix_identity_float4x4
    }
}

/// A drawable in scene render order: either an image layer's pass chain or a particle system.
enum SceneLayerRef {
    case image(ImageLayer)
    case particle(ParticleLayer)
}
