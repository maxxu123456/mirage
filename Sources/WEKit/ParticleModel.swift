import Foundation
import simd

/// A parsed `particles/*.json` description.
///
/// Wallpaper Engine builds a particle system out of four ordered lists: emitters spawn
/// particles, initializers randomise a new particle's properties, operators mutate every
/// live particle each frame, and a renderer decides how they are turned into geometry.
/// The lists are order sensitive, so they are kept as arrays rather than a dictionary.
public struct WEParticleSystem {
    public enum AnimationMode: String {
        case sequence, randomframe, once
    }

    public let material: String
    public let maxCount: Int
    public let startTime: Float
    public let flags: Int
    public let animationMode: AnimationMode
    public let sequenceMultiplier: Float
    public let emitters: [Emitter]
    public let initializers: [Initializer]
    public let operators: [Operator]
    public let renderer: Renderer
    public let controlPoints: [ControlPoint]

    /// bit 0: positions are world space, bit 1: no sprite frame blending, bit 2: perspective.
    public var isWorldSpace: Bool { flags & 1 != 0 }
    public var noFrameBlending: Bool { flags & 2 != 0 }
    public var isPerspective: Bool { flags & 4 != 0 }

    public init?(json: JSON) {
        guard let material = json["material"].string else { return nil }
        self.material = material
        // A missing or zero maxcount means "engine default"; the reference renderers use 1000.
        let declared = json["maxcount"].int ?? 0
        self.maxCount = declared > 0 ? min(declared, 20_000) : 1000
        self.startTime = json["starttime"].float ?? 0
        self.flags = json["flags"].int ?? 0
        self.animationMode = AnimationMode(rawValue: json["animationmode"].string ?? "sequence") ?? .sequence
        self.sequenceMultiplier = json["sequencemultiplier"].float ?? 1
        self.emitters = (json["emitter"].array ?? []).compactMap(Emitter.init(json:))
        self.initializers = (json["initializer"].array ?? []).map(Initializer.init(json:))
        self.operators = (json["operator"].array ?? []).map(Operator.init(json:))
        self.renderer = Renderer(json: (json["renderer"].array ?? []).first ?? .null)
        self.controlPoints = (json["controlpoint"].array ?? []).map(ControlPoint.init(json:))
    }

    // MARK: Emitter

    public struct Emitter {
        public enum Kind { case box, sphere }

        public let kind: Kind
        public let origin: SIMD3<Float>
        public let directions: SIMD3<Float>
        public let distanceMin: SIMD3<Float>
        public let distanceMax: SIMD3<Float>
        public let sign: SIMD3<Float>
        public let rate: Float
        public let instantaneous: Int
        public let speedMin: Float
        public let speedMax: Float
        public let controlPoint: Int
        public let flags: Int
        public let delay: Float
        public let duration: Float
        public let minPeriodicDelay: Float
        public let maxPeriodicDelay: Float
        public let minPeriodicDuration: Float
        public let maxPeriodicDuration: Float

        /// bit 1: at most one particle per frame, bit 2: emit in random bursts.
        public var oncePerFrame: Bool { flags & 2 != 0 }
        public var isPeriodic: Bool { flags & 4 != 0 }

        init?(json: JSON) {
            switch json["name"].string {
            case "boxrandom": kind = .box
            case "sphererandom": kind = .sphere
            default: return nil
            }
            origin = json["origin"].vec3 ?? .zero
            directions = json["directions"].vec3 ?? SIMD3(repeating: 1)
            distanceMin = WEParticleSystem.spread(json["distancemin"], default: 0)
            distanceMax = WEParticleSystem.spread(json["distancemax"], default: 0)
            sign = json["sign"].vec3 ?? .zero
            rate = json["rate"].float ?? 0
            instantaneous = json["instantaneous"].int ?? 0
            speedMin = json["speedmin"].float ?? 0
            speedMax = json["speedmax"].float ?? 0
            controlPoint = json["controlpoint"].int ?? 0
            flags = json["flags"].int ?? 0
            delay = json["delay"].float ?? 0
            duration = json["duration"].float ?? 0
            minPeriodicDelay = json["minperiodicdelay"].float ?? 1
            maxPeriodicDelay = json["maxperiodicdelay"].float ?? 2
            minPeriodicDuration = json["minperiodicduration"].float ?? 2
            maxPeriodicDuration = json["maxperiodicduration"].float ?? 3
        }
    }

