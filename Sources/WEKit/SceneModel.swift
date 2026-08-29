import Foundation
import simd

// MARK: - Scene

public struct WEScene {
    public struct Camera {
        public var eye: SIMD3<Float> = SIMD3(0, 0, 0)
        public var center: SIMD3<Float> = SIMD3(0, 0, -1)
        public var up: SIMD3<Float> = SIMD3(0, 1, 0)
        public var fov: Float = 50
        public var nearZ: Float = 0.01
        public var farZ: Float = 10000
    }

    public struct General {
        public var orthoWidth: Int?
        public var orthoHeight: Int?
        public var orthoAuto: Bool = false
        public var clearColor = DynamicValue(value: .string("1 1 1"))
        public var clearEnabled = DynamicValue(value: .bool(true))
        public var ambientColor = DynamicValue(value: .string("0.3 0.3 0.3"))
        public var skylightColor = DynamicValue(value: .string("0.3 0.3 0.3"))
        public var bloom = DynamicValue(value: .bool(false))
        public var bloomStrength = DynamicValue(value: .number(2))
        // 0.65 is both what real scenes carry and what downsample_quarter_bloom
        // declares as its annotation default.
        public var bloomThreshold = DynamicValue(value: .number(0.65))
        public var bloomTint = DynamicValue(value: .string("1 1 1"))
        public var cameraParallax = DynamicValue(value: .bool(false))
        public var cameraParallaxAmount = DynamicValue(value: .number(1))
        public var cameraParallaxDelay = DynamicValue(value: .number(0.1))
        public var cameraParallaxMouseInfluence = DynamicValue(value: .number(1))
        public var cameraShake = DynamicValue(value: .bool(false))
        public var cameraShakeAmplitude = DynamicValue(value: .number(0.5))
        public var cameraShakeRoughness = DynamicValue(value: .number(1))
        public var cameraShakeSpeed = DynamicValue(value: .number(3))
        public var cameraFade = DynamicValue(value: .bool(false))
        public var zoom = DynamicValue(value: .number(1))
        public var hdr = false
    }

    public let raw: JSON
    public let camera: Camera
    public let general: General
    public let objects: [WESceneObject]
    public let version: Int

    public init(json: JSON) {
        raw = json
        var cam = Camera()
        let c = json["camera"]
        if let v = c["eye"].vec3 { cam.eye = v }
        if let v = c["center"].vec3 { cam.center = v }
        if let v = c["up"].vec3 { cam.up = v }
        let g = json["general"]
        if let v = (c["fov"].float ?? g["fov"].float) { cam.fov = v }
        if let v = (c["nearz"].float ?? g["nearz"].float) { cam.nearZ = v }
        if let v = (c["farz"].float ?? g["farz"].float) { cam.farZ = v }
        camera = cam

        var gen = General()
        let ortho = g["orthogonalprojection"]
        gen.orthoWidth = ortho["width"].int
        gen.orthoHeight = ortho["height"].int
        gen.orthoAuto = ortho["auto"].bool ?? (gen.orthoWidth == nil)
        func dyn(_ key: String, _ def: DynamicValue) -> DynamicValue {
            let v = g[key]
            return v.isNull ? def : DynamicValue.parse(v)
        }
        gen.clearColor = dyn("clearcolor", gen.clearColor)
        gen.clearEnabled = dyn("clearenabled", gen.clearEnabled)
        gen.ambientColor = dyn("ambientcolor", gen.ambientColor)
        gen.skylightColor = dyn("skylightcolor", gen.skylightColor)
        gen.bloom = dyn("bloom", gen.bloom)
        gen.bloomStrength = dyn("bloomstrength", gen.bloomStrength)
        gen.bloomThreshold = dyn("bloomthreshold", gen.bloomThreshold)
        gen.bloomTint = dyn("bloomtint", gen.bloomTint)
        gen.cameraParallax = dyn("cameraparallax", gen.cameraParallax)
        gen.cameraParallaxAmount = dyn("cameraparallaxamount", gen.cameraParallaxAmount)
        gen.cameraParallaxDelay = dyn("cameraparallaxdelay", gen.cameraParallaxDelay)
        gen.cameraParallaxMouseInfluence = dyn("cameraparallaxmouseinfluence", gen.cameraParallaxMouseInfluence)
        gen.cameraShake = dyn("camerashake", gen.cameraShake)
        gen.cameraShakeAmplitude = dyn("camerashakeamplitude", gen.cameraShakeAmplitude)
        gen.cameraShakeRoughness = dyn("camerashakeroughness", gen.cameraShakeRoughness)
        gen.cameraShakeSpeed = dyn("camerashakespeed", gen.cameraShakeSpeed)
        gen.cameraFade = dyn("camerafade", gen.cameraFade)
        gen.zoom = dyn("zoom", gen.zoom)
        gen.hdr = g["hdr"].bool ?? false
        general = gen

        objects = (json["objects"].array ?? []).map(WESceneObject.init(json:))
        version = json["version"].int ?? 1
    }

    public static func parse(_ data: Data) throws -> WEScene {
        WEScene(json: try JSON.parse(data))
    }
}

