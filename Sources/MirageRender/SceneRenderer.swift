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
    /// Pixels per scene unit for every render target.
    ///
    /// A wallpaper is authored at its own resolution (`Pixel City` is 5120x2160)
    /// and every pass costs that many pixels no matter how big the display is.
    /// Geometry stays in scene units, so only the targets shrink and the image is
    /// the same one, drawn at the size it will actually be seen at.
    public private(set) var renderScale: Float = 1
    /// The part of the scene the display actually shows, in scene units.
    ///
    /// `present` covers the target and crops the axis whose aspect differs, so
    /// on a 16:9 screen a wallpaper authored at 21:9 has a quarter of every
    /// full-screen pass rendered and then thrown away. Cropping here instead
    /// costs nothing visually, because those pixels were never on screen.
    public private(set) var visibleWidth: Int
    public private(set) var visibleHeight: Int
    public var renderWidth: Int { scaled(visibleWidth) }
    public var renderHeight: Int { scaled(visibleHeight) }

    /// Rounds a cropped extent so that what is removed splits evenly either side.
    static func centredCrop(_ extent: Float, of whole: Int) -> Int {
        var value = max(1, min(whole, Int(extent.rounded())))
        if (whole - value) % 2 != 0 { value = max(1, value - 1) }
        return value
    }

    /// A scene-unit length in target pixels, never smaller than one.
    func scaled(_ value: Int) -> Int {
        guard renderScale < 1 else { return value }
        return max(1, Int((Float(value) * renderScale).rounded()))
    }
    public private(set) var diagnostics: [String] = []

    private let sceneScope: TargetScope
    private var layers: [ImageLayer] = []
    /// Images and particle systems in scene render order, so a particle system that sits
    /// between two image layers is composited between them.
    private var orderedLayers: [SceneLayerRef] = []
    /// Text layers rasterise their string to a texture and then go through the normal
    /// image pass chain, so effects and colour blending work on them like any other layer.
    private var textLayers: [ObjectIdentifier: TextBinding] = [:]
    private lazy var textRasterizer = TextRasterizer(device: context.device, locator: locator)
    /// Drives `{"script": …}` values. Nil when the wallpaper has none, so a scene
    /// without scripts never pays for a JavaScript context.
    private var scripts: ScriptRuntime?
    private var sceneTexture: MTLTexture!
    private var scratch: [String: MTLTexture] = [:]
    /// Effects Mirage manufactures rather than loads from disk, currently only
    /// the bloom chain, which Wallpaper Engine ships as engine code and not as
    /// an `effect.json`.
    private var syntheticEffects: [String: WEEffect] = [:]
    private var targetsNeedingInitialClear: [MTLTexture] = []
    private var targetSamplerKeys: [ObjectIdentifier: SamplerKey] = [:]
    private var renderTargetWrappers: [ObjectIdentifier: GPUTexture] = [:]
    private let preprocessor: ShaderPreprocessor
    private var lastTime: Double = -1
    private var parallaxDisplacement = SIMD2<Float>(0, 0)
    /// Set MIRAGE_DEBUG=1 to log every encoded pass.
    private let debugLogging = ProcessInfo.processInfo.environment["MIRAGE_DEBUG"] != nil

    private let inboxLock = NSLock()
    private var pendingProperties: [String: JSON] = [:]

    /// Hands edited user properties to the scene from another thread.
    ///
    /// Nothing here touches the store, Metal or JavaScriptCore: the values wait
    /// in a mailbox and the render thread drains it at the top of the next
    /// frame, so an edit lands on a frame boundary rather than mid-frame.
    public func setUserProperties(_ values: [String: JSON]) {
        guard !values.isEmpty else { return }
        inboxLock.lock()
        for (name, value) in values { pendingProperties[name] = value }
        inboxLock.unlock()
    }

    public func setUserProperty(_ name: String, _ value: JSON) {
        setUserProperties([name: value])
    }

    private func applyPendingProperties() {
        inboxLock.lock()
        let incoming = pendingProperties
        pendingProperties.removeAll(keepingCapacity: true)
        inboxLock.unlock()
        guard !incoming.isEmpty else { return }
        store.apply(incoming)
        // Scripts read the properties at registration and on change, never by
        // observing the store.
        scripts?.userPropertiesChanged(store)
    }

    /// Object ids forced visible whatever the scene says, for debugging a layer
    /// that is hidden by default.
    public var forceVisibleObjects: Set<Int> = []

    /// Normalised pointer position, x right / y down, as `g_PointerPosition` expects.
    public var pointerPosition = SIMD2<Float>(0.5, 0.5)
    private var pointerPositionLast = SIMD2<Float>(0.5, 0.5)
    /// Audio spectrum, 64 bins; the 16/32 bin uniforms are derived from it.
    /// The system audio spectrum, 64 bands per channel with index 0 lowest,
    /// which is Wallpaper Engine's own contract. The 32 and 16 wide forms the
    /// shaders also declare are averaged down from these.
    public private(set) var audioSpectrumLeft = [Float](repeating: 0, count: 64)
    public private(set) var audioSpectrumRight = [Float](repeating: 0, count: 64)
    private var derivedSpectrum: (l16: [Float], r16: [Float], l32: [Float], r32: [Float])?
    /// Whether any shader in this scene actually reads the spectrum, so the app
    /// only asks for the audio permission on a wallpaper that uses it.
    public private(set) var usesAudioSpectrum = false

    public func setAudioSpectrum(left: [Float], right: [Float]) {
        func shaped(_ values: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: 64)
            for i in 0..<min(64, values.count) where values[i].isFinite {
                out[i] = min(1, max(0, values[i]))
            }
            return out
        }
        audioSpectrumLeft = shaped(left)
        audioSpectrumRight = shaped(right)
        derivedSpectrum = nil
    }

    // MARK: Setup

    /// `outputSize` is the size the wallpaper will be displayed at, in pixels.
    /// Passing it lets a scene authored larger than the screen render at the
    /// screen's resolution instead of its own.
    /// `outputSize` is the size the wallpaper will be displayed at, in pixels.
    /// Its aspect is always used, to crop away the part of the scene the display
    /// will never show. Its resolution is only used when `scaleToOutput` is set,
    /// because rendering a scene at less than its authored resolution is
    /// visibly softer.
    public init(project: WEProject, locator: AssetLocator, context: RenderContext? = nil,
                propertyOverrides: [String: JSON] = [:], outputSize: (Int, Int)? = nil,
                scaleToOutput: Bool = false) throws {
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
        self.visibleWidth = size.0
        self.visibleHeight = size.1
        if let outputSize, outputSize.0 > 0, outputSize.1 > 0 {
            // Exactly the region `present` would have kept: it crops symmetrically
            // about the centre, so a centred crop here is the same image.
            let outAspect = Float(outputSize.0) / Float(outputSize.1)
            if outAspect.isFinite, outAspect > 0 {
                let w = min(Float(size.0), Float(size.1) * outAspect)
                let h = min(Float(size.1), Float(size.0) / outAspect)
                if w.isFinite, h.isFinite, w >= 1, h >= 1 {
                    // The crop is centred, so it only lands on whole pixels when
                    // the amount removed is even. Rounding to that keeps every
                    // triangle on the pixel centres it had before, which is what
                    // makes cropping cost nothing at all rather than nearly
                    // nothing: at native scale the frame comes out identical.
                    self.visibleWidth = SceneRenderer.centredCrop(w, of: size.0)
                    self.visibleHeight = SceneRenderer.centredCrop(h, of: size.1)
                }
            }
        }
        if scaleToOutput, let outputSize, outputSize.0 > 0, outputSize.1 > 0 {
            // The visible region is now exactly the target's aspect, so both
            // ratios agree and either will do. Never upscale: a scene smaller
            // than the display is already at its textures' size.
            let cover = Float(outputSize.0) / Float(visibleWidth)
            if cover.isFinite, cover > 0, cover < 1 { self.renderScale = cover }
        }

        try buildSceneTargets()
        buildLayers()
        buildParticleLayers()
        buildBloomLayer()
        buildScripts()
        usesAudioSpectrum = SceneRenderer.readsAudio(layers) || SceneRenderer.emittersFollowAudio(orderedLayers)
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
        guard let scene = makeTarget(name: "_rt_FullFrameBuffer", width: renderWidth, height: renderHeight) else {
            throw RenderError.resourceCreation("scene framebuffer")
        }
        sceneTexture = scene
        sceneScope.register("_rt_FullFrameBuffer", scene)
        // lwe aliases the mip-mapped frame buffer to the scene target.
        sceneScope.register("_rt_MipMappedFrameBuffer", scene)
        if let shadow = makeTarget(name: "_rt_shadowAtlas", width: renderWidth, height: renderHeight) {
            sceneScope.register("_rt_shadowAtlas", shadow)
            sceneScope.register("_alias_lightCookie", shadow)
        }
        // The engine framebuffers the bloom chain works in, at the quarter and
        // eighth scales Wallpaper Engine uses. Registered scene-wide, as WE has
        // them, so a wallpaper naming one of them resolves it.
        let quarter = (max(1, renderWidth / 4), max(1, renderHeight / 4))
        let eighth = (max(1, renderWidth / 8), max(1, renderHeight / 8))
        if let t = makeTarget(name: "_rt_4FrameBuffer", width: quarter.0, height: quarter.1) {
            sceneScope.register("_rt_4FrameBuffer", t)
        }
        if let t = makeTarget(name: "_rt_8FrameBuffer", width: eighth.0, height: eighth.1) {
            sceneScope.register("_rt_8FrameBuffer", t)
        }
        if let t = makeTarget(name: "_rt_Bloom", width: eighth.0, height: eighth.1) {
            sceneScope.register("_rt_Bloom", t)
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

    /// Objects whose composite another object samples, so they have to be built
    /// and filled even when they are invisible.
    ///
    /// A "composition layer" is exactly that: `visible: false`, no effects of its
    /// own, existing only so that another object can bind
    /// `_rt_imageLayerComposite_<id>_a`. Skipping it leaves the dependent layer
    /// sampling white.
    private lazy var dependencyTargets: Set<Int> = {
        var ids = Set<Int>()
        for object in scene.objects { ids.formUnion(object.dependencies) }
        // Anything naming a composite directly, wherever in the scene it appears.
        let text = scene.raw.description
        var search = text[...]
        let marker = "_rt_imageLayerComposite_"
        while let range = search.range(of: marker) {
            let rest = search[range.upperBound...]
            let digits = rest.prefix { $0.isNumber || $0 == "-" }
            if let id = Int(digits) { ids.insert(id) }
            search = rest
        }
        return ids
    }()

    private func buildLayers() {
        let objectsById = Dictionary(scene.objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for object in renderOrder() {
            if object.kind == .text {
                if let layer = makeTextLayer(object: object) {
                    layers.append(layer)
                    orderedLayers.append(.image(layer))
                }
                continue
            }
            guard object.kind == .image, let imagePath = object.imagePath else { continue }
            guard let model = locator.model(imagePath) else {
                diagnostics.append("[\(object.id)] model not found: \(imagePath)")
                continue
            }
            guard let loaded = locator.material(model.material) else {
                diagnostics.append("[\(object.id)] material not found: \(model.material)")
                continue
            }
            // A material instance replaces slots on the model's material, which is
            // how an object points itself at another layer's composite.
            let material = instantiate(loaded, with: object.instance)
            let passthrough = model.passthrough || object.passthrough
            // Every effect is compiled, whether or not it is on right now, so
            // that switching one on later needs no shader work. A passthrough
            // layer with nothing to run is skipped per frame instead of here.
            let visibleEffects = object.effects

            guard let layer = makeLayer(object: object, model: model, material: material,
                                        passthrough: passthrough, objectsById: objectsById) else { continue }
            buildPasses(layer: layer, material: material, visibleEffects: visibleEffects)
            layer.effectVisibility = object.effects.map(\.visible)
            layer.isPassthroughLayer = passthrough
            layer.setActiveEffects(object.effects.map { $0.visible.resolveBool(store) })
            layer.relocateBlending()
            layer.wirePasses()
            layers.append(layer)
            orderedLayers.append(.image(layer))
            diagnostics.append(contentsOf: layer.diagnostics.map { "[\(object.id)] \($0)" })
        }
    }

    /// Builds the particle systems, in the same pass over the render order as the images.
    private func buildParticleLayers() {
        var built: [Int: ParticleLayer] = [:]
        for object in renderOrder() where object.kind == .particle {
            guard let layer = makeParticleLayer(object: object) else { continue }
            built[object.id] = layer
        }
        guard !built.isEmpty else { return }
        // Splice each particle system into the ordered list at its scene position.
        var merged: [SceneLayerRef] = []
        var imageIndex = 0
        for object in renderOrder() {
            if object.kind == .particle, let layer = built[object.id] {
                merged.append(.particle(layer))
            } else if imageIndex < layers.count, layers[imageIndex].object.id == object.id {
                merged.append(.image(layers[imageIndex]))
                imageIndex += 1
            }
        }
        while imageIndex < layers.count {
            merged.append(.image(layers[imageIndex]))
            imageIndex += 1
        }
        orderedLayers = merged
    }

    /// State a text layer needs between frames: what it last rendered, so a clock only
    /// re-rasterises when the string actually changes.
    final class TextBinding {
        let object: WESceneObject
        var lastKey = ""
        init(object: WESceneObject) { self.object = object }
    }

    private func textSpec(for object: WESceneObject, store: PropertyStore?) -> TextLayerSpec {
        let text = object.text ?? .null
        let resolved = scriptedValue(object, "text")?.string
            ?? object.textValue?.resolve(store).string ?? (text["value"].string ?? "")
        return TextLayerSpec(string: resolved,
                             fontPath: object.raw["font"].string,
                             pointSize: object.raw["pointsize"].float ?? 32,
                             color: scriptedValue(object, "color")?.vec3
                                 ?? object.color.resolve(store).vec3 ?? SIMD3(repeating: 1),
                             alpha: scriptedValue(object, "alpha")?.float
                                 ?? object.alpha.resolveFloat(store, default: 1),
                             horizontalAlign: object.raw["horizontalalign"].string ?? "center",
                             verticalAlign: object.raw["verticalalign"].string ?? "center",
                             maxWidth: object.raw["maxwidth"].float ?? 500,
                             maxRows: object.raw["maxrows"].int ?? 1,
                             limitWidth: object.raw["limitwidth"].bool ?? false,
                             limitRows: object.raw["limitrows"].bool ?? false,
                             useEllipsis: object.raw["limituseellipsis"].bool ?? false)
    }

    private func textKey(_ spec: TextLayerSpec) -> String {
        "\(spec.string)|\(spec.fontPath ?? "")|\(spec.pointSize)|\(spec.maxWidth)|\(spec.maxRows)|\(spec.limitWidth)|\(spec.limitRows)|\(spec.horizontalAlign)"
    }

    private func makeTextLayer(object: WESceneObject) -> ImageLayer? {
        let spec = textSpec(for: object, store: store)
        guard let raster = textRasterizer.rasterize(spec) else { return nil }
        guard let material = locator.material("materials/fonts/basefont.json"),
              !material.passes.isEmpty else {
            diagnostics.append("[\(object.id)] font material not found")
            return nil
        }
        let model = WEModel(json: .object(["material": .string("materials/fonts/basefont.json")]))
        let size = SIMD2(Float(raster.width), Float(raster.height))
        let glyphs = GPUTexture(name: "text.\(object.id)", texture: raster.texture,
                                samplerKey: SamplerKey(nearest: false, clamp: true, hasMips: false),
                                resolution: SIMD4(size.x, size.y, size.x, size.y),
                                weFormat: .r8, source: nil, isRenderTarget: false)
        let scope = TargetScope(name: "text\(object.id)", parent: sceneScope)
        // Wallpaper Engine positions text like an image, with the vertical anchor folded in.
        var alignment = object.raw["horizontalalign"].string ?? "center"
        if let vertical = object.raw["verticalalign"].string, vertical != "center" { alignment += vertical }
        let layer = ImageLayer(object: object, model: model, size: size, texture: glyphs,
                               objectScope: scope, isPassthrough: false, isFullscreen: false,
                               alignment: alignment)
        let w = max(1, Int(size.x.rounded())), h = max(1, Int(size.y.rounded()))
        guard let a = makeTarget(name: "_rt_textComposite_\(object.id)_a", width: w, height: h),
              let b = makeTarget(name: "_rt_textComposite_\(object.id)_b", width: w, height: h) else { return nil }
        layer.compositeA = a
        layer.compositeB = b
        let visibleEffects = object.effects.filter { $0.visible.resolveBool(store) }
        buildPasses(layer: layer, material: material, visibleEffects: visibleEffects)
        layer.relocateBlending()
        layer.wirePasses()
        textLayers[ObjectIdentifier(layer)] = TextBinding(object: object)
        textLayers[ObjectIdentifier(layer)]?.lastKey = textKey(spec)
        diagnostics.append(contentsOf: layer.diagnostics.map { "[\(object.id)] \($0)" })
        return layer
    }

    /// Re-rasterises a text layer whose string changed this frame.
    private func refreshTextLayer(_ layer: ImageLayer) {
        guard let binding = textLayers[ObjectIdentifier(layer)] else { return }
        let spec = textSpec(for: binding.object, store: store)
        guard textKey(spec) != binding.lastKey else { return }
        binding.lastKey = textKey(spec)
        guard let raster = textRasterizer.rasterize(spec) else { return }
        let size = SIMD2(Float(raster.width), Float(raster.height))
        let glyphs = GPUTexture(name: "text.\(binding.object.id)", texture: raster.texture,
                                samplerKey: SamplerKey(nearest: false, clamp: true, hasMips: false),
                                resolution: SIMD4(size.x, size.y, size.x, size.y),
                                weFormat: .r8, source: nil, isRenderTarget: false)
        layer.replaceTexture(glyphs, size: size)
        // A longer string needs bigger composites; recreate them when it outgrows them.
        let w = max(1, Int(size.x.rounded())), h = max(1, Int(size.y.rounded()))
        if let existing = layer.compositeA, existing.width < w || existing.height < h {
            if let a = makeTarget(name: "_rt_textComposite_\(binding.object.id)_a", width: w, height: h),
               let b = makeTarget(name: "_rt_textComposite_\(binding.object.id)_b", width: w, height: h) {
                layer.compositeA = a
                layer.compositeB = b
            }
        }
    }

    private func makeParticleLayer(object: WESceneObject, depth: Int = 0) -> ParticleLayer? {
        let json: JSON
        if let path = object.particlePath {
            guard let loaded = locator.json(path) else {
                diagnostics.append("[\(object.id)] particle system not found: \(path)")
                return nil
            }
            json = loaded
        } else if let inline = object.particleInline {
            json = inline
        } else {
            return nil
        }
        guard let system = WEParticleSystem(json: json) else {
            diagnostics.append("[\(object.id)] particle system could not be parsed")
            return nil
        }
        guard let material = locator.material(system.material), let materialPass = material.passes.first else {
            diagnostics.append("[\(object.id)] particle material not found: \(system.material)")
            return nil
        }
        let layer = ParticleLayer(object: object, system: system)

        // Slot 0 is always the particle texture, whatever the shader's own default says.
        var particleTexture: GPUTexture?
        for name in materialPass.textures.compactMap({ $0 }) where particleTexture == nil {
            particleTexture = name.isRenderTargetName ? nil : textures.texture(named: name)
        }
        layer.configureSheet(with: particleTexture)

        var extra = layer.shaderCombos()
        for (key, value) in materialPass.combos { extra[key.uppercased()] = value }
        // A rope draws through its own shader, with the wide vertex format its
        // no-geometry-shader branch expects.
        if layer.system.renderer.isRope { extra["THICKFORMAT"] = 1 }
        let spec = PassSpec(materialPass: materialPass, override: nil, binds: [], target: nil,
                            scope: sceneScope, effectIndex: nil,
                            shaderOverride: layer.shaderOverride, extraCombos: extra)
        guard let pass = compile(spec: spec, objectTexture: particleTexture, note: { layer.note($0) }) else {
            diagnostics.append(contentsOf: layer.diagnostics.map { "[\(object.id)] \($0)" })
            return nil
        }
        layer.pass = pass

        // Child systems: a firework's sparks, a raindrop's splash, the glow that
        // rides along with a shooting star. One level deep is all the format
        // uses, and the depth guard keeps a malformed file from recursing.
        if depth < 2 {
            for child in system.children {
                guard let childJSON = locator.json(child.path) else {
                    layer.note("child system not found: \(child.path)")
                    continue
                }
                let childObject = WESceneObject(json: .object([
                    "id": .number(Double(object.id)),
                    "name": .string(object.name + "/" + (child.path as NSString).lastPathComponent),
                    "particle": childJSON,
                ]))
                guard let childLayer = makeParticleLayer(object: childObject, depth: depth + 1) else { continue }
                layer.children.append((child, childLayer))
            }
            layer.recordEvents = !layer.children.isEmpty
            if !layer.children.isEmpty {
                layer.note("built \(layer.children.count) child system(s): "
                    + layer.children.map { $0.spec.trigger.rawValue }.joined(separator: ", "))
            }
        }

        diagnostics.append(contentsOf: layer.diagnostics.map { "[\(object.id)] \($0)" })
        return layer
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

    /// Applies an object's material `instance` to the material it loaded.
    ///
    /// Per slot, a non-null entry in the instance wins; combos and constants are
    /// merged with the instance winning. This is the same rule the effect-pass
    /// override path already uses.
    private func instantiate(_ material: WEMaterial, with instance: JSON) -> WEMaterial {
        guard case .object = instance else { return material }
        guard case .array(let passes) = material.raw["passes"], !passes.isEmpty else { return material }
        func merged(_ pass: JSON) -> JSON {
            guard case .object(var fields) = pass else { return pass }
            for slot in ["textures", "usertextures"] {
                guard case .array(let replacements) = instance[slot] else { continue }
                var current: [JSON]
                if case .array(let existing) = fields[slot] ?? .null { current = existing } else { current = [] }
                for (index, replacement) in replacements.enumerated() {
                    if replacement.isNull { continue }
                    while current.count <= index { current.append(.null) }
                    current[index] = replacement
                }
                fields[slot] = .array(current)
            }
            for group in ["combos", "constantshadervalues"] {
                guard case .object(let additions) = instance[group] else { continue }
                var current: [String: JSON]
                if case .object(let existing) = fields[group] ?? .null { current = existing } else { current = [:] }
                for (key, value) in additions { current[key] = value }
                fields[group] = .object(current)
            }
            return .object(fields)
        }
        guard case .object(var raw) = material.raw else { return material }
        raw["passes"] = .array(passes.map(merged))
        return WEMaterial(json: .object(raw))
    }

    /// Loads a layer's `.mdl` and uploads its mesh.
    ///
    /// The buffers are real `MTLBuffer`s rather than inline vertex bytes: even
    /// the smallest puppet here is 43 KB of vertices, ten times Metal's inline
    /// limit. A file that will not parse leaves the layer drawing as a flat
    /// quad, which is what it did before puppets existed.
    private func attachPuppet(to layer: ImageLayer, path: String, object: WESceneObject,
                              cropOffset: SIMD2<Float>) {
        guard let data = locator.data(path) else {
            diagnostics.append("[\(object.id)] puppet not found: \(path)")
            return
        }
        guard let model = PuppetModel.parse(data), !model.bones.isEmpty, !model.indices.isEmpty else {
            diagnostics.append("[\(object.id)] puppet could not be parsed: \(path)")
            return
        }
        guard SceneRenderer.puppetMeshEnabled else { return }
        // Pack the parsed vertex and scale its texture coordinates into the
        // padded texture the way the quad path scales its own. A mesh sampling
        // raw content coordinates out of a padded store reads the wrong region.
        let ratio = layer.contentRatio
        var vertexBytes = [UInt8]()
        vertexBytes.reserveCapacity(model.vertices.count * 80)
        for vertex in model.vertices {
            var position = vertex.position
            var indices = vertex.blendIndices
            var weights = vertex.blendWeights
            var uv = vertex.uv * ratio
            var normal = vertex.normal
            var tangent = vertex.tangent
            withUnsafeBytes(of: &position) { vertexBytes.append(contentsOf: $0.prefix(12)) }
            withUnsafeBytes(of: &indices) { vertexBytes.append(contentsOf: $0.prefix(16)) }
            withUnsafeBytes(of: &weights) { vertexBytes.append(contentsOf: $0.prefix(16)) }
            withUnsafeBytes(of: &uv) { vertexBytes.append(contentsOf: $0.prefix(8)) }
            withUnsafeBytes(of: &normal) { vertexBytes.append(contentsOf: $0.prefix(12)) }
            withUnsafeBytes(of: &tangent) { vertexBytes.append(contentsOf: $0.prefix(16)) }
        }
        guard let vertexBuffer = context.device.makeBuffer(bytes: vertexBytes, length: vertexBytes.count,
                                                           options: .storageModeShared),
              let indexBuffer = context.device.makeBuffer(bytes: model.indices,
                                                          length: model.indices.count * 2,
                                                          options: .storageModeShared) else {
            diagnostics.append("[\(object.id)] puppet buffers could not be created")
            return
        }
        vertexBuffer.label = "puppet.\(object.id).vertices"
        indexBuffer.label = "puppet.\(object.id).indices"
        layer.puppet = ImageLayer.PuppetBinding(model: model, vertexBuffer: vertexBuffer,
                                                indexBuffer: indexBuffer, indexCount: model.indices.count,
                                                cropOffset: cropOffset)
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
            size = SIMD2(Float(visibleWidth), Float(visibleHeight))
        } else if size.x == 0 || size.y == 0, let w = model.width, let h = model.height {
            size = SIMD2(Float(w), Float(h))
        }
        if model.fullscreen {
            size = SIMD2(Float(visibleWidth), Float(visibleHeight))
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

        if let puppetPath = model.puppet {
            attachPuppet(to: layer, path: puppetPath, object: object, cropOffset: model.cropOffset)
        }

        let w = scaled(Int(size.x.rounded())), h = scaled(Int(size.y.rounded()))
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

        func adding(combos: [String: Int]) -> PassSpec {
            var merged = extraCombos
            for (key, value) in combos { merged[key] = value }
            return PassSpec(materialPass: materialPass, override: override, binds: binds, target: target,
                            scope: scope, effectIndex: effectIndex, shaderOverride: shaderOverride,
                            extraCombos: merged)
        }
    }

    private func buildPasses(layer: ImageLayer, material: WEMaterial, visibleEffects: [WEEffectInstance]) {
        var specs: [PassSpec] = []
        for pass in material.passes {
            specs.append(PassSpec(materialPass: pass, override: nil, binds: [], target: nil,
                                  scope: layer.objectScope, effectIndex: nil, shaderOverride: nil, extraCombos: [:]))
        }

        for (effectIndex, instance) in visibleEffects.enumerated() {
            guard let effect = syntheticEffects[instance.file] ?? locator.effect(instance.file) else {
                layer.note("effect not found: \(instance.file)")
                continue
            }
            let scope = TargetScope(name: "effect\(instance.id)", parent: layer.objectScope)
            for fbo in effect.fbos {
                let scale = max(fbo.scale, 0.0001)
                let width = layer.size.x / scale, height = layer.size.y / scale
                let w = width.isFinite ? scaled(min(SceneRenderer.maximumRenderDimension, max(1, Int(width.rounded(.towardZero))))) : 1
                let h = height.isFinite ? scaled(min(SceneRenderer.maximumRenderDimension, max(1, Int(height.rounded(.towardZero))))) : 1
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

        // A puppet replaces the quad on whichever pass ends up drawing the layer,
        // so that is the one compiled with skinning. With no effects in the way
        // that is the material's own pass; otherwise a copy of it is appended
        // after the chain and draws the skinned mesh over the result.
        var puppetSpecIndex: Int?
        if let puppet = layer.puppet {
            let skinning = ["SKINNING": 1, "BONECOUNT": puppet.model.bones.count]
            if specs.count == 1, let only = specs.first {
                specs[0] = only.adding(combos: skinning)
                puppetSpecIndex = 0
            } else if let base = material.passes.first {
                var combos = skinning
                for (key, value) in base.combos { combos[key.uppercased()] = value }
                specs.append(PassSpec(materialPass: base, override: nil, binds: [], target: nil,
                                      scope: layer.objectScope, effectIndex: nil, shaderOverride: nil,
                                      extraCombos: combos))
                puppetSpecIndex = specs.count - 1
            }
        }

        for (index, spec) in specs.enumerated() {
            guard let compiled = compile(spec: spec, objectTexture: layer.texture, note: { layer.note($0) }) else { continue }
            compiled.targetName = spec.target
            if index == puppetSpecIndex { layer.puppetPassIndex = layer.passes.count }
            layer.append(compiled)
        }
        // A puppet whose pass failed to compile falls back to its flat quad.
        if layer.puppetPassIndex == nil { layer.puppet = nil }
    }

    // MARK: Pass compilation

    private func compile(spec: PassSpec, objectTexture: GPUTexture?, note: (String) -> Void) -> CompiledPass? {
        let shaderName = spec.shaderOverride ?? spec.materialPass.shader
        let source: ShaderProgramSource
        do {
            source = try preprocessor.load(shaderName)
        } catch {
            note("shader not found: \(shaderName)")
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
        if let format = objectTexture?.weFormat {
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
            note("shader \(shaderName) failed: \(String(describing: error).prefix(200))")
            return nil
        }

        let pass = CompiledPass(shaderName: shaderName, source: source, program: program,
                                blending: spec.materialPass.blending,
                                depthTest: spec.materialPass.depthTest,
                                depthWrite: spec.materialPass.depthWrite,
                                cull: spec.materialPass.cullMode == "normal",
                                combos: combos, scope: spec.scope)
        pass.effectIndex = spec.effectIndex
        buildTextureSlots(pass: pass, spec: spec, note: note)
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

    private func buildTextureSlots(pass: CompiledPass, spec: PassSpec, note: (String) -> Void) {
        func prepend(_ slot: Int, _ entry: TextureSlotEntry) {
            pass.slots[slot, default: []].insert(entry, at: 0)
        }
        func entry(for name: String) -> TextureSlotEntry? {
            if name.isRenderTargetName { return .target(name) }
            guard let texture = textures.texture(named: name) else {
                note("texture not found: \(name)")
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

    /// Advances a puppet's animation layers and recomputes its bone palette.
    ///
    /// A scene names an animation by **id**, not by index, and each animation
    /// layer runs at its own rate, so each keeps its own clock. A layer whose
    /// `visible` resolves false contributes nothing.
    private func posePuppet(_ layer: ImageLayer, dt: Float) {
        guard let binding = layer.puppet else { return }
        let animationLayers = layer.object.animationLayerList
        if binding.times.count != animationLayers.count {
            binding.times = [Double](repeating: 0, count: animationLayers.count)
        }
        var active: [(animation: Int, blend: Float, rate: Float)] = []
        for (index, entry) in animationLayers.enumerated() {
            let rate = entry.rate.resolveFloat(store, default: 1)
            let safeRate = rate.isFinite ? rate : 1
            binding.times[index] += Double(dt)
            guard entry.visible.resolveBool(store, default: true) else { continue }
            let blend = entry.blend.resolveFloat(store, default: 1)
            guard blend.isFinite, blend > 0 else { continue }
            guard let resolved = binding.model.animationIndex(withID: entry.animation)
                ?? binding.model.animationIndex(named: entry.name) else { continue }
            active.append((animation: resolved, blend: blend, rate: safeRate))
        }
        // With no animation layers at all the mesh sits in its rest pose, which
        // is exactly where the file already draws it.
        binding.boneMatrices = binding.model.boneMatrices(layers: active,
                                                          time: binding.times.first ?? 0)
    }

    /// A value a script wrote onto this object's layer, if any. Scripts animate
    /// objects they do not drive, so a layer write outranks the stored value.
    func scriptedValue(_ object: WESceneObject, _ property: String) -> JSON? {
        guard let values = store.scriptValues, values.hasLayerValues else { return nil }
        return values.layerValue(object: object.scriptName, property: property)
    }

    /// WE's clock convention: the fraction of the day that has passed, which
    /// feeds both `g_Daytime` and the scripts' `engine.timeOfDay`.
    public static func dayTime() -> Float {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Float((now.hour ?? 0) * 60 + (now.minute ?? 0)) / (24 * 60)
    }

    private enum UniformStage { case vertex, fragment }

    /// Binds a constant block, inline when it fits and through a buffer when it
    /// does not.
    ///
    /// A puppet's bone palette costs 64 bytes a bone, so a rig of about sixty
    /// pushes the block past Metal's 4 KiB inline limit. Truncating there would
    /// zero the tail of `g_Bones` and collapse the mesh, so the large case gets
    /// a real buffer instead.
    private func setUniforms(_ bytes: [UInt8], on encoder: MTLRenderCommandEncoder,
                             index: Int, stage: UniformStage) {
        if bytes.count <= UniformWriter.inlineByteLimit {
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                switch stage {
                case .vertex: encoder.setVertexBytes(base, length: raw.count, index: index)
                case .fragment: encoder.setFragmentBytes(base, length: raw.count, index: index)
                }
            }
            return
        }
        guard let buffer = context.device.makeBuffer(bytes: bytes, length: bytes.count,
                                                     options: .storageModeShared) else { return }
        switch stage {
        case .vertex: encoder.setVertexBuffer(buffer, offset: 0, index: index)
        case .fragment: encoder.setFragmentBuffer(buffer, offset: 0, index: index)
        }
    }

    /// Re-derives which effects are on, so a user property or a script can
    /// switch one without the wallpaper being reloaded.
    ///
    /// Cheap enough to run every frame: one `resolveBool` per effect, and the
    /// re-wiring only happens when the answer actually changed.
    private func refreshEffectVisibility() {
        for layer in layers where !layer.effectVisibility.isEmpty {
            layer.setActiveEffects(layer.effectVisibility.map { $0.resolveBool(store) })
        }
    }

    /// Whether any particle emitter follows the music.
    private static func emittersFollowAudio(_ layers: [SceneLayerRef]) -> Bool {
        for entry in layers {
            guard case .particle(let layer) = entry else { continue }
            if layer.system.emitters.contains(where: { $0.audioProcessingMode != 0 }) { return true }
        }
        return false
    }

    /// Whether any compiled pass declares one of the spectrum uniforms.
    private static func readsAudio(_ layers: [ImageLayer]) -> Bool {
        for layer in layers {
            for pass in layer.passes {
                let names = (pass.uniformWriterVertex?.block.members.map(\.name) ?? [])
                    + (pass.uniformWriterFragment?.block.members.map(\.name) ?? [])
                if names.contains(where: { $0.hasPrefix("g_AudioSpectrum") }) { return true }
            }
        }
        return false
    }

    // MARK: Bloom

    /// Whether a puppet layer draws its skinned mesh instead of a flat quad.
    /// Set `MIRAGE_NO_PUPPET` to fall back to the flat quad.
    public static var puppetMeshEnabled = ProcessInfo.processInfo.environment["MIRAGE_NO_PUPPET"] == nil

    /// The id of the synthetic object that carries the bloom chain. Negative so
    /// it can never collide with a real scene object.
    static let bloomObjectID = -1

    /// Builds the bloom chain, which Wallpaper Engine implements in engine code
    /// rather than shipping as an `effect.json`.
    ///
    /// It is a full-screen passthrough layer appended after every other layer,
    /// carrying one four-pass effect: the scene is copied aside, downsampled to
    /// a quarter and then an eighth while being blurred on each axis, and
    /// combined back over the copy into the scene framebuffer. The stock
    /// materials do all the work; only the wiring is ours.
    private func buildBloomLayer() {
        let enabled = scene.general.bloom
        // A wallpaper that hard-codes bloom off costs nothing. One that binds it
        // to a user property always builds the layer, so the toggle stays live:
        // `visible` is re-resolved every frame.
        guard enabled.isBound || enabled.resolveBool(store, default: false) else { return }

        let id = SceneRenderer.bloomObjectID
        let sceneCopy = "_rt_imageLayerComposite_\(id)_a"
        func pass(_ material: String, target: String, binds: [(String, Int)]) -> JSON {
            .object([
                "material": .string(material),
                "target": .string(target),
                "bind": .array(binds.map { .object(["name": .string($0.0), "index": .number(Double($0.1))]) }),
            ])
        }
        syntheticEffects[SceneRenderer.bloomEffectFile] = WEEffect(json: .object([
            "name": .string("bloom"),
            "passes": .array([
                pass("materials/util/downsample_quarter_bloom.json", target: "_rt_4FrameBuffer",
                     binds: [("_rt_FullFrameBuffer", 0)]),
                pass("materials/util/downsample_eighth_blur_v.json", target: "_rt_8FrameBuffer",
                     binds: [("_rt_4FrameBuffer", 0)]),
                pass("materials/util/blur_h_bloom.json", target: "_rt_Bloom",
                     binds: [("_rt_8FrameBuffer", 0)]),
                pass("materials/util/combine.json", target: "_rt_FullFrameBuffer",
                     binds: [(sceneCopy, 0), ("_rt_Bloom", 1)]),
            ]),
        ]))

        // The strength, threshold and tint travel as raw JSON rather than
        // resolved numbers, so a value bound to a user property stays bound and
        // is re-resolved every frame like any other shader constant.
        let general = scene.raw["general"]
        let constants = JSON.object([
            "bloomstrength": general["bloomstrength"],
            "bloomthreshold": general["bloomthreshold"],
            "bloomtint": general["bloomtint"],
        ])
        let object = WESceneObject(json: .object([
            "id": .number(Double(id)),
            "name": .string("mirage_bloom"),
            "image": .string("models/mirage/bloomlayer.json"),
            "visible": general["bloom"].isNull ? .bool(true) : general["bloom"],
            "origin": .string("\(sceneWidth / 2) \(sceneHeight / 2) 0"),
            "effects": .array([.object([
                "file": .string(SceneRenderer.bloomEffectFile),
                "id": .number(Double(id)),
                "name": .string("bloom"),
                "passes": .array([.object(["constantshadervalues": constants])]),
            ])]),
        ]))

        guard let model = locator.model("models/mirage/bloomlayer.json"),
              let material = locator.material(model.material) else {
            diagnostics.append("bloom: the stock passthrough model or material is missing")
            return
        }
        guard let layer = makeLayer(object: object, model: model, material: material,
                                    passthrough: true, objectsById: [:]) else {
            diagnostics.append("bloom: the layer could not be built")
            return
        }
        buildPasses(layer: layer, material: material, visibleEffects: object.effects)
        layer.relocateBlending()
        layer.wirePasses()
        layers.append(layer)
        orderedLayers.append(.image(layer))
        diagnostics.append(contentsOf: layer.diagnostics.map { "[bloom] \($0)" })
    }

    static let bloomEffectFile = "effects/mirage/bloom.json"

    // MARK: Scripts

    /// Registers every scripted value in the scene, once, at load.
    ///
    /// A `DynamicValue` carries its own identity (`scriptID`), so the walk only
    /// has to reach each one; `ScriptRuntime` does the rest. The property names
    /// are Wallpaper Engine's own, because a script addresses the value it
    /// drives as `thisLayer.<property>`.
    private func buildScripts() {
        var scripted: [(value: DynamicValue, object: String, property: String)] = []

        func collect(_ value: DynamicValue?, _ object: String, _ property: String) {
            guard let value, value.script != nil else { return }
            scripted.append((value, object, property))
        }

        for object in scene.objects {
            let name = object.scriptName
            collect(object.origin, name, "origin")
            collect(object.scale, name, "scale")
            collect(object.angles, name, "angles")
            collect(object.size, name, "size")
            collect(object.visible, name, "visible")
            collect(object.alpha, name, "alpha")
            collect(object.color, name, "color")
            collect(object.brightness, name, "brightness")
            collect(object.parallaxDepth, name, "parallaxdepth")
            collect(object.textValue, name, "text")
            collect(object.volume, name, "volume")
        }
        collect(scene.general.clearColor, "scene", "clearcolor")
        collect(scene.general.zoom, "scene", "zoom")
        collect(scene.general.ambientColor, "scene", "ambientcolor")
        collect(scene.general.skylightColor, "scene", "skylightcolor")
        collect(scene.general.cameraParallax, "scene", "cameraparallax")
        collect(scene.general.cameraParallaxAmount, "scene", "cameraparallaxamount")
        collect(scene.general.cameraParallaxDelay, "scene", "cameraparallaxdelay")
        collect(scene.general.cameraParallaxMouseInfluence, "scene", "cameraparallaxmouseinfluence")
        collect(scene.general.bloom, "scene", "bloom")
        // An effect's `visible` still resolves once at load, but registering it
        // keeps the script running, so the value is right if that ever changes.
        for object in scene.objects {
            for effect in object.effects { collect(effect.visible, object.scriptName, "effectvisible") }
        }
        // Shader constants driven by a script, on the object that owns the pass.
        for layer in layers {
            let name = layer.object.scriptName
            for pass in layer.passes {
                for bound in pass.boundConstants { collect(bound.value, name, bound.uniform) }
            }
        }

        guard !scripted.isEmpty else { return }
        let runtime = ScriptRuntime(workshopId: project.workshopId,
                                    canvasSize: SIMD2(Float(sceneWidth), Float(sceneHeight)),
                                    store: store, locator: locator)
        // Every object, not just the scripted ones: a script positions itself
        // relative to layers it does not drive.
        for object in scene.objects {
            let name = object.scriptName
            var values: [String: JSON] = [
                "name": .string(object.name),
                "id": .number(Double(object.id)),
                "origin": object.origin.resolve(store),
                "scale": object.scale.resolve(store),
                "angles": object.angles.resolve(store),
                "alpha": object.alpha.resolve(store),
                "color": object.color.resolve(store),
                "brightness": object.brightness.resolve(store),
                "visible": object.visible.resolve(store),
                "parallaxDepth": object.parallaxDepth.resolve(store),
            ]
            if let size = object.size { values["size"] = size.resolve(store) }
            if let text = object.textValue { values["text"] = text.resolve(store) }
            runtime.seed(object: name, values: values)
        }
        for entry in scripted { runtime.register(entry.value, object: entry.object, property: entry.property) }
        scripts = runtime
        if runtime.boundCount < scripted.count {
            diagnostics.append("scripts: \(runtime.boundCount) of \(scripted.count) scripted values compiled")
        }
    }

    /// Script diagnostics, merged into the renderer's own.
    public var scriptDiagnostics: [String] { scripts?.diagnostics ?? [] }

    // MARK: Frame

    /// Renders one frame into `target`. `time` is the wallpaper's elapsed running time
    /// in seconds (the caller owns the epoch), and feeds `g_Time` and every animation.
    /// The scene is composed at its own resolution and then presented into `target`.
    public func render(into target: MTLTexture, time: Double, commandBuffer: MTLCommandBuffer) {
        applyPendingProperties()
        if lastTime < 0 { lastTime = time }
        let safeTime = time.isFinite ? time : 0
        let floatTime = Float(safeTime)
        let elapsed = floatTime.isFinite ? floatTime : 0
        let delta = safeTime - lastTime
        let dt = Float(delta.isFinite ? min(0.1, max(0, delta)) : 0)
        lastTime = safeTime
        // Scripts run first: every resolve below, parallax included, reads what
        // they produced this frame rather than last frame's.
        if let scripts {
            scripts.beginFrame(time: safeTime, frameTime: Double(dt),
                               dayTime: Double(SceneRenderer.dayTime()), cursor: pointerPosition)
        }
        updateParallax(dt: dt)
        refreshEffectVisibility()

        // Wallpaper Engine ignores `clearenabled` and always clears the scene target.
        let clearColor = scene.general.clearColor.resolve(store).vec3 ?? SIMD3(repeating: 1)
        let descriptor = MTLRenderPassDescriptor.color(sceneTexture,
                                                       clear: SIMD4(Double(clearColor.x), Double(clearColor.y), Double(clearColor.z), 1))
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.label = "mirage.clearScene"
            encoder.endEncoding()
        }

        let projection = SceneGeometry.sceneProjection(width: Float(visibleWidth), height: Float(visibleHeight),
                                                       nearZ: scene.camera.nearZ, farZ: scene.camera.farZ,
                                                       zoom: scene.general.zoom.resolveFloat(store, default: 1))
        // Video-backed textures decode on their own queue; pick up their newest frame.
        textures.advanceVideoTextures(to: safeTime)
        let objectsById = Dictionary(scene.objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var globals = ShaderValueBag()
        fillSceneGlobals(&globals, elapsed: elapsed, dt: dt)

        for entry in orderedLayers {
            switch entry {
            case .image(let layer):
                let visible = forceVisibleObjects.contains(layer.object.id) ? true
                    : (scriptedValue(layer.object, "visible")?.bool
                        ?? layer.object.visible.resolveBool(store, default: true))
                // An invisible layer another one samples still has to fill its
                // own composite; it is only kept out of the scene draw.
                let producesComposite = dependencyTargets.contains(layer.object.id)
                guard visible || producesComposite else { continue }
                // A passthrough layer with every effect off has nothing to do
                // but copy the scene onto itself.
                if layer.isPassthroughLayer, layer.activeEffectCount == 0, !producesComposite { continue }
                if layer.object.kind == .text { refreshTextLayer(layer) }
                let transform = SceneGeometry.resolveTransform(of: layer.object, objects: objectsById, store: store)
                let parallax = parallaxOffset(for: layer.object)
                layer.updateGeometry(transform: transform, sceneWidth: Float(sceneWidth), sceneHeight: Float(sceneHeight),
                                     projection: projection, parallax: parallax)
                if layer.puppet != nil { posePuppet(layer, dt: dt) }
                for pass in layer.passes {
                    encode(pass: pass, layer: layer, visible: visible, producesComposite: producesComposite,
                           globals: globals, elapsed: elapsed, commandBuffer: commandBuffer)
                }
            case .particle(let layer):
                encodeParticles(layer, globals: globals, elapsed: elapsed, dt: dt, projection: projection,
                                objectsById: objectsById, commandBuffer: commandBuffer)
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

    private func parallaxOffset(for object: WESceneObject) -> SIMD2<Float> {
        guard scene.general.cameraParallax.resolveBool(store, default: false) else { return .zero }
        let amount = scene.general.cameraParallaxAmount.resolveFloat(store, default: 1)
        let depth = object.parallaxDepth.resolve(store).vec2 ?? SIMD2(0, 0)
        let reference = Float(sceneWidth)
        return SIMD2((depth.x + amount) * parallaxDisplacement.x * reference,
                     (depth.y + amount) * parallaxDisplacement.y * reference)
    }

    private func fillSceneGlobals(_ bag: inout ShaderValueBag, elapsed: Float, dt: Float) {
        bag.set("g_Time", elapsed)
        let dayTime = SceneRenderer.dayTime()
        bag.set("g_Daytime", dayTime)
        bag.set("g_DayTime", dayTime)
        bag.set("g_Frametime", dt)
        bag.set("g_PointerPosition", pointerPosition)
        bag.set("g_PointerPositionLast", pointerPositionLast)
        pointerPositionLast = pointerPosition
        let influence = scene.general.cameraParallaxMouseInfluence.resolveFloat(store, default: 1)
        bag.set("g_ParallaxPosition", SIMD2(0.5, 0.5) + (SIMD2(pointerPosition.x, -pointerPosition.y) - SIMD2(0.5, 0.5)) * influence)
        bag.set("g_TexelSize", SIMD2(1 / Float(renderWidth), 1 / Float(renderHeight)))
        bag.set("g_TexelSizeHalf", SIMD2(0.5 / Float(renderWidth), 0.5 / Float(renderHeight)))
        bag.set("g_Screen", SIMD3(Float(renderWidth), Float(renderHeight), Float(renderWidth) / Float(renderHeight)))
        bag.set("g_TextureReductionScale", 1)
        bag.set("g_LightAmbientColor", scene.general.ambientColor.resolve(store).vec3 ?? .zero)
        bag.set("g_LightSkylightColor", scene.general.skylightColor.resolve(store).vec3 ?? .zero)
        bag.set("g_NormalModelMatrix", .mat3(matrix_identity_float3x3))
        bag.set("g_EffectTextureProjectionMatrix", matrix_identity_float4x4)
        bag.set("g_EffectTextureProjectionMatrixInverse", matrix_identity_float4x4)
        bag.set("g_ViewProjectionMatrix", matrix_identity_float4x4)
        // Only a scene that reads the spectrum pays for it: this used to box six
        // arrays into the dictionary on every frame of every wallpaper.
        guard usesAudioSpectrum else { return }
        let derived = derivedSpectrum ?? (l16: resample(audioSpectrumLeft, to: 16),
                                          r16: resample(audioSpectrumRight, to: 16),
                                          l32: resample(audioSpectrumLeft, to: 32),
                                          r32: resample(audioSpectrumRight, to: 32))
        derivedSpectrum = derived
        bag["g_AudioSpectrum16Left"] = .floatArray(derived.l16)
        bag["g_AudioSpectrum16Right"] = .floatArray(derived.r16)
        bag["g_AudioSpectrum32Left"] = .floatArray(derived.l32)
        bag["g_AudioSpectrum32Right"] = .floatArray(derived.r32)
        bag["g_AudioSpectrum64Left"] = .floatArray(audioSpectrumLeft)
        bag["g_AudioSpectrum64Right"] = .floatArray(audioSpectrumRight)
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

    private func texture(for surface: LayerSurface, layer: ImageLayer?, scope: TargetScope) -> MTLTexture? {
        switch surface {
        case .objectTexture: return layer?.texture?.texture
        case .compositeA: return layer?.compositeA
        case .compositeB: return layer?.compositeB
        case .named(let name): return scope.resolve(name)
        case .scene: return sceneTexture
        }
    }

    private func gpuTexture(for surface: LayerSurface, layer: ImageLayer?, scope: TargetScope) -> GPUTexture? {
        if case .objectTexture = surface { return layer?.texture }
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

    private func encode(pass: CompiledPass, layer: ImageLayer, visible: Bool,
                        producesComposite: Bool = false, globals: ShaderValueBag,
                        elapsed: Float, commandBuffer: MTLCommandBuffer) {
        let drawsToScene = pass.isFinalCandidate && visible
        let destinationSurface: LayerSurface = drawsToScene ? .scene : pass.destination
        guard let destination = texture(for: destinationSurface, layer: layer, scope: pass.scope) else {
            if debugLogging { print("  [\(layer.object.id)] \(pass.shaderName): NO DESTINATION \(destinationSurface)") }
            return
        }
        if !drawsToScene && pass.isFinalCandidate && !visible && !producesComposite { return }

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

        let drawsPuppet = layer.drawsPuppet(pass)
        let mvp = layer.matrix(for: pass, drawsToScene: drawsToScene)
        bag.set("g_ModelViewProjectionMatrix", mvp)
        bag.set("g_EffectModelViewProjectionMatrix", mvp)
        bag.set("g_ModelViewProjectionMatrixInverse", mvp.inverse)
        // With LIGHTING enabled genericimage3/4 position through
        // g_ViewProjectionMatrix * g_ModelMatrix and ignore the MVP. Image
        // passes use an identity view-projection, so the puppet transform must
        // also occupy the model slot for those shader variants.
        let modelMatrix = drawsPuppet ? mvp : SceneGeometry.copyMatrix(size: layer.size)
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
        guard let pipeline = try? context.pipeline(program: pass.program,
                                                   layout: drawsPuppet ? .puppet : .quad,
                                                   pixelFormat: destination.pixelFormat, blend: blend,
                                                   label: pass.shaderName) else {
            if debugLogging { print("  [\(layer.object.id)] \(pass.shaderName): PIPELINE FAILED") }
            encoder.endEncoding()
            return
        }
        encoder.setRenderPipelineState(pipeline)

        let vertices = layer.vertices(for: pass, drawsToScene: drawsToScene)
        if drawsPuppet, let binding = layer.puppet {
            // The mesh is far past Metal's inline vertex limit, so it lives in a
            // buffer, and the bone palette rides in with the other uniforms.
            encoder.setVertexBuffer(binding.vertexBuffer, offset: 0, index: BufferIndex.vertices)
            bag.set("g_Bones", .mat4x3Array(binding.boneMatrices))
        } else {
            vertices.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    encoder.setVertexBytes(base, length: bytes.count, index: BufferIndex.vertices)
                }
            }
        }
        encoder.setVertexBuffer(context.zeroBuffer, offset: 0, index: BufferIndex.zeroFill)

        if let writer = pass.uniformWriterVertex {
            var bytes = [UInt8](repeating: 0, count: writer.byteCount)
            writer.write(bag, into: &bytes)
            if (0..<BufferIndex.zeroFill).contains(writer.block.bufferIndex) {
                setUniforms(bytes, on: encoder, index: writer.block.bufferIndex, stage: .vertex)
            }
        }
        if let writer = pass.uniformWriterFragment {
            var bytes = [UInt8](repeating: 0, count: writer.byteCount)
            writer.write(bag, into: &bytes)
            if (0..<BufferIndex.zeroFill).contains(writer.block.bufferIndex) {
                setUniforms(bytes, on: encoder, index: writer.block.bufferIndex, stage: .fragment)
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

        if drawsPuppet, let binding = layer.puppet {
            // meshMatrix mirrors y, which reverses the winding, so this draw
            // never culls whatever the material asked for.
            encoder.setCullMode(.none)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: binding.indexCount,
                                          indexType: .uint16, indexBuffer: binding.indexBuffer,
                                          indexBufferOffset: 0)
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
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
        let alpha = scriptedValue(layer.object, "alpha")?.float
            ?? layer.object.alpha.resolveFloat(store, default: 1)
        let color = scriptedValue(layer.object, "color")?.vec3
            ?? layer.object.color.resolve(store).vec3 ?? SIMD3(repeating: 1)
        bag.set("g_Brightness", scriptedValue(layer.object, "brightness")?.float
            ?? layer.object.brightness.resolveFloat(store, default: 1))
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

    // MARK: Particles

    /// Simulates and draws one particle system straight into the scene target.
    ///
    /// Particles do not go through the image pass chain: the geometry is rebuilt on the CPU
    /// each frame and the vertex shader expands the billboards, so this is the one draw that
    /// needs the real model and view-projection matrices.
    /// Spawns a child system's particles from what its parent did this frame.
    ///
    /// A death child is an explosion: it fires where a parent particle expired,
    /// inheriting its velocity. A spawn child fires as the parent emits. A
    /// follow child rides the live parent particles and is re-seated each frame
    /// rather than accumulating.
    private func seed(child: ParticleLayer, spec: WEParticleSystem.Child, from parent: ParticleLayer) {
        switch spec.trigger {
        case .death:
            for event in parent.deathEvents where randomChance(spec.probability) {
                child.spawnExternal(at: event.position, inherit: event.velocity, scale: spec.scale.x)
            }
        case .spawn:
            for position in parent.birthEvents where randomChance(spec.probability) {
                child.spawnExternal(at: position, inherit: .zero, scale: spec.scale.x)
            }
        case .follow:
            child.removeAll()
            parent.livePositions { position in
                guard randomChance(spec.probability) else { return }
                child.spawnExternal(at: position, inherit: .zero, scale: spec.scale.x)
            }
        }
    }

    private var childRandom = FastRandom(seed: 0x5EED_1234)

    private func randomChance(_ probability: Float) -> Bool {
        guard probability < 1 else { return true }
        guard probability > 0 else { return false }
        return childRandom.float() < probability
    }

    private func encodeParticles(_ layer: ParticleLayer, globals: ShaderValueBag, elapsed: Float, dt: Float,
                                 projection: simd_float4x4, objectsById: [Int: WESceneObject],
                                 commandBuffer: MTLCommandBuffer) {
        guard let pass = layer.pass else { return }
        guard layer.object.visible.resolveBool(store, default: true) else { return }

        let transform = SceneGeometry.resolveTransform(of: layer.object, objects: objectsById, store: store)
        // An emitter can follow the music, so it needs this frame's spectrum.
        layer.audioSpectrum = audioSpectrumLeft
        if layer.recordEvents { layer.beginEvents() }
        layer.update(dt: dt, time: elapsed, sceneWidth: Float(sceneWidth), sceneHeight: Float(sceneHeight),
                     projection: projection, transform: transform,
                     parallax: parallaxOffset(for: layer.object), pointer: pointerPosition, store: store)

        // Children ride on the parent's frame: they see the same transform and
        // spawn from what the parent just did.
        for (spec, child) in layer.children {
            seed(child: child, spec: spec, from: layer)

            encodeParticles(child, globals: globals, elapsed: elapsed, dt: dt, projection: projection,
                            objectsById: objectsById, commandBuffer: commandBuffer)
        }

        let indexCount = layer.buildGeometry()
        guard indexCount > 0 else { return }

        if layer.vertexBuffer == nil {
            layer.vertexBuffer = context.device.makeBuffer(length: max(1, layer.vertexByteCount),
                                                           options: .storageModeShared)
            layer.vertexBuffer?.label = "particles.\(layer.object.id).vertices"
        }
        if layer.indexBuffer == nil {
            layer.indexBuffer = context.device.makeBuffer(length: max(1, layer.indexByteCount),
                                                          options: .storageModeShared)
            layer.indexBuffer?.label = "particles.\(layer.object.id).indices"
            if let buffer = layer.indexBuffer { layer.uploadIndices(into: buffer) }
        }
        guard let vertexBuffer = layer.vertexBuffer, let indexBuffer = layer.indexBuffer else { return }
        layer.uploadVertices(into: vertexBuffer, count: layer.liveParticleCount)

        var bag = ShaderValueBag()
        for (name, value) in pass.constants { bag.set(name, value) }
        for (name, dynamic) in pass.boundConstants {
            if let value = ShaderValue(json: dynamic.resolve(store)) { bag.set(name, value) }
        }
        bag.merge(globals)
        // Particle brightness comes from the material's overbright constant, not the object.
        var brightness: Float = 1
        if case .scalar(let value)? = pass.constants["g_Overbright"] { brightness = value }
        layer.fillUniforms(&bag, brightness: brightness)

        // Slot 0 is forced to the particle texture: the shader's own annotation default
        // (util/white) would otherwise win and every particle would be a white square.
        var bound: [Int: GPUTexture] = [:]
        for (slot, chain) in pass.slots {
            for entry in chain {
                switch entry {
                case .asset(let texture): bound[slot] = texture
                case .target(let name):
                    if pass.scope.resolve(name) != nil {
                        bound[slot] = gpuTexture(for: .named(name), layer: nil, scope: pass.scope)
                    }
                case .passInput: continue
                }
                if bound[slot] != nil { break }
            }
        }
        if let texture = layer.texture { bound[0] = texture }
        for (slot, texture) in bound {
            bag.set("g_Texture\(slot)Resolution", .vec4(texture.resolution))
        }

        let descriptor = MTLRenderPassDescriptor.color(sceneTexture, clear: nil)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "particles.\(layer.object.name)"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(sceneTexture.width), height: Double(sceneTexture.height),
                                        znear: 0, zfar: 1))
        encoder.setCullMode(.none)
        // Particle quads can be pushed outside the near plane by their own expansion.
        encoder.setDepthClipMode(.clamp)

        guard let pipeline = try? context.pipeline(program: pass.program, layout: layer.vertexLayout,
                                                   pixelFormat: sceneTexture.pixelFormat,
                                                   blend: BlendState(mode: pass.blending, writesAlpha: false),
                                                   label: "particles.\(pass.shaderName)") else {
            encoder.endEncoding()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: BufferIndex.vertices)
        encoder.setVertexBuffer(context.zeroBuffer, offset: 0, index: BufferIndex.zeroFill)

        if let writer = pass.uniformWriterVertex {
            var bytes = [UInt8](repeating: 0, count: writer.byteCount)
            writer.write(bag, into: &bytes)
            bytes.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: bytes.count, index: writer.block.bufferIndex) }
        }
        if let writer = pass.uniformWriterFragment {
            var bytes = [UInt8](repeating: 0, count: writer.byteCount)
            writer.write(bag, into: &bytes)
            bytes.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: bytes.count, index: writer.block.bufferIndex) }
        }

        let fallback = textures.white
        for binding in pass.fragmentTextureBindings {
            let texture = bound[binding.slot] ?? fallback
            encoder.setFragmentTexture(texture?.texture, index: binding.index)
            encoder.setFragmentSamplerState(context.sampler(texture?.samplerKey ?? .linearClamp), index: binding.index)
        }
        for binding in pass.vertexTextureBindings {
            let texture = bound[binding.slot] ?? fallback
            encoder.setVertexTexture(texture?.texture, index: binding.index)
            encoder.setVertexSamplerState(context.sampler(texture?.samplerKey ?? .linearClamp), index: binding.index)
        }

        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()

        if debugLogging {
            print("  [\(layer.object.id)] particles \(layer.liveParticleCount) live, \(indexCount / 6) quads, \(pass.shaderName)")
        }
    }

    // MARK: Present

    private func present(into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor.color(target, clear: SIMD4(0, 0, 0, 1))
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let pipeline = try? context.blitPipeline(pixelFormat: target.pixelFormat) else { return }
        encoder.label = "mirage.present"
        // "default" WE scaling: cover the target, cropping the axis whose aspect differs.
        let sceneAspect = Float(visibleWidth) / Float(visibleHeight)
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
    /// GPU time of the last offscreen frame, in milliseconds. Wall-clock time
    /// around a frame also contains the encode and any readback, so this is what
    /// tells a bandwidth problem apart from an encoding one.
    public private(set) var lastFrameGPUTime: Double = 0

    private var offscreenTarget: MTLTexture?

    /// Renders one frame into an offscreen texture.
    ///
    /// `readback` copies the result into `Data`, which costs a full-frame
    /// GPU-to-CPU copy (20 MB at 3008x1692) and has nothing to do with how the
    /// app draws, so a caller stepping the clock over many frames should only
    /// ask for it on the one it keeps.
    @discardableResult
    public func renderOffscreen(width: Int, height: Int, time: Double, readback: Bool = true) throws -> Data {
        guard width > 0, height > 0,
              width <= SceneRenderer.maximumRenderDimension,
              height <= SceneRenderer.maximumRenderDimension,
              let byteCount = WEPixelLayout.rgba8.checkedByteCount(width: width, height: height),
              byteCount <= WEPixelLayout.maximumAllocationByteCount else {
            throw RenderError.resourceCreation("valid offscreen target dimensions")
        }
        let output: MTLTexture
        if let existing = offscreenTarget, existing.width == width, existing.height == height {
            output = existing
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            guard let texture = context.device.makeTexture(descriptor: desc) else {
                throw RenderError.resourceCreation("offscreen target")
            }
            offscreenTarget = texture
            output = texture
        }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw RenderError.resourceCreation("command buffer")
        }
        render(into: output, time: time, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        let gpu = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        lastFrameGPUTime = gpu.isFinite && gpu > 0 ? gpu * 1000 : 0
        guard readback else { return Data() }

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
        var detail = "scene \(sceneWidth)x\(sceneHeight)"
        if visibleWidth != sceneWidth || visibleHeight != sceneHeight {
            detail += " cropped to \(visibleWidth)x\(visibleHeight)"
        }
        if renderWidth != visibleWidth || renderHeight != visibleHeight {
            detail += " rendered at \(renderWidth)x\(renderHeight)"
        }
        var lines: [String] = [detail + ", \(layers.count) image layers"
            + (usesAudioSpectrum ? ", reads audio" : "")]
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