    /// `distancemin`/`distancemax` are a scalar in some wallpapers and a vector in others.
    static func spread(_ json: JSON, default value: Float) -> SIMD3<Float> {
        guard let floats = json.floats, !floats.isEmpty else { return SIMD3(repeating: value) }
        if floats.count == 1 { return SIMD3(repeating: floats[0]) }
        return SIMD3(floats[0], floats.count > 1 ? floats[1] : 0, floats.count > 2 ? floats[2] : 0)
    }

    // MARK: Initializer

    public enum Initializer {
        case lifetime(min: Float, max: Float)
        case size(min: Float, max: Float, exponent: Float)
        case alpha(min: Float, max: Float)
        /// Stored already divided by 255: wallpaper files give colours as 0 to 255 here.
        case color(min: SIMD3<Float>, max: SIMD3<Float>)
        case velocity(min: SIMD3<Float>, max: SIMD3<Float>)
        case rotation(min: SIMD3<Float>, max: SIMD3<Float>)
        case angularVelocity(min: SIMD3<Float>, max: SIMD3<Float>, exponent: SIMD3<Float>)
        case turbulentVelocity(speedMin: Float, speedMax: Float, scale: Float, offset: Float,
                               forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                               timeScale: Float, phaseMin: Float, phaseMax: Float)
        case unsupported(String)

        init(json: JSON) {
            let name = json["name"].string ?? ""
            func scalarMin(_ fallback: Float = 0) -> Float { json["min"].floats?.first ?? fallback }
            func scalarMax(_ fallback: Float = 0) -> Float { json["max"].floats?.first ?? fallback }
            switch name {
            case "lifetimerandom":
                self = .lifetime(min: scalarMin(1), max: scalarMax(1))
            case "sizerandom":
                self = .size(min: scalarMin(20), max: scalarMax(20), exponent: json["exponent"].float ?? 1)
            case "alpharandom":
                self = .alpha(min: scalarMin(1), max: scalarMax(1))
            case "colorrandom":
                let lo = (json["min"].vec3 ?? SIMD3(repeating: 255)) / 255
                let hi = (json["max"].vec3 ?? (json["min"].vec3 ?? SIMD3(repeating: 255))) / 255
                self = .color(min: lo, max: hi)
            case "velocityrandom":
                self = .velocity(min: json["min"].vec3 ?? .zero, max: json["max"].vec3 ?? .zero)
            case "rotationrandom":
                self = .rotation(min: json["min"].vec3 ?? .zero, max: json["max"].vec3 ?? .zero)
            case "angularvelocityrandom":
                self = .angularVelocity(min: json["min"].vec3 ?? .zero, max: json["max"].vec3 ?? .zero,
                                        exponent: WEParticleSystem.spread(json["exponent"], default: 1))
            case "turbulentvelocityrandom":
                self = .turbulentVelocity(speedMin: json["speedmin"].float ?? 0,
                                          speedMax: json["speedmax"].float ?? 0,
                                          scale: json["scale"].float ?? 1,
                                          offset: json["offset"].float ?? 0,
                                          forward: json["forward"].vec3 ?? SIMD3(0, 1, 0),
                                          right: json["right"].vec3 ?? SIMD3(0, 0, 1),
                                          up: json["up"].vec3 ?? SIMD3(1, 0, 0),
                                          timeScale: json["timescale"].float ?? 1,
                                          phaseMin: json["phasemin"].float ?? 0,
                                          phaseMax: json["phasemax"].float ?? 0.1)
            default:
                self = .unsupported(name)
            }
        }
    }

