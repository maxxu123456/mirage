import Foundation
import Metal
import simd
import WEKit

/// Renders a Wallpaper Engine *scene* wallpaper with Metal.
///
/// The pipeline mirrors linux-wallpaperengine: every image object owns two
/// "composite" framebuffers that its material and effect passes ping-pong
/// between, and the last pass draws the result into the scene framebuffer.
/// The scene framebuffer is then presented to the drawable.
public final class SceneRenderer {
    private static let maximumRenderDimension = 16_384
    public let context: RenderContext
    public let project: WEProject
    public let locator: AssetLocator
    public let scene: WEScene
    public let store: PropertyStore
    public let textures: TextureStore

    public private(set) var sceneWidth: Int
    public private(set) var sceneHeight: Int
    public private(set) var diagnostics: [String] = []

    private let sceneScope: TargetScope
    private var layers: [ImageLayer] = []
    private var sceneTexture: MTLTexture!
    private var scratch: [String: MTLTexture] = [:]
    private var targetsNeedingInitialClear: [MTLTexture] = []
    private var targetSamplerKeys: [ObjectIdentifier: SamplerKey] = [:]
    private var renderTargetWrappers: [ObjectIdentifier: GPUTexture] = [:]
    private let preprocessor: ShaderPreprocessor
    private var lastTime: Double = -1
    private var parallaxDisplacement = SIMD2<Float>(0, 0)
    /// Set MIRAGE_DEBUG=1 to log every encoded pass.
    private let debugLogging = ProcessInfo.processInfo.environment["MIRAGE_DEBUG"] != nil

    /// Normalised pointer position, x right / y down, as `g_PointerPosition` expects.
    public var pointerPosition = SIMD2<Float>(0.5, 0.5)
    private var pointerPositionLast = SIMD2<Float>(0.5, 0.5)
    /// Audio spectrum, 64 bins; the 16/32 bin uniforms are derived from it.
    public var audioSpectrum = [Float](repeating: 0, count: 64)

    // MARK: Setup

    public init(project: WEProject, locator: AssetLocator, context: RenderContext? = nil,
                propertyOverrides: [String: JSON] = [:]) throws {
        let ctx = try context ?? RenderContext()
        self.context = ctx
        self.project = project
        self.locator = locator
        guard let sceneJSON = locator.json(project.file) else {
            throw RenderError.resourceCreation("scene file \(project.file)")
        }
        self.scene = WEScene(json: sceneJSON)
        self.store = PropertyStore(properties: project.properties, overrides: propertyOverrides)
        self.textures = TextureStore(context: ctx, locator: locator)
        self.preprocessor = ShaderPreprocessor(locator: locator)
        self.sceneScope = TargetScope(name: "scene", parent: nil)

        let size = SceneRenderer.resolveSceneSize(scene: scene, store: store)
        self.sceneWidth = size.0
        self.sceneHeight = size.1

        try buildSceneTargets()
        buildLayers()
        try clearInitialTargets()
    }

    /// `general.orthogonalprojection`, or the extent of the objects when `auto`.
    static func resolveSceneSize(scene: WEScene, store: PropertyStore?) -> (Int, Int) {
        if let w = scene.general.orthoWidth, let h = scene.general.orthoHeight, w > 0, h > 0, !scene.general.orthoAuto {
            return (min(w, maximumRenderDimension), min(h, maximumRenderDimension))
        }
        var maxW: Float = 0, maxH: Float = 0
        for object in scene.objects where object.kind == .image {
            let origin = object.origin.resolve(store).vec3 ?? .zero
            let size = object.size?.resolve(store).vec2 ?? SIMD2(0, 0)
            let extentX = abs(origin.x) + abs(size.x) / 2
            let extentY = abs(origin.y) + abs(size.y) / 2
            if extentX.isFinite { maxW = min(Float(maximumRenderDimension) / 2, max(maxW, extentX)) }
            if extentY.isFinite { maxH = min(Float(maximumRenderDimension) / 2, max(maxH, extentY)) }
        }
        if maxW < 1 || maxH < 1 { return (1920, 1080) }
        return (Int((maxW * 2).rounded(.towardZero)), Int((maxH * 2).rounded(.towardZero)))
    }

    private func buildSceneTargets() throws {
        guard let scene = makeTarget(name: "_rt_FullFrameBuffer", width: sceneWidth, height: sceneHeight) else {
            throw RenderError.resourceCreation("scene framebuffer")
        }
        sceneTexture = scene
        sceneScope.register("_rt_FullFrameBuffer", scene)
        // lwe aliases the mip-mapped frame buffer to the scene target.
        sceneScope.register("_rt_MipMappedFrameBuffer", scene)
        if let shadow = makeTarget(name: "_rt_shadowAtlas", width: sceneWidth, height: sceneHeight) {
            sceneScope.register("_rt_shadowAtlas", shadow)
            sceneScope.register("_alias_lightCookie", shadow)
        }
    }

    private func makeTarget(name: String, width: Int, height: Int,
                            samplerKey: SamplerKey = .linearClamp, clearOnce: Bool = true) -> MTLTexture? {
        guard width > 0, height > 0,
              width <= SceneRenderer.maximumRenderDimension,
              height <= SceneRenderer.maximumRenderDimension else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                            width: width, height: height,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        let texture = context.device.makeTexture(descriptor: desc)
        texture?.label = name
        if let texture {
            targetSamplerKeys[ObjectIdentifier(texture)] = samplerKey
            if clearOnce { targetsNeedingInitialClear.append(texture) }
        }
        return texture
    }

