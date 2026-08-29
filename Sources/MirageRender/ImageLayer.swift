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
    public private(set) var passes: [CompiledPass] = []
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

    func append(_ pass: CompiledPass) { passes.append(pass) }
    func note(_ message: String) { diagnostics.append(message) }

    /// lwe moves the first pass's blending onto the last pass and makes the first opaque.
    func relocateBlending() {
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
            if let targetName = passTargets[index] {
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

    /// `target` name per pass index, filled while building.
    var passTargets: [Int: String] = [:]

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

    public func matrix(for pass: CompiledPass, drawsToScene: Bool) -> simd_float4x4 {
        if drawsToScene { return screenMatrix }
        if pass.isFirst { return copyMatrix }
        return matrix_identity_float4x4
    }
}