    // MARK: Operator

    public enum Operator {
        case movement(drag: Float, gravity: SIMD3<Float>)
        case angularMovement(drag: Float, force: SIMD3<Float>)
        case alphaFade(fadeIn: Float, fadeOut: Float)
        case alphaChange(start: Float, end: Float, startTime: Float, endTime: Float)
        case sizeChange(start: Float, end: Float, startTime: Float, endTime: Float)
        case colorChange(start: SIMD3<Float>, end: SIMD3<Float>, startTime: Float, endTime: Float)
        case oscillateAlpha(frequencyMin: Float, frequencyMax: Float,
                            scaleMin: Float, scaleMax: Float, phaseMin: Float, phaseMax: Float)
        case oscillateSize(frequencyMin: Float, frequencyMax: Float,
                           scaleMin: Float, scaleMax: Float, phaseMin: Float, phaseMax: Float)
        case oscillatePosition(frequencyMin: SIMD3<Float>, frequencyMax: SIMD3<Float>,
                               scaleMin: SIMD3<Float>, scaleMax: SIMD3<Float>,
                               phaseMin: SIMD3<Float>, phaseMax: SIMD3<Float>, mask: SIMD3<Float>)
        case turbulence(scale: Float, speedMin: Float, speedMax: Float, timeScale: Float,
                        mask: SIMD3<Float>, phaseMin: Float, phaseMax: Float)
        case vortex(controlPoint: Int, axis: SIMD3<Float>, offset: SIMD3<Float>, flags: Int,
                    distanceInner: Float, distanceOuter: Float, speedInner: Float, speedOuter: Float)
        case controlPointAttract(controlPoint: Int, threshold: Float, scale: Float)
        case unsupported(String)

        init(json: JSON) {
            let name = json["name"].string ?? ""
            func f(_ key: String, _ fallback: Float) -> Float { json[key].float ?? fallback }
            func v(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> { json[key].vec3 ?? fallback }
            switch name {
            case "movement":
                self = .movement(drag: f("drag", 0), gravity: v("gravity", .zero))
            case "angularmovement":
                self = .angularMovement(drag: f("drag", 0), force: v("force", .zero))
            case "alphafade":
                self = .alphaFade(fadeIn: f("fadeintime", 0.5), fadeOut: f("fadeouttime", 0.5))
            case "alphachange":
                self = .alphaChange(start: f("startvalue", 1), end: f("endvalue", 0),
                                    startTime: f("starttime", 0), endTime: f("endtime", 1))
            case "sizechange":
                self = .sizeChange(start: f("startvalue", 1), end: f("endvalue", 1),
                                   startTime: f("starttime", 0), endTime: f("endtime", 1))
            case "colorchange":
                self = .colorChange(start: v("startvalue", SIMD3(repeating: 1)),
                                    end: v("endvalue", SIMD3(repeating: 1)),
                                    startTime: f("starttime", 0), endTime: f("endtime", 1))
            case "oscillatealpha":
                self = .oscillateAlpha(frequencyMin: f("frequencymin", 0), frequencyMax: f("frequencymax", 10),
                                       scaleMin: f("scalemin", 0), scaleMax: f("scalemax", 1),
                                       phaseMin: f("phasemin", 0), phaseMax: f("phasemax", 6.283))
            case "oscillatesize":
                self = .oscillateSize(frequencyMin: f("frequencymin", 0), frequencyMax: f("frequencymax", 10),
                                      scaleMin: f("scalemin", 0), scaleMax: f("scalemax", 1),
                                      phaseMin: f("phasemin", 0), phaseMax: f("phasemax", 6.283))
            case "oscillateposition":
                self = .oscillatePosition(frequencyMin: WEParticleSystem.spread(json["frequencymin"], default: 0),
                                          frequencyMax: WEParticleSystem.spread(json["frequencymax"], default: 10),
                                          scaleMin: WEParticleSystem.spread(json["scalemin"], default: 0),
                                          scaleMax: WEParticleSystem.spread(json["scalemax"], default: 1),
                                          phaseMin: WEParticleSystem.spread(json["phasemin"], default: 0),
                                          phaseMax: WEParticleSystem.spread(json["phasemax"], default: 6.283),
                                          mask: v("mask", SIMD3(1, 1, 0)))
            case "turbulence":
                self = .turbulence(scale: f("scale", 0.005), speedMin: f("speedmin", 0),
                                   speedMax: f("speedmax", 0), timeScale: f("timescale", 0.01),
                                   mask: v("mask", SIMD3(1, 1, 0)),
                                   phaseMin: f("phasemin", 0), phaseMax: f("phasemax", 0))
            case "vortex", "vortex_v2":
                self = .vortex(controlPoint: json["controlpoint"].int ?? 0,
                               axis: v("axis", SIMD3(0, 0, 1)), offset: v("offset", .zero),
                               flags: json["flags"].int ?? 0,
                               distanceInner: f("distanceinner", 500), distanceOuter: f("distanceouter", 650),
                               speedInner: f("speedinner", 0), speedOuter: f("speedouter", 0))
            case "controlpointattract", "controlpointforce":
                self = .controlPointAttract(controlPoint: json["controlpoint"].int ?? 0,
                                            threshold: f("threshold", 512), scale: f("scale", 512))
            default:
                self = .unsupported(name)
            }
        }
    }