    private func clearInitialTargets() throws {
        guard !targetsNeedingInitialClear.isEmpty else { return }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw RenderError.resourceCreation("initial-clear command buffer")
        }
        for texture in targetsNeedingInitialClear {
            let descriptor = MTLRenderPassDescriptor.color(texture, clear: SIMD4(0, 0, 0, 0))
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw RenderError.resourceCreation("initial-clear encoder")
            }
            encoder.endEncoding()
        }
        commandBuffer.commit()
        targetsNeedingInitialClear.removeAll(keepingCapacity: false)
    }

    // MARK: Layer construction

    private func buildLayers() {
        let objectsById = Dictionary(scene.objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for object in renderOrder() {
            guard object.kind == .image, let imagePath = object.imagePath else { continue }
            guard let model = locator.model(imagePath) else {
                diagnostics.append("[\(object.id)] model not found: \(imagePath)")
                continue
            }
            guard let material = locator.material(model.material) else {
                diagnostics.append("[\(object.id)] material not found: \(model.material)")
                continue
            }
            let passthrough = model.passthrough || object.passthrough
            let visibleEffects = object.effects.filter { $0.visible.resolveBool(store) }
            // Passthrough layers only exist to run effects over the scene behind them.
            if passthrough && visibleEffects.isEmpty { continue }

            guard let layer = makeLayer(object: object, model: model, material: material,
                                        passthrough: passthrough, objectsById: objectsById) else { continue }
            buildPasses(layer: layer, material: material, visibleEffects: visibleEffects)
            layer.relocateBlending()
            layer.wirePasses()
            layers.append(layer)
            diagnostics.append(contentsOf: layer.diagnostics.map { "[\(object.id)] \($0)" })
        }
    }

    /// `objects[]` order with `dependencies` hoisted ahead of their dependents.
    private func renderOrder() -> [WESceneObject] {
        let byId = Dictionary(scene.objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var emitted = Set<Int>()
        var order: [WESceneObject] = []
        func visit(_ object: WESceneObject, depth: Int) {
            guard depth < 32, !emitted.contains(object.id) else { return }
            emitted.insert(object.id)
            for dependency in object.dependencies {
                if let dep = byId[dependency], dep.id != object.id { visit(dep, depth: depth + 1) }
            }
            order.append(object)
        }
        for object in scene.objects { visit(object, depth: 0) }
        return order
    }

    private func makeLayer(object: WESceneObject, model: WEModel, material: WEMaterial,
                           passthrough: Bool, objectsById: [Int: WESceneObject]) -> ImageLayer? {
        // The object's texture is slot 0 (lowest slot) of the material's first pass.
        var objectTexture: GPUTexture?
        if let first = material.passes.first {
            // `usertextures` name user properties and often resolve to nothing, so they
            // are tried first but fall back to the material's own texture list.
            // Wallpaper Engine takes the *lowest present* slot, which is normally 0 but is
            // not forced to be, a material may leave slot 0 empty and start at 1.
            var candidates: [String] = []
            if let name = first.userTextures.compactMap({ $0 }).first { candidates.append(name) }
            if let name = first.textures.compactMap({ $0 }).first { candidates.append(name) }
            for name in candidates where objectTexture == nil {
                // `_rt_*` names (e.g. composelayer's `_rt_FullFrameBuffer`) give the layer the
                // scene's size; anything else is an asset texture.
                if name.isRenderTargetName {
                    if let target = sceneScope.resolve(name) {
                        objectTexture = GPUTexture(name: name, texture: target,
                                                   samplerKey: SamplerKey(nearest: false, clamp: true, hasMips: false),
                                                   resolution: SIMD4(Float(target.width), Float(target.height),
                                                                     Float(target.width), Float(target.height)),
                                                   weFormat: .argb8888, source: nil, isRenderTarget: true)
                    }
                } else {
                    objectTexture = textures.texture(named: name)
                    if objectTexture == nil {
                        let isVideo = textures.isVideoTexture(named: name)
                        diagnostics.append("[\(object.id)] texture unavailable: \(name)\(isVideo ? " (video texture, not implemented yet)" : "")")
                    }
                }
            }
        }

        // Wallpaper Engine resolves the layer size from the material's slot-0 texture and
        // ignores scene.json's `size` whenever a texture exists. That is what makes a
        // compose layer screen-sized despite the bogus `size` those objects carry
        // (e.g. 1000x800 on a 5120x2160 scene). Preferring `size` renders such scenes blank.
        var size = object.size?.resolve(store).vec2 ?? SIMD2(0, 0)
        if let texture = objectTexture {
            size = SIMD2(texture.resolution.z, texture.resolution.w)
        } else if model.solidLayer && size == SIMD2(0, 0) {
            size = SIMD2(Float(sceneWidth), Float(sceneHeight))
        } else if size.x == 0 || size.y == 0, let w = model.width, let h = model.height {
            size = SIMD2(Float(w), Float(h))
        }
        if model.fullscreen {
            size = SIMD2(Float(sceneWidth), Float(sceneHeight))
        }
        size = SIMD2(size.x.isFinite ? min(Float(SceneRenderer.maximumRenderDimension), max(1, size.x)) : 1,
                     size.y.isFinite ? min(Float(SceneRenderer.maximumRenderDimension), max(1, size.y)) : 1)

        let scope = TargetScope(name: "object\(object.id)", parent: sceneScope)
        let alignmentRaw = object.raw["horizontalalign"].string ?? object.raw["alignment"].string ?? "center"
        let missingTexture = objectTexture == nil
        let layer = ImageLayer(object: object, model: model, size: size, texture: objectTexture,
                               objectScope: scope, isPassthrough: passthrough,
                               isFullscreen: model.fullscreen, alignment: alignmentRaw)
        layer.missingTexture = missingTexture

        let w = Int(size.x.rounded()), h = Int(size.y.rounded())
        let samplerKey = objectTexture?.samplerKey ?? .linearClamp
        if let a = makeTarget(name: "_rt_imageLayerComposite_\(object.id)_a", width: w, height: h,
                              samplerKey: samplerKey),
           let b = makeTarget(name: "_rt_imageLayerComposite_\(object.id)_b", width: w, height: h,
                              samplerKey: samplerKey) {
            layer.compositeA = a
            layer.compositeB = b
            // Registered scene-wide: other objects may sample them by name.
            sceneScope.register("_rt_imageLayerComposite_\(object.id)_a", a)
            sceneScope.register("_rt_imageLayerComposite_\(object.id)_b", b)
        } else {
            diagnostics.append("[\(object.id)] could not allocate layer composites (\(w)x\(h))")
            return nil
        }
        return layer
    }

    /// Description of one draw before it is compiled.
    private struct PassSpec {
        let materialPass: WEMaterialPass
        let override: WEEffectPassOverride?
        let binds: [WEEffectBind]
        let target: String?
        let scope: TargetScope
        let effectIndex: Int?
        let shaderOverride: String?
        let extraCombos: [String: Int]
    }

    private func buildPasses(layer: ImageLayer, material: WEMaterial, visibleEffects: [WEEffectInstance]) {
        var specs: [PassSpec] = []
        for pass in material.passes {
            specs.append(PassSpec(materialPass: pass, override: nil, binds: [], target: nil,
                                  scope: layer.objectScope, effectIndex: nil, shaderOverride: nil, extraCombos: [:]))
        }

        for (effectIndex, instance) in visibleEffects.enumerated() {
            guard let effect = locator.effect(instance.file) else {
                layer.note("effect not found: \(instance.file)")
                continue
            }
            let scope = TargetScope(name: "effect\(instance.id)", parent: layer.objectScope)
            for fbo in effect.fbos {
                let scale = max(fbo.scale, 0.0001)
                let width = layer.size.x / scale, height = layer.size.y / scale
                let w = width.isFinite ? min(SceneRenderer.maximumRenderDimension, max(1, Int(width.rounded(.towardZero)))) : 1
                let h = height.isFinite ? min(SceneRenderer.maximumRenderDimension, max(1, Int(height.rounded(.towardZero)))) : 1
                if let texture = makeTarget(name: fbo.name, width: w, height: h,
                                            samplerKey: layer.texture?.samplerKey ?? .linearClamp) {
                    scope.register(fbo.name, texture)
                }
            }
            var overrideIndex = 0
            for effectPass in effect.passes {
                guard let materialPath = effectPass.material else {
                    // A material-less pass must be a copy command.
                    if effectPass.command == "copy", let source = effectPass.source, let target = effectPass.target {
                        let copyPass = WEMaterialPass(json: .object([
                            "shader": .string("commands/copy"),
                            "blending": .string("normal"),
                            "cullmode": .string("nocull"),
                            "depthtest": .string("disabled"),
                            "depthwrite": .string("disabled"),
                            "textures": .array([.string(source)]),
                        ]))
                        specs.append(PassSpec(materialPass: copyPass, override: nil, binds: [], target: target,
                                              scope: scope, effectIndex: effectIndex, shaderOverride: nil, extraCombos: [:]))
                    } else {
                        layer.note("skipping effect pass without material in \(instance.file)")
                    }
                    continue
                }
                guard let effectMaterial = locator.material(materialPath) else {
                    layer.note("effect material not found: \(materialPath)")
                    overrideIndex += 1
                    continue
                }
                let override = overrideIndex < instance.passOverrides.count ? instance.passOverrides[overrideIndex] : nil
                for pass in effectMaterial.passes {
                    specs.append(PassSpec(materialPass: pass, override: override, binds: effectPass.binds,
                                          target: effectPass.target, scope: scope, effectIndex: effectIndex,
                                          shaderOverride: nil, extraCombos: effectPass.combos))
                }
                overrideIndex += 1
            }
        }

        if layer.object.colorBlendMode > 0 {
            if let passthroughMaterial = locator.material("materials/util/effectpassthrough.json"),
               let pass = passthroughMaterial.passes.first {
                specs.append(PassSpec(materialPass: pass, override: nil, binds: [], target: nil,
                                      scope: layer.objectScope, effectIndex: nil, shaderOverride: nil,
                                      extraCombos: ["BLENDMODE": layer.object.colorBlendMode]))
            }
        }

        for (index, spec) in specs.enumerated() {
            guard let compiled = compile(spec: spec, layer: layer) else { continue }
            if let target = spec.target { layer.passTargets[layer.passes.count] = target }
            _ = index
            layer.append(compiled)
        }
    }

    // MARK: Pass compilation

    private func compile(spec: PassSpec, layer: ImageLayer) -> CompiledPass? {
        let shaderName = spec.shaderOverride ?? spec.materialPass.shader
        let source: ShaderProgramSource
        do {
            source = try preprocessor.load(shaderName)
        } catch {
            layer.note("shader not found: \(shaderName)")
            return nil
        }

        // Texture names visible to the sampler-annotation combo logic.
        var passTextures: [Int: String] = [:]
        for (index, name) in spec.materialPass.textures.enumerated() { if let name { passTextures[index] = name } }
        for (index, name) in spec.materialPass.userTextures.enumerated() { if let name { passTextures[index] = name } }
        var overrideTextures: [Int: String] = [:]
        if let override = spec.override {
            for (index, name) in override.textures.enumerated() { if let name { overrideTextures[index] = name } }
        }

        var materialCombos = spec.materialPass.combos
        if let format = layer.texture?.weFormat {
            if format == .rg88 { materialCombos["TEX0FORMAT"] = 8 }
            else if format == .r8 { materialCombos["TEX0FORMAT"] = 9 }
        }
        for (name, value) in spec.extraCombos { materialCombos[name.uppercased()] = value }
        var overrideCombos: [String: Int] = [:]
        if let override = spec.override {
            for (name, value) in override.combos { overrideCombos[name.uppercased()] = value }
        }

        var combos: [String: Int] = [:]
        // Lowest priority first; later assignments win.
        for decl in source.combos { combos[decl.name] = decl.defaultValue }
        for (name, value) in SceneRenderer.samplerCombos(source: source, passTextures: passTextures,
                                                         overrideTextures: overrideTextures,
                                                         materialCombos: materialCombos,
                                                         overrideCombos: overrideCombos) {
            combos[name] = value
        }
        for (name, value) in materialCombos { combos[name] = value }
        for (name, value) in overrideCombos { combos[name] = value }

        let program: ShaderCompiler.Program
        do {
            program = try ShaderCompiler.shared.compile(source: source, combos: combos)
        } catch {
            layer.note("shader \(shaderName) failed: \(String(describing: error).prefix(200))")
            return nil
        }

        let pass = CompiledPass(shaderName: shaderName, source: source, program: program,
                                blending: spec.materialPass.blending,
                                depthTest: spec.materialPass.depthTest,
                                depthWrite: spec.materialPass.depthWrite,
                                cull: spec.materialPass.cullMode == "normal",
                                combos: combos, scope: spec.scope)
        pass.effectIndex = spec.effectIndex
        buildTextureSlots(pass: pass, spec: spec, layer: layer)
        buildConstants(pass: pass, spec: spec)
        return pass
    }

    /// `uniform sampler2D g_TextureN; // {"combo":"MASK","require":{…}}`, emit the combo
    /// when the slot is actually bound, or when the `require` clause says so.
    static func samplerCombos(source: ShaderProgramSource, passTextures: [Int: String],
                              overrideTextures: [Int: String], materialCombos: [String: Int],
                              overrideCombos: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        let uniforms = ShaderPreprocessor.extractUniforms(source.vertex)
            + ShaderPreprocessor.extractUniforms(source.fragment)
        for uniform in uniforms {
            guard uniform.isSampler, let slot = uniform.textureSlot else { continue }
            guard let combo = uniform.annotation["combo"].string?.uppercased() else { continue }
            let slotUsed = passTextures[slot] != nil || overrideTextures[slot] != nil
            var required = slotUsed
            var value = 1
            if !required, let require = uniform.annotation["require"].object {
                let requireAny = uniform.annotation["requireany"].bool ?? false
                if requireAny {
                    for (macro, wanted) in require {
                        let name = macro.uppercased()
                        let current = materialCombos[name]
                        if current == nil || overrideCombos[name] != nil || current != wanted.int {
                            required = true
                            break
                        }
                    }
                } else {
                    required = true
                    for (macro, wanted) in require {
                        let name = macro.uppercased()
                        if (materialCombos[name] != nil || overrideCombos[name] != nil),
                           materialCombos[name] == wanted.int {
                            required = false
                            break
                        }
                    }
                }
            }
            if required && !slotUsed {
                let fallback = uniform.annotation["default"]
                if fallback.isNull { required = false }
                else if materialCombos[combo] != nil || overrideCombos[combo] != nil { required = false }
                else { value = fallback.int ?? 1 }
            }
            if required { out[combo] = value }
        }
        return out
    }

    private func buildTextureSlots(pass: CompiledPass, spec: PassSpec, layer: ImageLayer) {
        func prepend(_ slot: Int, _ entry: TextureSlotEntry) {
            pass.slots[slot, default: []].insert(entry, at: 0)
        }
        func entry(for name: String) -> TextureSlotEntry? {
            if name.isRenderTargetName { return .target(name) }
            guard let texture = textures.texture(named: name) else {
                layer.note("texture not found: \(name)")
                return nil
            }
            return .asset(texture)
        }

        // 1. Vertex defaults start each chain; the first declaration for a slot wins.
        var seenVertexDefaults = Set<Int>()
        for uniform in ShaderPreprocessor.extractUniforms(source(of: pass).vertex) where uniform.isSampler {
            guard let slot = uniform.textureSlot, let name = uniform.annotation["default"].string,
                  seenVertexDefaults.insert(slot).inserted else { continue }
            if !name.isEmpty, let e = entry(for: name) { pass.slots[slot] = [e] }
        }
        // 2. Fragment defaults prepend, retaining the vertex default as a fallback.
        var seenFragmentDefaults = Set<Int>()
        for uniform in ShaderPreprocessor.extractUniforms(source(of: pass).fragment) where uniform.isSampler {
            guard let slot = uniform.textureSlot, let name = uniform.annotation["default"].string,
                  seenFragmentDefaults.insert(slot).inserted else { continue }
            if !name.isEmpty, let e = entry(for: name) { prepend(slot, e) }
        }
        // 3-4. Material textures.
        for (index, name) in spec.materialPass.textures.enumerated() {
            guard let name, let e = entry(for: name) else { continue }
            prepend(index, e)
        }
        for (index, name) in spec.materialPass.userTextures.enumerated() {
            guard let name, let e = entry(for: name) else { continue }
            prepend(index, e)
        }
        // 5-6. Effect pass overrides.
        if let override = spec.override {
            for (index, name) in override.textures.enumerated() {
                guard let name, let e = entry(for: name) else { continue }
                prepend(index, e)
            }
            for (index, name) in override.userTextures.enumerated() {
                guard let name, let e = entry(for: name) else { continue }
                prepend(index, e)
            }
        }
        // 7. Binds, highest priority.
        for bind in spec.binds {
            if bind.name == "previous" {
                prepend(bind.index, .passInput)
            } else if let resolved = entry(for: bind.name) {
                prepend(bind.index, resolved)
            } else if let placeholder = textures.transparent {
                prepend(bind.index, .asset(placeholder))
            }
        }
    }

    private func source(of pass: CompiledPass) -> ShaderProgramSource { pass.source }

    private func buildConstants(pass: CompiledPass, spec: PassSpec) {
        // Annotation defaults.
        for uniform in pass.source.uniforms where !uniform.isSampler {
            guard !uniform.defaultValue.isNull, let value = ShaderValue(json: uniform.defaultValue) else { continue }
            pass.constants[uniform.name] = value
        }
        func uniformName(for key: String) -> String? {
            if let match = pass.source.uniforms.first(where: { $0.materialKey == key }) { return match.name }
            // wsr's fallback: the GLSL name minus its "g_"/"u_" prefix.
            return pass.source.uniforms.first(where: { $0.name.count > 2 && String($0.name.dropFirst(2)) == key })?.name
        }
        func apply(_ values: [String: JSON]) {
            for (key, json) in values {
                guard let name = uniformName(for: key) else { continue }
                let dynamic = DynamicValue.parse(json)
                if dynamic.isBound {
                    pass.boundConstants.append((name, dynamic))
                    if let value = ShaderValue(json: dynamic.value) { pass.constants[name] = value }
                } else if let value = ShaderValue(json: json) {
                    pass.constants[name] = value
                }
            }
        }
        apply(spec.materialPass.constantShaderValues)
        if let override = spec.override { apply(override.constantShaderValues) }
    }

    // MARK: Frame

    /// Renders one frame into `target`. `time` is the wallpaper's elapsed running time
    /// in seconds (the caller owns the epoch), and feeds `g_Time` and every animation.
    /// The scene is composed at its own resolution and then presented into `target`.
    public func render(into target: MTLTexture, time: Double, commandBuffer: MTLCommandBuffer) {
        if lastTime < 0 { lastTime = time }
        let safeTime = time.isFinite ? time : 0
        let floatTime = Float(safeTime)
        let elapsed = floatTime.isFinite ? floatTime : 0
        let delta = safeTime - lastTime
        let dt = Float(delta.isFinite ? min(0.1, max(0, delta)) : 0)
        lastTime = safeTime
        updateParallax(dt: dt)

        // Wallpaper Engine ignores `clearenabled` and always clears the scene target.
        let clearColor = scene.general.clearColor.resolve(store).vec3 ?? SIMD3(repeating: 1)
        let descriptor = MTLRenderPassDescriptor.color(sceneTexture,
                                                       clear: SIMD4(Double(clearColor.x), Double(clearColor.y), Double(clearColor.z), 1))
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.label = "mirage.clearScene"
            encoder.endEncoding()
        }

        let projection = SceneGeometry.sceneProjection(width: Float(sceneWidth), height: Float(sceneHeight),
                                                       nearZ: scene.camera.nearZ, farZ: scene.camera.farZ,
                                                       zoom: scene.general.zoom.resolveFloat(store, default: 1))
        let objectsById = Dictionary(scene.objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var globals = ShaderValueBag()
        fillSceneGlobals(&globals, elapsed: elapsed, dt: dt)

        for layer in layers {
            let visible = layer.object.visible.resolveBool(store, default: true)
            guard visible else { continue }
            let transform = SceneGeometry.resolveTransform(of: layer.object, objects: objectsById, store: store)
            let parallax = parallaxOffset(for: layer)
            layer.updateGeometry(transform: transform, sceneWidth: Float(sceneWidth), sceneHeight: Float(sceneHeight),
                                 projection: projection, parallax: parallax)
            for pass in layer.passes {
                encode(pass: pass, layer: layer, visible: visible, globals: globals,
                       elapsed: elapsed, commandBuffer: commandBuffer)
            }
        }

        present(into: target, commandBuffer: commandBuffer)
    }

    private func updateParallax(dt: Float) {
        guard scene.general.cameraParallax.resolveBool(store, default: false) else { return }
        let amount = scene.general.cameraParallaxAmount.resolveFloat(store, default: 1)
        let influence = scene.general.cameraParallaxMouseInfluence.resolveFloat(store, default: 1)
        let delay = simd_clamp(scene.general.cameraParallaxDelay.resolveFloat(store, default: 0.1) * dt, 0, 1)
        let target = (pointerPosition - SIMD2(0.5, 0.5)) * amount * influence
        parallaxDisplacement = simd_mix(parallaxDisplacement, target, SIMD2(repeating: delay))
    }

    private func parallaxOffset(for layer: ImageLayer) -> SIMD2<Float> {
        guard scene.general.cameraParallax.resolveBool(store, default: false) else { return .zero }
        let amount = scene.general.cameraParallaxAmount.resolveFloat(store, default: 1)
        let depth = layer.object.parallaxDepth.resolve(store).vec2 ?? SIMD2(0, 0)
        let reference = Float(sceneWidth)
        return SIMD2((depth.x + amount) * parallaxDisplacement.x * reference,
                     (depth.y + amount) * parallaxDisplacement.y * reference)
    }

    private func fillSceneGlobals(_ bag: inout ShaderValueBag, elapsed: Float, dt: Float) {
        bag.set("g_Time", elapsed)
        let calendar = Calendar.current
        let now = calendar.dateComponents([.hour, .minute], from: Date())
        let dayTime = Float((now.hour ?? 0) * 60 + (now.minute ?? 0)) / (24 * 60)
        bag.set("g_Daytime", dayTime)
        bag.set("g_DayTime", dayTime)
        bag.set("g_Frametime", dt)
        bag.set("g_PointerPosition", pointerPosition)
        bag.set("g_PointerPositionLast", pointerPositionLast)
        pointerPositionLast = pointerPosition
        let influence = scene.general.cameraParallaxMouseInfluence.resolveFloat(store, default: 1)
        bag.set("g_ParallaxPosition", SIMD2(0.5, 0.5) + (SIMD2(pointerPosition.x, -pointerPosition.y) - SIMD2(0.5, 0.5)) * influence)
        bag.set("g_TexelSize", SIMD2(1 / Float(sceneWidth), 1 / Float(sceneHeight)))
        bag.set("g_TexelSizeHalf", SIMD2(0.5 / Float(sceneWidth), 0.5 / Float(sceneHeight)))
        bag.set("g_Screen", SIMD3(Float(sceneWidth), Float(sceneHeight), Float(sceneWidth) / Float(sceneHeight)))
        bag.set("g_TextureReductionScale", 1)
        bag.set("g_LightAmbientColor", scene.general.ambientColor.resolve(store).vec3 ?? .zero)
        bag.set("g_LightSkylightColor", scene.general.skylightColor.resolve(store).vec3 ?? .zero)
        bag.set("g_NormalModelMatrix", .mat3(matrix_identity_float3x3))
        bag.set("g_EffectTextureProjectionMatrix", matrix_identity_float4x4)
        bag.set("g_EffectTextureProjectionMatrixInverse", matrix_identity_float4x4)
        bag.set("g_ViewProjectionMatrix", matrix_identity_float4x4)
        let spectrum16 = resample(audioSpectrum, to: 16)
        let spectrum32 = resample(audioSpectrum, to: 32)
        let spectrum64 = resample(audioSpectrum, to: 64)
        bag["g_AudioSpectrum16Left"] = .floatArray(spectrum16)
        bag["g_AudioSpectrum16Right"] = .floatArray(spectrum16)
        bag["g_AudioSpectrum32Left"] = .floatArray(spectrum32)
        bag["g_AudioSpectrum32Right"] = .floatArray(spectrum32)
        bag["g_AudioSpectrum64Left"] = .floatArray(spectrum64)
        bag["g_AudioSpectrum64Right"] = .floatArray(spectrum64)
    }

    private func resample(_ values: [Float], to count: Int) -> [Float] {
        guard values.count != count, !values.isEmpty else { return values }
        let stride = values.count / count
        guard stride > 1 else { return Array(values.prefix(count)) + [Float](repeating: 0, count: max(0, count - values.count)) }
        return (0..<count).map { i in
            let slice = values[(i * stride)..<min(values.count, (i + 1) * stride)]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }

    // MARK: Encoding

    private func texture(for surface: LayerSurface, layer: ImageLayer, scope: TargetScope) -> MTLTexture? {
        switch surface {
        case .objectTexture: return layer.texture?.texture
        case .compositeA: return layer.compositeA
        case .compositeB: return layer.compositeB
        case .named(let name): return scope.resolve(name)
        case .scene: return sceneTexture
        }
    }

    private func gpuTexture(for surface: LayerSurface, layer: ImageLayer, scope: TargetScope) -> GPUTexture? {
        if case .objectTexture = surface { return layer.texture }
        guard let texture = texture(for: surface, layer: layer, scope: scope) else { return nil }
        let identifier = ObjectIdentifier(texture)
        if let wrapper = renderTargetWrappers[identifier] { return wrapper }
        let wrapper = GPUTexture(name: texture.label ?? "rt", texture: texture,
                                 samplerKey: targetSamplerKeys[identifier] ?? .linearClamp,
                                 resolution: SIMD4(Float(texture.width), Float(texture.height),
                                                   Float(texture.width), Float(texture.height)),
                                 weFormat: .argb8888, source: nil, isRenderTarget: true)
        renderTargetWrappers[identifier] = wrapper
        return wrapper
    }

    private func encode(pass: CompiledPass, layer: ImageLayer, visible: Bool, globals: ShaderValueBag,
                        elapsed: Float, commandBuffer: MTLCommandBuffer) {
        let drawsToScene = pass.isFinalCandidate && visible
        let destinationSurface: LayerSurface = drawsToScene ? .scene : pass.destination
        guard let destination = texture(for: destinationSurface, layer: layer, scope: pass.scope) else {
            if debugLogging { print("  [\(layer.object.id)] \(pass.shaderName): NO DESTINATION \(destinationSurface)") }
            return
        }
        if !drawsToScene && pass.isFinalCandidate && !visible { return }

        // Resolve texture slots.
        var bound: [Int: GPUTexture] = [:]
        let inputTexture = gpuTexture(for: pass.input, layer: layer, scope: pass.scope)
        let previousTexture = pass.previousInput.flatMap { gpuTexture(for: $0, layer: layer, scope: pass.scope) }
        var maxSlot = 0
        for binding in pass.program.fragment.textures + pass.program.vertex.textures {
            if binding.name.hasPrefix("g_Texture"),
               let slot = Int(binding.name.dropFirst("g_Texture".count)), (0..<128).contains(slot) {
                maxSlot = max(maxSlot, slot)
            }
        }
        for slot in 0...max(maxSlot, 0) {
            var resolved: GPUTexture?
            for entry in pass.slots[slot] ?? [] {
                switch entry {
                case .asset(let texture): resolved = texture
                case .target(let name):
                    if let texture = pass.scope.resolve(name) {
                        resolved = gpuTexture(for: .named(name), layer: layer, scope: pass.scope)
                        _ = texture
                    }
                case .passInput: resolved = previousTexture ?? inputTexture
                }
                if resolved != nil { break }
            }
            if resolved == nil { resolved = previousTexture ?? inputTexture }
            if let resolved { bound[slot] = resolved }
        }

        // Self-read protection: a pass may not sample the texture it is writing.
        for (slot, texture) in bound where texture.texture === destination {
            if let copy = scratchCopy(of: texture.texture, commandBuffer: commandBuffer) {
                bound[slot] = GPUTexture(name: texture.name + ".copy", texture: copy, samplerKey: texture.samplerKey,
                                         resolution: texture.resolution, weFormat: texture.weFormat,
                                         source: texture.source, isRenderTarget: true)
            } else {
                bound.removeValue(forKey: slot)
            }
        }

        // Uniforms.
        var bag = ShaderValueBag()
        for (name, value) in pass.constants { bag.set(name, value) }
        for (name, dynamic) in pass.boundConstants {
            if let value = ShaderValue(json: dynamic.resolve(store)) { bag.set(name, value) }
        }
        bag.merge(globals)
        fillObjectValues(&bag, layer: layer)

        let mvp = layer.matrix(for: pass, drawsToScene: drawsToScene)
        bag.set("g_ModelViewProjectionMatrix", mvp)
        bag.set("g_EffectModelViewProjectionMatrix", mvp)
        bag.set("g_ModelViewProjectionMatrixInverse", mvp.inverse)
        let modelMatrix = SceneGeometry.copyMatrix(size: layer.size)
        bag.set("g_ModelMatrix", modelMatrix)
        bag.set("g_EffectModelMatrix", modelMatrix)
        bag.set("g_ModelMatrixInverse", modelMatrix.inverse)

        for (slot, texture) in bound {
            bag.set("g_Texture\(slot)Resolution", .vec4(texture.resolution))
            if let (rotation, translation) = texture.spriteTransform(at: Double(elapsed)) {
                bag.set("g_Texture\(slot)Rotation", .vec4(rotation))
                bag.set("g_Texture\(slot)Translation", .vec2(translation))
            }
        }

        // Encode.
        let descriptor = MTLRenderPassDescriptor.color(destination, clear: nil)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "\(layer.object.name).\(pass.shaderName)"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(destination.width), height: Double(destination.height),
                                        znear: 0, zfar: 1))
        encoder.setCullMode(pass.cull ? .back : .none)
        encoder.setFrontFacing(.counterClockwise)

        let writesAlpha = !pass.isLastOfObject
        let blend = BlendState(mode: pass.blending, writesAlpha: writesAlpha)
        guard let pipeline = try? context.pipeline(program: pass.program, layout: .quad,
                                                   pixelFormat: destination.pixelFormat, blend: blend,
                                                   label: pass.shaderName) else {
            if debugLogging { print("  [\(layer.object.id)] \(pass.shaderName): PIPELINE FAILED") }
            encoder.endEncoding()
            return
        }
        encoder.setRenderPipelineState(pipeline)

        let vertices = layer.vertices(for: pass, drawsToScene: drawsToScene)
        vertices.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                encoder.setVertexBytes(base, length: bytes.count, index: BufferIndex.vertices)
            }
        }
        encoder.setVertexBuffer(context.zeroBuffer, offset: 0, index: BufferIndex.zeroFill)

        if let writer = pass.uniformWriterVertex {
            var bytes = [UInt8](repeating: 0, count: writer.byteCount)
            writer.write(bag, into: &bytes)
            if (0..<BufferIndex.zeroFill).contains(writer.block.bufferIndex) {
                bytes.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { encoder.setVertexBytes(base, length: raw.count, index: writer.block.bufferIndex) }
                }
            }
        }
        if let writer = pass.uniformWriterFragment {
            var bytes = [UInt8](repeating: 0, count: writer.byteCount)
            writer.write(bag, into: &bytes)
            if (0..<BufferIndex.zeroFill).contains(writer.block.bufferIndex) {
                bytes.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { encoder.setFragmentBytes(base, length: raw.count, index: writer.block.bufferIndex) }
                }
            }
        }

        // A slot that resolves to nothing gets Wallpaper Engine's white default, except
        // when the object's own texture is missing, white would blow out the whole scene.
        let fallback = layer.missingTexture ? textures.transparent : textures.white
        for binding in pass.fragmentTextureBindings {
            guard (0..<128).contains(binding.index) else { continue }
            let texture = bound[binding.slot] ?? fallback
            guard let sampler = context.sampler(texture?.samplerKey ?? .linearClamp) else {
                encoder.endEncoding()
                return
            }
            encoder.setFragmentTexture(texture?.texture, index: binding.index)
            encoder.setFragmentSamplerState(sampler, index: binding.index)
        }
        for binding in pass.vertexTextureBindings {
            guard (0..<128).contains(binding.index) else { continue }
            let texture = bound[binding.slot] ?? fallback
            guard let sampler = context.sampler(texture?.samplerKey ?? .linearClamp) else {
                encoder.endEncoding()
                return
            }
            encoder.setVertexTexture(texture?.texture, index: binding.index)
            encoder.setVertexSamplerState(sampler, index: binding.index)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        if debugLogging {
            let slots = bound.keys.sorted().compactMap { slot in bound[slot].map { "\(slot):\($0.name)" } }.joined(separator: ",")
            let fragBindings = pass.fragmentTextureBindings.map { "s\($0.slot)@\($0.index)" }.joined(separator: ",")
            let vertexExtent = vertices.count > 5
                ? "(\(vertices[0].x),\(vertices[0].y))->(\(vertices[5].x),\(vertices[5].y))"
                : "empty"
            print("  [\(layer.object.id)] \(pass.shaderName) -> \(destination.label ?? "?") \(destination.width)x\(destination.height)"
                + " blend=\(pass.blending) scene=\(drawsToScene) slots=[\(slots)] frag=[\(fragBindings)]"
                + " v0=\(vertexExtent)"
                + " rot=\(bag["g_Texture0Rotation"].map { String(describing: $0) } ?? "-")"
                + " trans=\(bag["g_Texture0Translation"].map { String(describing: $0) } ?? "-")"
                + " ubo=v\(pass.uniformWriterVertex?.byteCount ?? 0)/f\(pass.uniformWriterFragment?.byteCount ?? 0)")
        }
    }

    private func fillObjectValues(_ bag: inout ShaderValueBag, layer: ImageLayer) {
        let alpha = layer.object.alpha.resolveFloat(store, default: 1)
        let color = layer.object.color.resolve(store).vec3 ?? SIMD3(repeating: 1)
        bag.set("g_Brightness", layer.object.brightness.resolveFloat(store, default: 1))
        bag.set("g_UserAlpha", alpha)
        bag.set("g_Alpha", alpha)
        bag.set("g_Color", color)
        bag.set("g_Color4", SIMD4(color.x, color.y, color.z, alpha))
        bag.setIfAbsent("g_CompositeColor", .vec3(color))
    }

    private func scratchCopy(of texture: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let key = "\(texture.width)x\(texture.height)x\(texture.pixelFormat.rawValue)"
        let copy: MTLTexture
        if let existing = scratch[key] {
            copy = existing
        } else {
            guard let made = makeTarget(name: "scratch.\(key)", width: texture.width, height: texture.height,
                                        clearOnce: false) else { return nil }
            scratch[key] = made
            copy = made
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        return copy
    }

    // MARK: Present

    private func present(into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor.color(target, clear: SIMD4(0, 0, 0, 1))
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let pipeline = try? context.blitPipeline(pixelFormat: target.pixelFormat) else { return }
        encoder.label = "mirage.present"
        // "default" WE scaling: cover the target, cropping the axis whose aspect differs.
        let sceneAspect = Float(sceneWidth) / Float(sceneHeight)
        let targetAspect = Float(target.width) / Float(target.height)
        var scale = SIMD2<Float>(1, 1)
        if targetAspect > sceneAspect {
            scale.y = sceneAspect / targetAspect
        } else if targetAspect < sceneAspect {
            scale.x = targetAspect / sceneAspect
        }
        let offset = (SIMD2<Float>(1, 1) - scale) * 0.5
        // SPIRV-Cross's FLIP_VERTEX_Y already turns Wallpaper Engine's y-up scene space
        // into Metal's top-left texture origin, so the scene target's row 0 *is* the top
        // of the image and the present pass must not flip again.
        let params = RenderContext.BlitParams(uvScale: scale, uvOffset: offset, flipY: false)
        context.encodeBlit(encoder, source: sceneTexture, pipeline: pipeline, params: params)
        encoder.endEncoding()
    }

    // MARK: Offscreen

    /// Renders a single frame and returns straight-alpha RGBA8 bytes.
    public func renderOffscreen(width: Int, height: Int, time: Double) throws -> Data {
        guard width > 0, height > 0,
              width <= SceneRenderer.maximumRenderDimension,
              height <= SceneRenderer.maximumRenderDimension,
              let byteCount = WEPixelLayout.rgba8.checkedByteCount(width: width, height: height),
              byteCount <= WEPixelLayout.maximumAllocationByteCount else {
            throw RenderError.resourceCreation("valid offscreen target dimensions")
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let output = context.device.makeTexture(descriptor: desc) else {
            throw RenderError.resourceCreation("offscreen target")
        }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw RenderError.resourceCreation("command buffer")
        }
        render(into: output, time: time, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }

        let bytesPerRow = byteCount / height
        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                output.getBytes(base, bytesPerRow: bytesPerRow,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
        }
        return Data(bytes)
    }

    /// Human-readable summary of what was built, for `wetool`.
    public var summary: String {
        var lines: [String] = ["scene \(sceneWidth)x\(sceneHeight), \(layers.count) image layers"]
        for layer in layers {
            let passNames = layer.passes.map { pass -> String in
                let dest: String
                switch pass.destination {
                case .compositeA: dest = "A"
                case .compositeB: dest = "B"
                case .named(let n): dest = n
                case .scene: dest = "scene"
                case .objectTexture: dest = "tex"
                }
                return "\(pass.shaderName)->\(pass.isFinalCandidate ? "scene?" : dest)"
            }
            lines.append("  [\(layer.object.id)] \(layer.object.name) size=\(Int(layer.size.x))x\(Int(layer.size.y)) passes=\(passNames)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Texture binding helpers

extension CompiledPass {
    struct TextureBinding {
        let slot: Int
        let index: Int
    }

    /// Maps `g_TextureN` names to the Metal texture indices SPIRV-Cross assigned.
    var fragmentTextureBindings: [TextureBinding] {
        program.fragment.textures.compactMap { binding in
            guard binding.name.hasPrefix("g_Texture"),
                  let slot = Int(binding.name.dropFirst("g_Texture".count)), (0..<128).contains(slot) else {
                return TextureBinding(slot: 0, index: binding.index)
            }
            return TextureBinding(slot: slot, index: binding.index)
        }
    }

    var vertexTextureBindings: [TextureBinding] {
        program.vertex.textures.compactMap { binding in
            guard binding.name.hasPrefix("g_Texture"),
                  let slot = Int(binding.name.dropFirst("g_Texture".count)), (0..<128).contains(slot) else {
                return TextureBinding(slot: 0, index: binding.index)
            }
            return TextureBinding(slot: slot, index: binding.index)
        }
    }
}

extension simd_float4x4 {
    var inverse: simd_float4x4 { simd_inverse(self) }
}
