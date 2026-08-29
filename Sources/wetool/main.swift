import Foundation
import WEKit
import MirageRender
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Developer CLI for poking at Wallpaper Engine content.
//
//   wetool ls <project-dir|scene.pkg>
//   wetool info <project-dir>
//   wetool tex <project-dir> <material-name> <out.png>
//   wetool shader <project-dir> <shader-name> [COMBO=1 ...]   (prints GLSL + MSL)
//   wetool compile-all <project-dir>                            (compiles every shader referenced by the scene)
//   wetool render <project-dir> <out.png> [--time t] [--size WxH] [--display-res]
//   wetool scripts <project-dir> [--frames N] [--object NAME]  (runs SceneScript with no Metal)
//   wetool sound <project-dir> [--seconds N]                    (plays the scene's sound objects)

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else {
    print("usage: wetool <ls|info|tex|shader|compile-all|render|pipelines|scripts|sound> ...")
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func makeLocator(_ dir: String) -> (WEProject, AssetLocator) {
    let url = URL(fileURLWithPath: dir)
    guard let project = try? WEProject.load(directory: url) else { fail("no project.json in \(dir)") }
    let assets = AssetLocator.defaultAssetsDirectories()
    let fallback = ResourceLocator.fallbackAssetsDirectory()
    guard let locator = try? AssetLocator(project: project, assetsDirectories: assets, fallbackDirectory: fallback) else { fail("cannot open package") }
    return (project, locator)
}

func writePNG(_ rgba: Data, width: Int, height: Int, to path: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: rgba as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot encode png") }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func intOption(_ args: [String], _ name: String) -> Int? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return Int(args[i + 1])
}

func stringOption(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let rest = Array(args.dropFirst())
do {
switch command {
case "ls":
    guard let path = rest.first else { fail("usage: wetool ls <dir|pkg>") }
    var pkgURL = URL(fileURLWithPath: path)
    if pkgURL.hasDirectoryPath || (try? pkgURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        pkgURL = pkgURL.appendingPathComponent("scene.pkg")
    }
    let pkg = try WEPackage(url: pkgURL)
    print("\(pkg.version)  \(pkg.entries.count) files")
    for e in pkg.entries { print(String(format: "%10d  %@", e.length, e.name)) }

case "info":
    guard let dir = rest.first else { fail("usage: wetool info <dir>") }
    let (project, locator) = makeLocator(dir)
    print("title: \(project.title)\ntype: \(project.kind)\nfile: \(project.file)\nworkshop: \(project.workshopId ?? "-")")
    print("properties:")
    for p in project.properties { print("  \(p.name) (\(p.kind)) = \(p.defaultValue)  [\(p.displayLabel)]") }
    if project.kind == .scene, let sceneJSON = locator.json(project.file) {
        let scene = WEScene(json: sceneJSON)
        print("ortho: \(scene.general.orthoWidth ?? 0)x\(scene.general.orthoHeight ?? 0)  objects: \(scene.objects.count)")
        for o in scene.objects {
            let effects = o.effects.map { ($0.file as NSString).lastPathComponent == "effect.json" ? ($0.file as NSString).deletingLastPathComponent : $0.file }
            print("  [\(o.id)] \(o.kind) \(o.name)  image=\(o.imagePath ?? "-") particle=\(o.particlePath ?? "-") effects=\(effects)")
        }
    }

case "scripts":
    // Runs the scripting layer on its own, with no Metal and no renderer, which is
    // how you tell a broken script from a broken pass chain.
    guard let dir = rest.first else { fail("usage: wetool scripts <dir> [--frames N] [--object NAME]") }
    let frameCount = intOption(rest, "--frames") ?? 3
    let onlyObject = stringOption(rest, "--object")
    let (project, locator) = makeLocator(dir)
    guard let sceneJSON = locator.json(project.file) else { fail("no scene file") }
    let scene = WEScene(json: sceneJSON)
    let store = PropertyStore(properties: project.properties)
    let width = Float(scene.general.orthoWidth ?? 1920)
    let height = Float(scene.general.orthoHeight ?? 1080)
    let runtime = ScriptRuntime(workshopId: project.workshopId,
                                canvasSize: SIMD2(width, height), store: store, locator: locator)
    var scripted: [(value: DynamicValue, object: String, property: String)] = []
    for object in scene.objects {
        let name = object.scriptName
        var values: [String: JSON] = [
            "name": .string(object.name), "id": .number(Double(object.id)),
            "origin": object.origin.resolve(store), "scale": object.scale.resolve(store),
            "angles": object.angles.resolve(store), "alpha": object.alpha.resolve(store),
            "color": object.color.resolve(store), "brightness": object.brightness.resolve(store),
            "visible": object.visible.resolve(store), "parallaxDepth": object.parallaxDepth.resolve(store),
        ]
        if let size = object.size { values["size"] = size.resolve(store) }
        if let text = object.textValue { values["text"] = text.resolve(store) }
        runtime.seed(object: name, values: values)
        for (property, value) in [("origin", object.origin), ("scale", object.scale), ("angles", object.angles),
                                  ("visible", object.visible), ("alpha", object.alpha), ("color", object.color),
                                  ("brightness", object.brightness), ("parallaxdepth", object.parallaxDepth)] {
            if value.script != nil { scripted.append((value, name, property)) }
        }
        if let size = object.size, size.script != nil { scripted.append((size, name, "size")) }
        if let text = object.textValue, text.script != nil { scripted.append((text, name, "text")) }
    }
    let selected = scripted.filter { onlyObject == nil || $0.object == onlyObject! }
    for entry in selected { runtime.register(entry.value, object: entry.object, property: entry.property) }
    print("\(selected.count) scripted values, \(runtime.boundCount) registered")
    for frame in 0..<max(1, frameCount) {
        runtime.beginFrame(time: Double(frame) / 60, frameTime: 1.0 / 60,
                           dayTime: Double(SceneRenderer.dayTime()), cursor: SIMD2(0.5, 0.5))
    }
    for entry in selected {
        let produced = entry.value.resolve(store)
        let changed = produced == entry.value.value ? "unchanged" : "-> \(produced)"
        print("  \(entry.object).\(entry.property): \(entry.value.value) \(changed)")
    }
    if let watched = stringOption(rest, "--watch") {
        print("layer writes on \(watched): \(runtime.layerWrites[watched] ?? [:])")
    }
    if !runtime.diagnostics.isEmpty {
        print("diagnostics:")
        for d in runtime.diagnostics { print("  \(d)") }
    }

case "sound":
    // Plays a scene's sound objects for a few seconds, with no renderer, which is
    // the only way to hear whether extraction and the start delays work.
    guard let dir = rest.first else { fail("usage: wetool sound <dir> [--seconds N]") }
    let seconds = Double(intOption(rest, "--seconds") ?? 6)
    let (project, locator) = makeLocator(dir)
    guard let sceneJSON = locator.json(project.file) else { fail("no scene file") }
    let scene = WEScene(json: sceneJSON)
    let store = PropertyStore(properties: project.properties)
    let sounds = scene.objects.filter { $0.kind == .sound }
    print("\(sounds.count) sound objects")
    for object in sounds {
        print("  \(object.name): mode=\(object.playbackMode ?? "loop") "
              + "volume=\(object.volume.resolveFloat(store, default: 1)) "
              + "delay=\(object.raw["mintime"].double ?? 0)...\(object.raw["maxtime"].double ?? 0) "
              + "startsilent=\(object.raw["startsilent"].bool ?? false)")
        for path in object.sounds { print("     \(path)") }
    }
    let player = WallpaperSoundPlayer(locator: locator, workshopId: project.workshopId)
    for object in sounds {
        player.add(paths: object.sounds, mode: object.playbackMode ?? "loop",
                   volume: object.volume.resolveFloat(store, default: 1),
                   minTime: object.raw["mintime"].double ?? 0,
                   maxTime: object.raw["maxtime"].double ?? 0,
                   startSilent: object.raw["startsilent"].bool ?? false)
    }
    player.setVolume(1, muted: false)
    player.start()
    var t = 0.0
    while t < seconds {
        player.update(time: t)
        Thread.sleep(forTimeInterval: 1.0 / 30)
        t += 1.0 / 30
    }
    player.stop()
    if player.diagnostics.isEmpty { print("no diagnostics") }
    else { for d in player.diagnostics { print("  \(d)") } }

case "tex":
    guard rest.count >= 3 else { fail("usage: wetool tex <dir> <material-name> <out.png>") }
    let (_, locator) = makeLocator(rest[0])
    guard let data = locator.textureData(named: rest[1]) else { fail("texture not found: \(rest[1])") }
    let tex = try WETexture.decode(data)
    print("format=\(tex.format) flags=\(tex.flags.rawValue) layout=\(tex.layout) size=\(tex.width)x\(tex.height) image=\(tex.imageWidth)x\(tex.imageHeight) mips=\(tex.mipCount) frames=\(tex.frames.count) video=\(tex.isVideo)")
    if tex.isVideo { fail("video texture; not writing png") }
    let mip = tex.mip0
    guard let rgba = BlockCompression.decodeToRGBA8(mip.data, width: mip.width, height: mip.height, layout: tex.layout) else { fail("cannot decode \(tex.layout)") }
    writePNG(rgba, width: mip.width, height: mip.height, to: rest[2])
    print("wrote \(rest[2])")

case "shader":
    guard rest.count >= 2 else { fail("usage: wetool shader <dir> <shader-name> [COMBO=1 ...] [--msl]") }
    let (_, locator) = makeLocator(rest[0])
    var combos: [String: Int] = [:]
    var showMSL = false
    for a in rest.dropFirst(2) {
        if a == "--msl" { showMSL = true; continue }
        let kv = a.split(separator: "=")
        if kv.count == 2, let v = Int(kv[1]) { combos[String(kv[0]).uppercased()] = v }
    }
    let pre = ShaderPreprocessor(locator: locator)
    let source = try pre.load(rest[1])
    // Fill in declared combo defaults, exactly as the renderer does.
    for c in source.combos where combos[c.name] == nil { combos[c.name] = c.defaultValue }
    print("// combos declared: \(source.combos.map { "\($0.name)=\($0.defaultValue)" })")
    print("// combos used: \(combos.sorted { $0.key < $1.key })")
    print("// uniforms: \(source.uniforms.map { "\($0.type) \($0.name)" + ($0.materialKey.map { " (\($0))" } ?? "") })")
    do {
        let program = try ShaderCompiler.shared.compile(source: source, combos: combos)
        if showMSL {
            print("// ===== VERTEX MSL =====\n\(program.vertex.msl)\n// ===== FRAGMENT MSL =====\n\(program.fragment.msl)")
        } else {
            print("// ===== VERTEX GLSL =====\n\(program.glslVertex)\n// ===== FRAGMENT GLSL =====\n\(program.glslFragment)")
        }
        print("// vertex inputs: \(program.vertex.inputs.map { "\($0.name)@\($0.location):\($0.baseType)\($0.vecSize)" })")
        print("// vertex uniforms: buffer \(program.vertex.uniforms?.bufferIndex ?? -1) size \(program.vertex.uniforms?.size ?? 0): \(program.vertex.uniforms?.members.map { "\($0.name)@\($0.offset)" } ?? [])")
        print("// fragment uniforms: buffer \(program.fragment.uniforms?.bufferIndex ?? -1) size \(program.fragment.uniforms?.size ?? 0): \(program.fragment.uniforms?.members.map { "\($0.name)@\($0.offset)" } ?? [])")
        print("// vertex textures: \(program.vertex.textures.map { "\($0.name)@\($0.index)" })  fragment textures: \(program.fragment.textures.map { "\($0.name)@\($0.index)" })")
        if !program.repairs.isEmpty { print("// repairs: \(program.repairs)") }
    } catch {
        // Still show the finalized GLSL so the reported line numbers can be read.
        if let (v, f) = try? ShaderCompiler.shared.finalizedGLSL(source: source, combos: combos) {
            let numbered = { (t: String) in t.components(separatedBy: "\n").enumerated().map { String(format: "%4d| %@", $0.offset, $0.element) }.joined(separator: "\n") }
            print("// ===== VERTEX GLSL =====\n\(numbered(v))\n// ===== FRAGMENT GLSL =====\n\(numbered(f))")
        }
        fail("compile failed: \(error)")
    }

case "compile-all":
    guard let dir = rest.first else { fail("usage: wetool compile-all <dir>") }
    let (project, locator) = makeLocator(dir)
    guard let sceneJSON = locator.json(project.file) else { fail("scene not found") }
    let scene = WEScene(json: sceneJSON)
    let pre = ShaderPreprocessor(locator: locator)
    var ok = 0, failed = 0
    var seen = Set<String>()
    func compileMaterial(_ path: String, extraCombos: [String: Int]) {
        guard let material = locator.material(path) else { print("  ! material not found: \(path)"); failed += 1; return }
        for pass in material.passes {
            var combos = pass.combos
            for (k, v) in extraCombos { combos[k] = v }
            let key = pass.shader + " " + combos.description
            guard seen.insert(key).inserted else { continue }
            do {
                let src = try pre.load(pass.shader)
                var all = combos
                for c in src.combos where all[c.name] == nil { all[c.name] = c.defaultValue }
                _ = try ShaderCompiler.shared.compile(source: src, combos: all)
                ok += 1
                print("  ok  \(pass.shader) \(all)")
            } catch {
                failed += 1
                print("  FAIL \(pass.shader) \(combos): \(error)")
            }
        }
    }
    for o in scene.objects {
        if let img = o.imagePath, let model = locator.model(img) {
            compileMaterial(model.material, extraCombos: [:])
            for e in o.effects {
                guard let effect = locator.effect(e.file) else { print("  ! effect not found: \(e.file)"); failed += 1; continue }
                for (i, p) in effect.passes.enumerated() {
                    guard let m = p.material else { continue }
                    var combos = p.combos
                    if i < e.passOverrides.count { for (k, v) in e.passOverrides[i].combos { combos[k] = v } }
                    compileMaterial(m, extraCombos: combos)
                }
            }
        }
        if let pp = o.particlePath, let pj = locator.json(pp), let m = pj["material"].string {
            compileMaterial(m, extraCombos: [:])
        }
    }
    print("compiled \(ok) shader variants, \(failed) failures")
    if !locator.unresolvedPaths.isEmpty { print("unresolved: \(locator.unresolvedPaths)") }

case "render":
    guard rest.count >= 2 else { fail("usage: wetool render <dir> <out.png> [--time t] [--size WxH] [--frames N] [--display-res]") }
    var time = 1.0
    var size = (1920, 1080)
    var i = 2
    while i < rest.count {
        if rest[i] == "--time", i + 1 < rest.count { time = Double(rest[i + 1]) ?? time; i += 2; continue }
        if rest[i] == "--size", i + 1 < rest.count {
            let p = rest[i + 1].split(separator: "x")
            if p.count == 2, let w = Int(p[0]), let h = Int(p[1]) { size = (w, h) }
            i += 2; continue
        }
        i += 1
    }
    var frames = 1
    if let i = rest.firstIndex(of: "--frames"), i + 1 < rest.count { frames = max(1, Int(rest[i + 1]) ?? 1) }
    let setupStart = Date()
    let (project, locator) = makeLocator(rest[0])
    // Like the app, the scene renders at the resolution it was authored at unless
    // --display-res asks for the output size instead.
    let renderer = try SceneRenderer(project: project, locator: locator, outputSize: size,
                                     scaleToOutput: rest.contains("--display-res"))
    let setupMs = Date().timeIntervalSince(setupStart) * 1000
    print(renderer.summary)

    // Simulated systems (particles, video) need several frames before they show anything,
    // so step the clock up to `time` over `frames` steps and keep the last image.
    let start = Date()
    var rgba = Data()
    var gpuTotal = 0.0
    for frame in 0..<frames {
        let t = frames == 1 ? time : time * Double(frame + 1) / Double(frames)
        // Only the frame that gets written needs the readback; timing the others
        // with it would measure a 20 MB copy the app never makes.
        let last = frame == frames - 1
        let data = try renderer.renderOffscreen(width: size.0, height: size.1, time: t, readback: last)
        if last { rgba = data }
        gpuTotal += renderer.lastFrameGPUTime
    }
    if frames > 1 {
        let ms = Date().timeIntervalSince(start) * 1000 / Double(frames)
        let gpu = gpuTotal / Double(frames)
        print(String(format: "setup %.0f ms, %.2f ms/frame (%.0f fps), gpu %.2f ms, over %d frames at %dx%d",
                     setupMs, ms, 1000 / ms, gpu, frames, size.0, size.1))
    }
    writePNG(rgba, width: size.0, height: size.1, to: rest[1])
    print("wrote \(rest[1])")
    if !locator.unresolvedPaths.isEmpty { print("unresolved: \(locator.unresolvedPaths)") }
    if !renderer.diagnostics.isEmpty { print(renderer.diagnostics.joined(separator: "\n")) }
    if !renderer.scriptDiagnostics.isEmpty { print(renderer.scriptDiagnostics.joined(separator: "\n")) }

case "pipelines":
    // Compile every shader variant a scene uses all the way to an MTLRenderPipelineState.
    guard let dir = rest.first else { fail("usage: wetool pipelines <dir> [--verbose]") }
    let verbose = rest.contains("--verbose")
    let (project, locator) = makeLocator(dir)
    guard let sceneJSON = locator.json(project.file) else { fail("scene not found") }
    let scene = WEScene(json: sceneJSON)
    guard let context = try? RenderContext() else { fail("no Metal device") }
    let pre = ShaderPreprocessor(locator: locator)
    var ok = 0, compileFailed = 0, pipelineFailed = 0
    var seen = Set<String>()
    var errors: [String] = []

    func build(_ shaderName: String, combos: [String: Int], layout: VertexLayout, blend: WEBlendMode) {
        let key = "\(shaderName)|\(combos.sorted { $0.key < $1.key })|\(layout.name)|\(blend.rawValue)"
        guard seen.insert(key).inserted else { return }
        let source: ShaderProgramSource
        do { source = try pre.load(shaderName) } catch {
            compileFailed += 1; errors.append("  MISSING \(shaderName): \(error)"); return
        }
        var all = combos
        for c in source.combos where all[c.name] == nil { all[c.name] = c.defaultValue }
        let program: ShaderCompiler.Program
        do { program = try ShaderCompiler.shared.compile(source: source, combos: all) } catch {
            compileFailed += 1
            errors.append("  GLSL  \(shaderName) \(all): \(String(describing: error).prefix(220))")
            return
        }
        do {
            _ = try context.pipeline(program: program, layout: layout, pixelFormat: .rgba8Unorm,
                                     blend: BlendState(mode: blend, writesAlpha: true), label: shaderName)
            ok += 1
            if verbose {
                let vu = program.vertex.uniforms.map { "\($0.size)B@\($0.bufferIndex)" } ?? "-"
                let fu = program.fragment.uniforms.map { "\($0.size)B@\($0.bufferIndex)" } ?? "-"
                print("  ok  \(shaderName) \(all) vtx=\(program.vertex.inputs.map(\.name)) ubo v:\(vu) f:\(fu) tex=\(program.fragment.textures.map { "\($0.name)@\($0.index)" })")
            }
        } catch {
            pipelineFailed += 1
            errors.append("  MSL   \(shaderName) \(all): \(String(describing: error).prefix(400))")
        }
    }

    func buildMaterial(_ path: String, extra: [String: Int], layout: VertexLayout) {
        guard let material = locator.material(path) else { errors.append("  MISSING material \(path)"); compileFailed += 1; return }
        for pass in material.passes {
            var combos = pass.combos
            for (k, v) in extra { combos[k] = v }
            build(pass.shader, combos: combos, layout: layout, blend: pass.blending)
        }
    }

    for o in scene.objects {
        if let img = o.imagePath, let model = locator.model(img) {
            buildMaterial(model.material, extra: [:], layout: .quad)
            for e in o.effects {
                guard let effect = locator.effect(e.file) else { continue }
                for (i, p) in effect.passes.enumerated() {
                    guard let m = p.material else { continue }
                    var combos = p.combos
                    if i < e.passOverrides.count { for (k, v) in e.passOverrides[i].combos { combos[k] = v } }
                    buildMaterial(m, extra: combos, layout: .quad)
                }
            }
        }
        if let pp = o.particlePath, let pj = locator.json(pp), let m = pj["material"].string {
            buildMaterial(m, extra: ["THICKFORMAT": 1], layout: .particle)
        }
    }
    for e in errors { print(e) }
    print("pipelines: \(ok) ok, \(compileFailed) glsl failures, \(pipelineFailed) msl/pipeline failures")

default:
    fail("unknown command \(command)")
}
} catch {
    fail("\(error)")
}