    // MARK: Renderer

    public enum Renderer {
        case sprite
        case spriteTrail(length: Float, maxLength: Float, minLength: Float)
        /// Rope renderers need a different shader and a spline; they fall back to sprites.
        case rope(trail: Bool)

        public var isTrail: Bool {
            if case .spriteTrail = self { return true }
            if case .rope(let trail) = self { return trail }
            return false
        }

        public var isRope: Bool {
            if case .rope = self { return true }
            return false
        }

        init(json: JSON) {
            switch json["name"].string ?? "sprite" {
            case "spritetrail":
                self = .spriteTrail(length: json["length"].float ?? 0.05,
                                    maxLength: json["maxlength"].float ?? 10,
                                    minLength: json["minlength"].float ?? 0)
            case "rope": self = .rope(trail: false)
            case "ropetrail": self = .rope(trail: true)
            default: self = .sprite
            }
        }
    }

    // MARK: Control points

    public struct ControlPoint {
        public let id: Int
        public let flags: Int
        public let offset: SIMD3<Float>

        /// bit 0: the point follows the cursor, bit 1: it is in world space.
        public var followsCursor: Bool { flags & 1 != 0 }
        public var isWorldSpace: Bool { flags & 2 != 0 }

        init(json: JSON) {
            id = json["id"].int ?? 0
            flags = json["flags"].int ?? 0
            offset = json["offset"].vec3 ?? .zero
        }
    }

    /// `instanceoverride` on the scene object, which scales a shared particle definition.
    public struct InstanceOverride {
        public var alpha: Float = 1
        public var size: Float = 1
        public var lifetime: Float = 1
        public var rate: Float = 1
        public var speed: Float = 1
        public var count: Float = 1
        public var color: SIMD3<Float>?      // replaces the particle colour outright
        public var colorMultiplier: SIMD3<Float>?

        public init(json: JSON) {
            guard json.exists, json["enabled"].bool ?? true else { return }
            alpha = json["alpha"].float ?? 1
            size = json["size"].float ?? 1
            lifetime = json["lifetime"].float ?? 1
            rate = json["rate"].float ?? 1
            speed = json["speed"].float ?? 1
            count = json["count"].float ?? 1
            if let c = json["color"].vec3 { color = c / 255 }
            if let c = json["colorn"].vec3 { colorMultiplier = c }
        }
    }
}