// MARK: - Objects

public struct WEEffectPassOverride {
    public let id: Int
    public let combos: [String: Int]
    public let constantShaderValues: [String: JSON]
    /// `nil` entries mean "not overridden".
    public let textures: [String?]
    public let userTextures: [String?]

    public init(json: JSON) {
        id = json["id"].int ?? 0
        combos = WEMaterialPass.parseCombos(json["combos"])
        constantShaderValues = json["constantshadervalues"].object ?? [:]
        textures = WEMaterialPass.parseTextures(json["textures"])
        userTextures = WEMaterialPass.parseTextures(json["usertextures"])
    }
}

public struct WEEffectInstance {
    public let file: String
    public let id: Int
    public let name: String
    public let visible: DynamicValue
    public let passOverrides: [WEEffectPassOverride]
    public let raw: JSON

    public init(json: JSON) {
        raw = json
        file = json["file"].string ?? ""
        id = json["id"].int ?? 0
        name = json["name"].string ?? ""
        visible = json["visible"].isNull ? DynamicValue(value: .bool(true)) : DynamicValue.parse(json["visible"])
        passOverrides = (json["passes"].array ?? []).map(WEEffectPassOverride.init(json:))
    }
}

public struct WESceneObject: Identifiable {
    public enum Kind: String { case image, particle, sound, text, light, group }

    public let raw: JSON
    public let id: Int
    public let name: String
    public let kind: Kind
    public let imagePath: String?
    public let particlePath: String?
    public let particleInline: JSON?
    public let sounds: [String]
    public let text: JSON?
    /// `text` parsed once, so a scripted string keeps one identity across frames.
    public let textValue: DynamicValue?

    public let origin: DynamicValue
    public let scale: DynamicValue
    public let angles: DynamicValue
    public let size: DynamicValue?
    public let visible: DynamicValue
    public let alpha: DynamicValue
    public let color: DynamicValue
    public let brightness: DynamicValue
    public let parallaxDepth: DynamicValue
    public let colorBlendMode: Int
    public let alignment: String
    public let fullscreen: Bool
    public let copyBackground: Bool
    public let solid: Bool
    public let perspective: Bool
    public let ledSource: Bool
    public let passthrough: Bool
    public let effects: [WEEffectInstance]
    public let instanceOverride: JSON
    /// A *material* instance: per-object overrides of the model's material,
    /// usually to point a slot at another layer's composite. Not to be confused
    /// with `instanceoverride`, which belongs to particles.
    public let instance: JSON
    public let animationLayers: JSON
    public let dependencies: [Int]
    public let parent: Int?
    public let playbackMode: String?
    public let volume: DynamicValue

    /// The name scripts address this object by. Wallpaper Engine keys layers by
    /// name, and an unnamed object still has to be addressable.
    public var scriptName: String { name.isEmpty ? "object\(id)" : name }

    public init(json: JSON) {
        raw = json
        id = json["id"].int ?? 0
        name = json["name"].string ?? ""
        imagePath = json["image"].string
        switch json["particle"] {
        case .string(let s): particlePath = s; particleInline = nil
        case .object: particlePath = nil; particleInline = json["particle"]
        default: particlePath = nil; particleInline = nil
        }
        sounds = (json["sound"].array ?? []).compactMap(\.string)
        text = json["text"].isNull ? nil : json["text"]
        textValue = text.map(DynamicValue.parse)
        if imagePath != nil { kind = .image }
        else if particlePath != nil || particleInline != nil { kind = .particle }
        else if !sounds.isEmpty { kind = .sound }
        else if text != nil { kind = .text }
        else if json["light"].exists { kind = .light }
        else { kind = .group }

        func dyn(_ key: String, _ def: JSON) -> DynamicValue {
            let v = json[key]
            return v.isNull ? DynamicValue(value: def) : DynamicValue.parse(v)
        }
        origin = dyn("origin", .string("0 0 0"))
        scale = dyn("scale", .string("1 1 1"))
        angles = dyn("angles", .string("0 0 0"))
        size = json["size"].isNull ? nil : DynamicValue.parse(json["size"])
        visible = dyn("visible", .bool(true))
        alpha = dyn("alpha", .number(1))
        color = dyn("color", .string("1 1 1"))
        brightness = dyn("brightness", .number(1))
        parallaxDepth = dyn("parallaxDepth", .string("0 0"))
        colorBlendMode = json["colorBlendMode"].int ?? 0
        alignment = json["alignment"].string ?? "center"
        fullscreen = json["fullscreen"].bool ?? false
        copyBackground = json["copybackground"].bool ?? false
        solid = json["solid"].bool ?? false
        perspective = json["perspective"].bool ?? false
        ledSource = json["ledsource"].bool ?? false
        passthrough = json["config"]["passthrough"].bool ?? false
        effects = (json["effects"].array ?? []).map(WEEffectInstance.init(json:))
        instanceOverride = json["instanceoverride"]
        instance = json["instance"]
        animationLayers = json["animationlayers"]
        dependencies = (json["dependencies"].array ?? []).compactMap(\.int)
        parent = json["parent"].int
        playbackMode = json["playbackmode"].string
        volume = dyn("volume", .number(1))
    }
}

// MARK: - Model / Material / Effect

public struct WEModel {
    public let material: String
    public let width: Int?
    public let height: Int?
    public let autosize: Bool
    public let fullscreen: Bool
    public let passthrough: Bool
    public let solidLayer: Bool
    public let noPadding: Bool
    public let projectLayer: Bool
    public let puppet: String?
    public let raw: JSON

    public init(json: JSON) {
        raw = json
        material = json["material"].string ?? ""
        width = json["width"].int
        height = json["height"].int
        autosize = json["autosize"].bool ?? false
        fullscreen = json["fullscreen"].bool ?? false
        passthrough = json["passthrough"].bool ?? false
        solidLayer = json["solidlayer"].bool ?? false
        noPadding = json["nopadding"].bool ?? false
        projectLayer = json["projectlayer"].bool ?? false
        puppet = json["puppet"].string
    }
}

public enum WEBlendMode: String {
    case normal, translucent, additive, disabled

    public init(string: String?) {
        switch string?.lowercased() {
        case "translucent": self = .translucent
        case "additive": self = .additive
        case "disabled": self = .disabled
        default: self = .normal
        }
    }
}

public struct WEMaterialPass {
    public let shader: String
    public let blending: WEBlendMode
    public let cullMode: String
    public let depthTest: Bool
    public let depthWrite: Bool
    /// Texture slot names; `nil` = empty slot (bound to pass input / shader default).
    public let textures: [String?]
    public let userTextures: [String?]
    public let combos: [String: Int]
    public let constantShaderValues: [String: JSON]
    public let raw: JSON

    public init(json: JSON) {
        raw = json
        shader = json["shader"].string ?? "genericimage2"
        blending = WEBlendMode(string: json["blending"].string)
        cullMode = json["cullmode"].string ?? "nocull"
        depthTest = (json["depthtest"].string ?? "disabled") == "enabled"
        depthWrite = (json["depthwrite"].string ?? "disabled") == "enabled"
        textures = WEMaterialPass.parseTextures(json["textures"])
        userTextures = WEMaterialPass.parseTextures(json["usertextures"])
        combos = WEMaterialPass.parseCombos(json["combos"])
        constantShaderValues = json["constantshadervalues"].object ?? [:]
    }

    static func parseTextures(_ json: JSON) -> [String?] {
        (json.array ?? []).map { t -> String? in
            switch t {
            case .string(let s): return s.isEmpty ? nil : s
            case .object: return t["name"].string
            default: return nil
            }
        }
    }

    static func parseCombos(_ json: JSON) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in json.object ?? [:] {
            if let i = v.int { out[k.uppercased()] = i }
        }
        return out
    }
}

public struct WEMaterial {
    public let passes: [WEMaterialPass]
    public let raw: JSON

    public init(json: JSON) {
        raw = json
        passes = (json["passes"].array ?? []).map(WEMaterialPass.init(json:))
    }
}

public struct WEEffectBind {
    public let name: String
    public let index: Int
}

public struct WEEffectFBO {
    public let name: String
    public let scale: Float
    public let format: String
    public let unique: Bool
}

public struct WEEffectPass {
    public let material: String?
    public let target: String?
    public let binds: [WEEffectBind]
    public let combos: [String: Int]
    public let constantShaderValues: [String: JSON]
    public let textures: [String?]
    public let command: String?
    public let source: String?
    public let compose: Bool
    public let raw: JSON

    public init(json: JSON) {
        raw = json
        material = json["material"].string
        target = json["target"].string
        binds = (json["bind"].array ?? []).compactMap { b in
            guard let name = b["name"].string else { return nil }
            return WEEffectBind(name: name, index: b["index"].int ?? 0)
        }
        combos = WEMaterialPass.parseCombos(json["combos"])
        constantShaderValues = json["constantshadervalues"].object ?? [:]
        textures = WEMaterialPass.parseTextures(json["textures"])
        command = json["command"].string
        source = json["source"].string
        compose = json["compose"].bool ?? false
    }
}

public struct WEEffect {
    public let name: String
    public let passes: [WEEffectPass]
    public let fbos: [WEEffectFBO]
    public let dependencies: [String]
    public let raw: JSON

    public init(json: JSON) {
        raw = json
        name = json["name"].string ?? ""
        passes = (json["passes"].array ?? []).map(WEEffectPass.init(json:))
        fbos = (json["fbos"].array ?? []).compactMap { f in
            guard let name = f["name"].string else { return nil }
            return WEEffectFBO(name: name, scale: f["scale"].float ?? 1, format: f["format"].string ?? "rgba8888", unique: f["unique"].bool ?? false)
        }
        dependencies = (json["dependencies"].array ?? []).compactMap(\.string)
    }
}

// MARK: - Helpers

public extension String {
    /// Render-target names start with `_rt_` or `_alias_`.
    var isRenderTargetName: Bool { hasPrefix("_rt_") || hasPrefix("_alias_") || hasPrefix("$") }
}
