import Foundation
import JavaScriptCore

/// An opaque token for one compiled scripted value.
///
/// The engine owns every piece of JavaScript state, callers only keep the
/// token, so a handle stays valid for the lifetime of its `ScriptEngine` and
/// carries nothing a caller could corrupt.
public struct ScriptHandle: Equatable {
    fileprivate let id: Int
    fileprivate init(id: Int) { self.id = id }
}

/// One JavaScript context per wallpaper, hosting every scripted value in it.
///
/// Wallpaper Engine lets any scene value be driven by a small JavaScript
/// module ("SceneScript"): `{"script": "…", "value": <fallback>}`. All the
/// scripts of one wallpaper share a context, because they also share `shared`,
/// `localStorage` and the layer objects they reach through
/// `thisScene.getLayer(name)`, so a context per script would break scripts that
/// talk to each other.
///
/// Scripts are third-party input and are treated as hostile: nothing they do
/// throws out of this class, every failure lands in `diagnostics`, and a script
/// that keeps throwing is switched off instead of costing a frame forever.
///
/// Not thread safe, a `JSContext` must be driven from one thread. Call
/// `beginFrame` and `evaluate` from the same thread that created the engine
/// (in Mirage, the render thread).
public final class ScriptEngine {

    // MARK: Limits
    //
    // Every one of these bounds a resource a wallpaper file controls.

    private static let maximumDiagnostics = 256
    private static let maximumScriptByteCount = 1 << 20
    private static let maximumScriptLineCount = 20_000
    private static let maximumRegisteredScripts = 1024
    private static let maximumFailuresPerScript = 5
    private static let maximumTimers = 256
    private static let maximumTimerFiringsPerFrame = 64
    private static let maximumStringLength = 1 << 15
    private static let maximumArrayCount = 1024
    private static let maximumStorageEntries = 256
    private static let maximumStorageValueLength = 1 << 16

    /// Scene properties whose values are vectors. A script driving one of these
    /// expects a `Vec2`/`Vec3` (it writes `thisLayer.origin.x`), and returns one,
    /// while WE stores them as `"x y z"` strings, so both directions convert.
    private static let vectorProperties: Set<String> = [
        "origin", "scale", "angles", "color", "offset", "size", "position",
        "direction", "translation", "rotation", "velocity", "point", "parallaxdepth",
    ]

    /// Names bound by the wrapper closure. A script that re-declares one of
    /// these with `let`/`const` is a syntax error, so those become `var`.
    private static let closureParameterNames: Set<String> = [
        "exports", "thisLayer", "thisObject", "thisScene", "engine", "input", "scriptProperties",
    ]

    // MARK: State

    /// Everything that went wrong, in order. Diagnostics are collected instead
    /// of printed so the caller can surface them next to the renderer's own.
    public private(set) var diagnostics: [String] = []

    /// Scene size in pixels, used for `engine.canvasSize` and to turn the
    /// normalised cursor into `input.cursorScreenPosition` /
    /// `cursorWorldPosition`. Set it from the scene's orthogonal projection
    /// before the first frame.
    public var canvasSize: SIMD2<Float> = SIMD2(1920, 1080)

    private let virtualMachine: JSVirtualMachine?
    private let context: JSContext
    private let workshopId: String?
    private let storageKey: String

    private var records: [Int: ScriptRecord] = [:]
    private var nextHandleId = 1
    private var transformCache: [String: String] = [:]

    private var engineObject: JSValue?
    private var inputObject: JSValue?

    private var timers: [FrameTimer] = []
    private var nextTimerId = 1
    private var runtime: Double = 0

    private var storage: [String: String]
    private var propertyStore: PropertyStore?
    private var userProperties: [String: Any] = [:]

    /// Set by the exception handler, read right after every call into JS.
    private var exceptionSeen = false
    private var activeLabel: String?
    private var diagnosticsTruncated = false
    private var timerLimitReported = false

    // MARK: Init

    public init(workshopId: String?) {
        self.workshopId = workshopId
        self.storageKey = "scripts.localStorage." + (ScriptEngine.sanitizedIdentifier(workshopId) ?? "default")
        let machine: JSVirtualMachine? = JSVirtualMachine()
        self.virtualMachine = machine
        self.context = (machine.flatMap { JSContext(virtualMachine: $0) } ?? JSContext()) ?? JSContext()
        self.storage = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]

        installExceptionHandler()
        installNativeBridge()
        installRuntime(source: ScriptEngine.preludeSource, name: "mirage-runtime")
        engineObject = context.objectForKeyedSubscript("engine")
        inputObject = context.objectForKeyedSubscript("input")
    }

    /// Evaluate extra JavaScript into the shared context, before any script is
    /// registered. Mirage's built-in runtime already covers `Vec2`/`Vec3`/`Vec4`
    /// and the `WEMath` / `WEVector` / `WEColor` helpers, but Wallpaper Engine's
    /// own `assets/scripts/jsclasses/baseclasses.js` can be layered on top when
    /// the assets folder is present: it declares the same names and shadows
    /// these fallbacks.
    @discardableResult
    public func installRuntime(source: String, name: String) -> Bool {
        guard !source.isEmpty else { return false }
        exceptionSeen = false
        activeLabel = name
        context.evaluateScript(source, withSourceURL: ScriptEngine.sourceURL(name))
        activeLabel = nil
        if exceptionSeen {
            record("runtime '\(name)' failed to evaluate")
            return false
        }
        return true
    }

    /// Hands the wallpaper's user properties to the engine. They do two jobs:
    /// scripts read them as `engine.userProperties`, and a script property may
    /// itself be a `{"user": …}` binding that resolves through the store.
    ///
    /// Call it before registering anything, and again whenever a property
    /// changes, because nothing here observes the store.
    public func setUserProperties(_ store: PropertyStore?) {
        propertyStore = store
        var plain: [String: Any] = [:]
        for (key, value) in store?.values ?? [:] { plain[key] = value.anyValue }
        userProperties = plain
        engineObject?.setObject(plain, forKeyedSubscript: "userProperties" as NSString)
    }

    /// Delivers the user properties to every script that wants them.
    ///
    /// Wallpaper Engine calls `applyUserProperties` once at load, after `init`,
    /// and again whenever a property changes. Scripts lean on it heavily: real
    /// ones compute their layout there and leave `init` to look up layers, so a
    /// script that never receives it runs `update` against undefined state and
    /// throws on the first frame.
    public func applyUserProperties() {
        for (_, record) in records { deliverUserProperties(to: record) }
    }

    /// Tells a media-aware script that nothing is playing.
    ///
    /// Mirage has no media integration, and a wallpaper that is never told
    /// anything sits in whatever state its author left in the editor, which is
    /// usually a placeholder song. Saying "stopped" is both the truth and what
    /// Wallpaper Engine sends when no player is running, so those wallpapers
    /// fall back to their idle layout (a clock, usually).
    private func deliverMediaState(to record: ScriptRecord) {
        guard let function = record.mediaPlaybackFunction else { return }
        record.didDeliverMediaState = true
        guard let event = JSValue(object: ["state": 0], in: context), event.isObject else { return }
        _ = call(function, arguments: [event], record: record, phase: "mediaPlaybackChanged")
    }

    private func deliverUserProperties(to record: ScriptRecord) {
        guard let function = record.applyPropertiesFunction else { return }
        record.didApplyUserProperties = true
        guard let properties = JSValue(object: userProperties, in: context), properties.isObject else { return }
        _ = call(function, arguments: [properties], record: record, phase: "applyUserProperties")
    }

    /// Evaluates one of Wallpaper Engine's own ES modules
    /// (`assets/scripts/jsmodules/*.js`) and binds its exports to a global.
    ///
    /// Scripts reach these through `import * as WEMath from 'WEMath'`, and the
    /// import line is stripped on the way in, so the module has to arrive as a
    /// global of that name. The module body goes through the same rewrite the
    /// scripts do, which is what turns its `export`s into an object.
    @discardableResult
    public func installModule(source: String, name: String, global: String) -> Bool {
        guard !source.isEmpty, ScriptEngine.isIdentifier(global) else { return false }
        guard let body = ScriptEngine.moduleBody(from: source) else {
            record("module '\(name)' could not be rewritten")
            return false
        }
        let wrapped = "globalThis[\"\(global)\"] = (function () {\n  var exports = {};\n"
            + body + "\n  return exports;\n})();"
        exceptionSeen = false
        activeLabel = name
        context.evaluateScript(wrapped, withSourceURL: ScriptEngine.sourceURL(name))
        activeLabel = nil
        if exceptionSeen {
            record("module '\(name)' failed to evaluate")
            return false
        }
        return true
    }

    // MARK: Frame

    /// Per-frame globals the scripts read.
    ///
    /// `time` and `frameTime` are seconds, `dayTime` is the WE convention
    /// `(hour * 60 + minute) / 1440`, and `cursor` is normalised with x right
    /// and y down, matching `g_PointerPosition`.
    public func beginFrame(time: Double, frameTime: Double, dayTime: Double, cursor: SIMD2<Float>) {
        if time.isFinite { runtime = max(0, time) }
        // A frame time of many seconds (a resumed wallpaper) would make every
        // timer fire at once and every script integrate a huge step.
        let delta = frameTime.isFinite ? min(max(frameTime, 0), 1) : 0
        let day = dayTime.isFinite ? min(max(dayTime, 0), 1) : 0

        let width = canvasSize.x.isFinite && canvasSize.x > 0 ? Double(canvasSize.x) : 1920
        let height = canvasSize.y.isFinite && canvasSize.y > 0 ? Double(canvasSize.y) : 1080
        let cursorX = cursor.x.isFinite ? Double(cursor.x) : 0
        let cursorY = cursor.y.isFinite ? Double(cursor.y) : 0

        if let engineObject {
            engineObject.setObject(runtime, forKeyedSubscript: "runtime" as NSString)
            engineObject.setObject(delta, forKeyedSubscript: "frametime" as NSString)
            engineObject.setObject(day, forKeyedSubscript: "timeOfDay" as NSString)
            if let size = makeVector([width, height]) {
                engineObject.setObject(size, forKeyedSubscript: "canvasSize" as NSString)
            }
        }
        if let inputObject {
            if let normalised = makeVector([cursorX, cursorY]) {
                inputObject.setObject(normalised, forKeyedSubscript: "cursorPosition" as NSString)
            }
            if let screen = makeVector([cursorX * width, cursorY * height]) {
                inputObject.setObject(screen, forKeyedSubscript: "cursorScreenPosition" as NSString)
            }
            // Scene space is pixels with the origin at the centre and y up, so
            // the cursor's y is mirrored on the way in.
            if let world = makeVector([(cursorX - 0.5) * width, (0.5 - cursorY) * height, 0]) {
                inputObject.setObject(world, forKeyedSubscript: "cursorWorldPosition" as NSString)
            }
        }

        fireDueTimers()
    }

    // MARK: Registration

    /// Compiles one scripted value and returns a handle. `objectName` is used
    /// for diagnostics. Returns nil when the script cannot be compiled.
    public func register(script: String, scriptProperties: JSON,
                         object objectName: String, property propertyName: String) -> ScriptHandle? {
        let label = "\(objectName).\(propertyName)"
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard script.utf8.count <= ScriptEngine.maximumScriptByteCount else {
            record("\(label): script is too large (\(script.utf8.count) bytes)")
            return nil
        }
        guard records.count < ScriptEngine.maximumRegisteredScripts else {
            record("\(label): too many scripts in one wallpaper, ignored")
            return nil
        }

        let body: String
        if let cached = transformCache[script] {
            body = cached
        } else if let transformed = ScriptEngine.moduleBody(from: script) {
            transformCache[script] = transformed
            body = transformed
        } else {
            record("\(label): script could not be rewritten into a module")
            return nil
        }

        // The whole script becomes a closure so that two scripts declaring the
        // same top-level name cannot collide in the global object.
        let wrapped = "(function (exports, thisLayer, thisObject, thisScene, engine, input, scriptProperties) {\n"
            + body + "\n})"

        exceptionSeen = false
        activeLabel = label
        let factory = context.evaluateScript(wrapped, withSourceURL: ScriptEngine.sourceURL(label))
        activeLabel = nil
        guard !exceptionSeen, let factory, !factory.isUndefined, !factory.isNull else {
            record("\(label): script failed to compile")
            return nil
        }

        guard let exports = JSValue(newObjectIn: context),
              let layer = layerObject(named: objectName),
              let scene = context.objectForKeyedSubscript("thisScene"),
              let engineObject, let inputObject else {
            record("\(label): the script context is unavailable")
            return nil
        }

        let properties = propertiesObject(from: scriptProperties)
        // `createScriptProperties()` needs the stored values of the script that
        // is being set up right now, and the closure signature has no room for
        // them, so they travel through a global that is set around each call.
        context.setObject(properties, forKeyedSubscript: "__weScriptProperties" as NSString)

        exceptionSeen = false
        activeLabel = label
        factory.call(withArguments: [exports, layer, layer, scene, engineObject, inputObject, properties])
        activeLabel = nil
        if exceptionSeen {
            record("\(label): script threw while loading")
            return nil
        }

        let entry = ScriptRecord(objectName: objectName,
                                 propertyName: propertyName,
                                 isVectorValued: ScriptEngine.vectorProperties.contains(propertyName.lowercased()),
                                 exports: exports,
                                 layer: layer,
                                 properties: properties)
        entry.initFunction = callable(exports.objectForKeyedSubscript("init"))
        entry.updateFunction = callable(exports.objectForKeyedSubscript("update"))
        entry.applyPropertiesFunction = callable(exports.objectForKeyedSubscript("applyUserProperties"))
        entry.mediaPlaybackFunction = callable(exports.objectForKeyedSubscript("mediaPlaybackChanged"))
        if entry.updateFunction == nil && entry.initFunction == nil {
            // Cursor-driven and media-driven scripts have neither; they cannot
            // produce a value here, but they are not an error either.
            entry.disabled = true
        }

        let id = nextHandleId
        nextHandleId += 1
        records[id] = entry
        return ScriptHandle(id: id)
    }

    /// Gives a scene object's JavaScript twin its real values.
    ///
    /// Scripts read the layer they drive and the layers around it
    /// (`thisScene.getLayer("Album Cover").origin`), so a layer object holding
    /// only the one property its script drives makes those reads `undefined`
    /// and the script throws on the first frame. Seed before registering, so
    /// `init()` sees the same scene the renderer does.
    public func seedLayer(named name: String, values: [String: JSON]) {
        guard let layer = layerObject(named: name) else { return }
        for (key, value) in values where !value.isNull {
            let isVector = ScriptEngine.vectorProperties.contains(key.lowercased())
            layer.setObject(jsValue(for: value, isVector: isVector), forKeyedSubscript: key as NSString)
        }
    }

    // MARK: Evaluation

    /// Runs `update(value)` and returns its result, or nil when the script did
    /// not return anything usable this frame. Never throws; failures are recorded.
    ///
    /// Roughly half of the clock scripts in the wild return nothing and assign
    /// `thisLayer.text` instead, so the layer object is read back as well.
    public func evaluate(_ handle: ScriptHandle, current: JSON) -> JSON? {
        guard let record = records[handle.id], !record.disabled else { return nil }

        // Re-seed the layer only when the caller's value actually changed,
        // otherwise a script that writes `thisLayer.text` once and then leaves
        // it alone would be overwritten with the stored default every frame.
        if record.lastCurrent != current {
            record.lastCurrent = current
            record.layer.setObject(jsValue(for: current, isVector: record.isVectorValued),
                                   forKeyedSubscript: record.propertyName as NSString)
        }
        context.setObject(record.properties, forKeyedSubscript: "__weScriptProperties" as NSString)

        guard var seed = record.layer.objectForKeyedSubscript(record.propertyName)
            ?? JSValue(undefinedIn: context) else { return nil }
        if !record.didRunInit {
            record.didRunInit = true
            if let function = record.initFunction {
                if let result = call(function, arguments: [seed], record: record, phase: "init"),
                   !result.isUndefined, !result.isNull {
                    seed = result
                    record.layer.setObject(result, forKeyedSubscript: record.propertyName as NSString)
                }
            }
        }
        // WE's order is init, then the properties, then the first update.
        if !record.didApplyUserProperties { deliverUserProperties(to: record) }
        if !record.didDeliverMediaState { deliverMediaState(to: record) }

        if let update = record.updateFunction {
            let result = call(update, arguments: [seed], record: record, phase: "update")
            if let value = json(from: result) {
                record.layer.setObject(result, forKeyedSubscript: record.propertyName as NSString)
                return coerce(value, for: record.propertyName)
            }
        }

        // No usable return value: fall back to whatever the script left on the
        // layer, but only when it differs from the value the caller passed in.
        let after = record.layer.objectForKeyedSubscript(record.propertyName)
        if let value = json(from: after), value != current {
            return coerce(value, for: record.propertyName)
        }
        return nil
    }

    /// Reads one property back off the script's layer object, for callers that
    /// want the side effects (`thisLayer.visible`, `thisLayer.alpha`) as well as
    /// the driven value. Returns nil when the script never set it.
    public func layerProperty(_ handle: ScriptHandle, named name: String) -> JSON? {
        guard let record = records[handle.id] else { return nil }
        return json(from: record.layer.objectForKeyedSubscript(name))
    }

    // MARK: Calling into JavaScript

    private func call(_ function: JSValue, arguments: [Any], record: ScriptRecord, phase: String) -> JSValue? {
        exceptionSeen = false
        activeLabel = "\(record.objectName).\(record.propertyName)"
        let result = function.call(withArguments: arguments)
        activeLabel = nil
        if exceptionSeen {
            noteFailure(record, phase: phase)
            return nil
        }
        return result
    }

    /// A script that keeps throwing costs a JS call and a diagnostic every
    /// frame forever, so it is switched off after a few failures.
    private func noteFailure(_ record: ScriptRecord, phase: String) {
        record.failureCount += 1
        guard record.failureCount >= ScriptEngine.maximumFailuresPerScript, !record.disabled else { return }
        record.disabled = true
        self.record("\(record.objectName).\(record.propertyName): disabled after \(record.failureCount) errors in \(phase)()")
    }

    private func callable(_ value: JSValue?) -> JSValue? {
        guard let value, !value.isUndefined, !value.isNull, value.isObject else { return nil }
        // JSValue has no isFunction, but every function has a callable `call`.
        guard let call = value.objectForKeyedSubscript("call"), call.isObject else { return nil }
        return value
    }

    // MARK: Timers

    /// Timers run off the frame clock rather than dispatch queues, so pausing
    /// the wallpaper (no `beginFrame`) pauses them, exactly like WE.
    private struct FrameTimer {
        let id: Int
        var due: Double
        let interval: Double?
        let callback: JSValue
    }

    private func addTimer(callback: JSValue?, milliseconds: Double, repeats: Bool) -> Double {
        guard let callback, !callback.isUndefined, !callback.isNull, callback.isObject else { return 0 }
        guard timers.count < ScriptEngine.maximumTimers else {
            if !timerLimitReported {
                timerLimitReported = true
                record("timer limit of \(ScriptEngine.maximumTimers) reached, further timers ignored")
            }
            return 0
        }
        let seconds = milliseconds.isFinite ? min(max(milliseconds, 0), 24 * 60 * 60 * 1000) / 1000 : 0
        let id = nextTimerId
        nextTimerId += 1
        timers.append(FrameTimer(id: id, due: runtime + seconds, interval: repeats ? seconds : nil, callback: callback))
        return Double(id)
    }

    private func removeTimer(id: Double) {
        guard id.isFinite, let value = Int(exactly: id.rounded()) else { return }
        timers.removeAll { $0.id == value }
    }

    private func fireDueTimers() {
        var firings = 0
        while firings < ScriptEngine.maximumTimerFiringsPerFrame {
            guard let index = timers.firstIndex(where: { $0.due <= runtime }) else { return }
            let timer = timers[index]
            firings += 1
            if let interval = timer.interval {
                // A zero interval would fire until the per-frame cap; push it to
                // the next frame instead.
                timers[index].due = runtime + max(interval, 0.001)
            } else {
                timers.remove(at: index)
            }

            exceptionSeen = false
            activeLabel = "timer \(timer.id)"
            timer.callback.call(withArguments: [])
            activeLabel = nil
            if exceptionSeen {
                record("timer \(timer.id) threw, cancelled")
                timers.removeAll { $0.id == timer.id }
            }
        }
        record("more than \(ScriptEngine.maximumTimerFiringsPerFrame) timer callbacks in one frame, the rest wait")
    }

    // MARK: Value conversion

    private func jsValue(for json: JSON, isVector: Bool) -> Any {
        if isVector, let components = ScriptEngine.doubleComponents(json),
           components.count >= 2, components.count <= 4,
           let vector = makeVector(components) {
            return vector
        }
        return json.anyValue
    }

    /// Like `JSON.floats` but without the trip through `Float`, which would turn
    /// a stored `1.46` into `1.4600000381469727` on the way back out.
    private static func doubleComponents(_ json: JSON) -> [Double]? {
        switch json {
        case .number(let value): return value.isFinite ? [value] : nil
        case .string(let text):
            let parts = text.split(maxSplits: 8, whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
            guard parts.count <= 8 else { return nil }
            let values = parts.compactMap { Double($0) }.filter { $0.isFinite }
            return values.isEmpty ? nil : values
        case .array(let items):
            guard items.count <= 8 else { return nil }
            let values = items.compactMap { $0.double }.filter { $0.isFinite }
            return values.isEmpty ? nil : values
        default: return nil
        }
    }

    private func makeVector(_ components: [Double]) -> JSValue? {
        guard components.allSatisfy({ $0.isFinite }), (2...4).contains(components.count) else { return nil }
        guard let maker = context.objectForKeyedSubscript("__weVec"), maker.isObject else { return nil }
        let result = maker.call(withArguments: components.map { $0 as Any })
        guard let result, result.isObject else { return nil }
        return result
    }

    private func json(from value: JSValue?) -> JSON? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isBoolean { return .bool(value.toBool()) }
        if value.isNumber {
            let number = value.toDouble()
            return number.isFinite ? .number(number) : nil
        }
        if value.isString {
            guard let text = value.toString() else { return nil }
            return .string(String(text.prefix(ScriptEngine.maximumStringLength)))
        }
        if value.isArray {
            guard let items = value.toArray(), items.count <= ScriptEngine.maximumArrayCount else { return nil }
            return JSON(any: items)
        }
        if value.isObject { return vectorJSON(from: value) }
        return nil
    }

    /// A `Vec2`/`Vec3`/`Vec4` (or anything shaped like one) comes back as WE's
    /// `"x y z"` string, which is what every scene value expects.
    private func vectorJSON(from value: JSValue) -> JSON? {
        guard let x = value.objectForKeyedSubscript("x"), x.isNumber,
              let y = value.objectForKeyedSubscript("y"), y.isNumber else { return nil }
        var components = [x.toDouble(), y.toDouble()]
        if let z = value.objectForKeyedSubscript("z"), z.isNumber {
            components.append(z.toDouble())
            if let w = value.objectForKeyedSubscript("w"), w.isNumber { components.append(w.toDouble()) }
        }
        guard components.allSatisfy({ $0.isFinite }) else { return nil }
        return .string(components.map { JSON.numberString($0) }.joined(separator: " "))
    }

    /// Text layers need a string; scripts happily return a number for one.
    private func coerce(_ value: JSON, for propertyName: String) -> JSON {
        guard propertyName.lowercased() == "text", value.string == nil else { return value }
        switch value {
        case .number(let n): return .string(JSON.numberString(n))
        case .bool(let b): return .string(b ? "true" : "false")
        default: return value
        }
    }

    /// A stored script property is often a binding rather than a literal
    /// (`{"user": "newproperty", "value": "{day}, {month}"}`), and a script that
    /// gets the binding object where it expected a string throws on the first
    /// call, so every member is resolved the way any other scene value is.
    private func propertiesObject(from json: JSON) -> JSValue {
        if case .object(let members) = json {
            var plain: [String: Any] = [:]
            for (key, value) in members {
                plain[key] = DynamicValue.parse(value).resolve(propertyStore).anyValue
            }
            if let value = JSValue(object: plain, in: context), value.isObject { return value }
        }
        return JSValue(newObjectIn: context) ?? JSValue(undefinedIn: context)
    }

    /// Every script on the same scene object shares one layer object, and
    /// `thisScene.getLayer(name)` hands out the same instances, because scripts
    /// routinely read another layer's origin to position themselves.
    private func layerObject(named name: String) -> JSValue? {
        guard let getter = context.objectForKeyedSubscript("__weGetLayer"), getter.isObject else { return nil }
        exceptionSeen = false
        let layer = getter.call(withArguments: [name])
        guard !exceptionSeen, let layer, layer.isObject else { return nil }
        return layer
    }

    // MARK: Diagnostics

    private func record(_ message: String) {
        // A script that throws every frame would otherwise fill the log with
        // one message before it is disabled.
        if diagnostics.last == message { return }
        guard diagnostics.count < ScriptEngine.maximumDiagnostics else {
            if !diagnosticsTruncated {
                diagnosticsTruncated = true
                diagnostics.append("script diagnostics truncated at \(ScriptEngine.maximumDiagnostics) entries")
            }
            return
        }
        diagnostics.append(message)
    }

    private func installExceptionHandler() {
        context.exceptionHandler = { [weak self] _, exception in
            guard let self else { return }
            self.exceptionSeen = true
            let location = self.activeLabel ?? "script"
            guard let exception else {
                self.record("\(location): unknown JavaScript error")
                return
            }
            let text = exception.toString() ?? "unknown JavaScript error"
            let line = exception.objectForKeyedSubscript("line")
            if let line, line.isNumber, line.toDouble().isFinite {
                self.record("\(location): \(text) (line \(JSON.numberString(line.toDouble())))")
            } else {
                self.record("\(location): \(text)")
            }
        }
    }

    // MARK: Native bridge
    //
    // Blocks capture self weakly: the context retains them and this class
    // retains the context.

    private func installNativeBridge() {
        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            guard let self else { return }
            let text = String(message.prefix(ScriptEngine.maximumStringLength))
            self.record("console.\(level) [\(self.activeLabel ?? "script")]: \(text)")
        }
        context.setObject(log, forKeyedSubscript: "__weLog" as NSString)

        let setTimer: @convention(block) (JSValue?, Double, Bool) -> Double = { [weak self] callback, ms, repeats in
            self?.addTimer(callback: callback, milliseconds: ms, repeats: repeats) ?? 0
        }
        context.setObject(setTimer, forKeyedSubscript: "__weSetTimer" as NSString)

        let clearTimer: @convention(block) (Double) -> Void = { [weak self] id in
            self?.removeTimer(id: id)
        }
        context.setObject(clearTimer, forKeyedSubscript: "__weClearTimer" as NSString)

        let storageGet: @convention(block) (String) -> String? = { [weak self] key in
            self?.storage[key]
        }
        context.setObject(storageGet, forKeyedSubscript: "__weStorageGet" as NSString)

        let storageSet: @convention(block) (String, String) -> Void = { [weak self] key, value in
            self?.setStorage(key: key, value: value)
        }
        context.setObject(storageSet, forKeyedSubscript: "__weStorageSet" as NSString)

        let storageRemove: @convention(block) (String) -> Void = { [weak self] key in
            guard let self else { return }
            self.storage.removeValue(forKey: key)
            self.persistStorage()
        }
        context.setObject(storageRemove, forKeyedSubscript: "__weStorageRemove" as NSString)

        let storageClear: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            self.storage.removeAll()
            self.persistStorage()
        }
        context.setObject(storageClear, forKeyedSubscript: "__weStorageClear" as NSString)
    }

    private func setStorage(key: String, value: String) {
        guard !key.isEmpty, key.count <= 256 else { return }
        guard storage[key] != nil || storage.count < ScriptEngine.maximumStorageEntries else {
            record("localStorage is full at \(ScriptEngine.maximumStorageEntries) keys, '\(key)' dropped")
            return
        }
        storage[key] = String(value.prefix(ScriptEngine.maximumStorageValueLength))
        persistStorage()
    }

    private func persistStorage() {
        UserDefaults.standard.set(storage, forKey: storageKey)
    }

    private static func sanitizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return allowed.isEmpty ? nil : String(allowed.prefix(64))
    }

    private static func sourceURL(_ label: String) -> URL? {
        let escaped = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "script"
        return URL(string: "mirage-script://" + escaped)
    }

    // MARK: Per-script state

    private final class ScriptRecord {
        let objectName: String
        let propertyName: String
        let isVectorValued: Bool
        let exports: JSValue
        let layer: JSValue
        let properties: JSValue

        var initFunction: JSValue?
        var updateFunction: JSValue?
        var applyPropertiesFunction: JSValue?
        var mediaPlaybackFunction: JSValue?
        var didRunInit = false
        var didApplyUserProperties = false
        var didDeliverMediaState = false
        var failureCount = 0
        var disabled = false
        var lastCurrent: JSON?

        init(objectName: String, propertyName: String, isVectorValued: Bool,
             exports: JSValue, layer: JSValue, properties: JSValue) {
            self.objectName = objectName
            self.propertyName = propertyName
            self.isVectorValued = isVectorValued
            self.exports = exports
            self.layer = layer
            self.properties = properties
        }
    }
}

// MARK: - Module rewriting

extension ScriptEngine {

    /// Turns a SceneScript module into a function body.
    ///
    /// The transformation is deliberately line based rather than a real parser:
    /// WE's own editor writes these modules, so the `import` / `export` forms in
    /// the wild all sit at the start of their own line, and anything unusual is
    /// left alone rather than mangled. Dropped lines become empty ones so the
    /// line numbers in a JavaScript error still point at the original file.
    ///
    /// Exports are collected and assigned at the end instead of in place: a
    /// rewrite of `export function checkTime` into `exports.checkTime =
    /// function checkTime` would take the name out of scope for the other
    /// functions in the script, and real clock scripts call each other.
    static func moduleBody(from source: String) -> String? {
        guard !source.isEmpty else { return nil }
        var lines = source.components(separatedBy: .newlines)
        guard lines.count <= maximumScriptLineCount else { return nil }

        var exported: [(local: String, exported: String)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isUseStrictDirective(trimmed) {
                lines[index] = ""
                index += 1
                continue
            }
            if isImportStatement(trimmed) {
                // A multi-line import list ends on the line that closes it.
                var end = index
                var scanned = 0
                while end < lines.count, scanned < 32,
                      !lines[end].contains(";"), !lines[end].contains("from") {
                    end += 1
                    scanned += 1
                }
                for i in index...min(end, lines.count - 1) { lines[i] = "" }
                index = min(end, lines.count - 1) + 1
                continue
            }
            if startsWithExportKeyword(trimmed) {
                lines[index] = rewriteExport(line, collecting: &exported)
            }
            index += 1
        }

        var body = lines.joined(separator: "\n")
        body += "\n;\n"
        for entry in exported where isIdentifier(entry.local) && isIdentifier(entry.exported) {
            body += "try { exports[\"\(entry.exported)\"] = \(entry.local); } catch (__weError) {}\n"
        }
        // Scripts that never export their entry points still work in WE, so
        // pick up plain declarations too.
        for name in ["update", "init", "applyUserProperties"] {
            body += "try { if (typeof \(name) === 'function' && typeof exports.\(name) !== 'function') "
                + "{ exports.\(name) = \(name); } } catch (__weError) {}\n"
        }
        return body
    }

    private static func isUseStrictDirective(_ trimmed: String) -> Bool {
        var text = trimmed
        while text.hasSuffix(";") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text == "'use strict'" || text == "\"use strict\""
    }

    private static func isImportStatement(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("import") else { return false }
        let rest = trimmed.dropFirst("import".count)
        guard let next = rest.first else { return false }
        // `importantThing = 1` is not an import.
        return next == " " || next == "\t" || next == "{" || next == "*" || next == "(" || next == "'" || next == "\""
    }

    private static func startsWithExportKeyword(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("export") else { return false }
        let rest = trimmed.dropFirst("export".count)
        guard let next = rest.first else { return false }
        return next == " " || next == "\t" || next == "{" || next == "*"
    }

    private static func rewriteExport(_ line: String, collecting exported: inout [(local: String, exported: String)]) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        var rest = Substring(line.trimmingCharacters(in: .whitespaces)).dropFirst("export".count)
            .drop { $0 == " " || $0 == "\t" }

        if rest.hasPrefix("*") { return indent }  // `export * from '…'`, nothing to bind.

        if rest.hasPrefix("{") {
            guard let close = rest.firstIndex(of: "}") else { return indent }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            for item in inner.split(separator: ",") {
                let parts = item.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if parts.count >= 3, parts[1] == "as" {
                    exported.append((local: parts[0], exported: parts[2]))
                } else if let name = parts.first {
                    exported.append((local: name, exported: name))
                }
            }
            return indent
        }

        if rest.hasPrefix("default") {
            rest = rest.dropFirst("default".count).drop { $0 == " " || $0 == "\t" }
            if rest.hasPrefix("function") || rest.hasPrefix("class") || rest.hasPrefix("async") {
                return indent + String(rest)
            }
            return indent + "exports.default = " + String(rest)
        }

        var declaration = String(rest)
        if declaration.hasPrefix("async ") {
            declaration = String(declaration.dropFirst("async ".count))
            if let name = declaredName(after: "function", in: declaration) {
                exported.append((local: name, exported: name))
            }
            return indent + "async " + declaration
        }
        for keyword in ["function", "class"] where declaration.hasPrefix(keyword) {
            if let name = declaredName(after: keyword, in: declaration) {
                exported.append((local: name, exported: name))
            }
            return indent + declaration
        }
        for keyword in ["var", "let", "const"] where hasKeyword(keyword, declaration) {
            let declarators = String(declaration.dropFirst(keyword.count).drop { $0 == " " || $0 == "\t" })
            var usesParameterName = false
            for name in declaredNames(in: declarators) {
                exported.append((local: name, exported: name))
                if closureParameterNames.contains(name) { usesParameterName = true }
            }
            // `let scriptProperties = …` would collide with the wrapper's
            // parameter of that name and fail to parse; `var` re-assigns it,
            // which is what the script means anyway.
            let effective = usesParameterName ? "var" : keyword
            return indent + effective + " " + declarators
        }
        // Anything else: drop the keyword and keep the statement.
        return indent + declaration
    }

    private static func hasKeyword(_ keyword: String, _ text: String) -> Bool {
        guard text.hasPrefix(keyword) else { return false }
        let rest = text.dropFirst(keyword.count)
        guard let next = rest.first else { return false }
        return !(next.isLetter || next.isNumber || next == "_" || next == "$")
    }

    private static func declaredName(after keyword: String, in text: String) -> String? {
        guard hasKeyword(keyword, text) else { return nil }
        let rest = text.dropFirst(keyword.count).drop { $0 == " " || $0 == "\t" || $0 == "*" }
        let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })
        return isIdentifier(name) ? name : nil
    }

    /// The leading identifier of each declarator in `a = 1, b = 2`. Destructuring
    /// patterns yield nothing, so they stay unexported rather than mis-parsed.
    private static func declaredNames(in declarators: String) -> [String] {
        var names: [String] = []
        var depth = 0
        var current = ""
        var quote: Character?
        for character in declarators {
            if let active = quote {
                if character == active { quote = nil }
                continue
            }
            switch character {
            case "'", "\"", "`": quote = character
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth = max(0, depth - 1)
            case "," where depth == 0:
                names.append(current)
                current = ""
                continue
            default: break
            }
            if depth == 0 { current.append(character) }
        }
        names.append(current)
        return names.compactMap { chunk in
            let trimmed = chunk.trimmingCharacters(in: .whitespaces)
            let name = String(trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })
            return isIdentifier(name) ? name : nil
        }
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, name.count <= 128 else { return false }
        guard first.isLetter || first == "_" || first == "$" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
    }
}

// MARK: - JavaScript runtime

extension ScriptEngine {

    /// The stand-in for Wallpaper Engine's `baseclasses.js` and its JS modules.
    ///
    /// Written from the documented behaviour rather than copied: the WE assets
    /// folder is licensed content that this project never redistributes, and it
    /// is not always installed. Everything is attached to `globalThis` instead
    /// of declared with `class` / `let`, so evaluating the real `baseclasses.js`
    /// afterwards shadows these without a redeclaration error.
    static let preludeSource = #"""
    function __weNumber(value, fallback) {
        var n = (typeof value === 'number') ? value : parseFloat(value);
        return (typeof n === 'number' && isFinite(n)) ? n : fallback;
    }

    function __weParts(text) {
        return String(text).split(/[\s,]+/).filter(function (part) { return part.length > 0; });
    }

    function __weComponents(count, x, y, z, w) {
        var out = [0, 0, 0, 0];
        if (typeof x === 'string') {
            var parts = __weParts(x);
            for (var i = 0; i < count; i++) { out[i] = __weNumber(parts[i], 0); }
        } else if (x !== null && typeof x === 'object') {
            out[0] = __weNumber(x.x, 0);
            out[1] = __weNumber(x.y, 0);
            out[2] = __weNumber(x.z, 0);
            out[3] = __weNumber(x.w, 0);
        } else if (typeof x !== 'undefined') {
            var value = __weNumber(x, 0);
            out[0] = value;
            out[1] = (typeof y === 'number') ? y : value;
            out[2] = (typeof z === 'number') ? z : ((typeof y === 'number') ? 0 : value);
            out[3] = (typeof w === 'number') ? w : ((typeof y === 'number') ? 0 : value);
        }
        return out;
    }

    function __weInstallVector(constructor, axes) {
        var proto = constructor.prototype;
        var count = axes.length;

        function make(values) {
            var result = Object.create(proto);
            for (var i = 0; i < count; i++) { result[axes[i]] = __weNumber(values[i], 0); }
            return result;
        }
        function parts(self) {
            var out = [];
            for (var i = 0; i < count; i++) { out[i] = __weNumber(self[axes[i]], 0); }
            return out;
        }
        function operand(other, index) {
            if (typeof other === 'number') { return other; }
            if (other !== null && typeof other === 'object') { return __weNumber(other[axes[index]], 0); }
            return __weNumber(other, 0);
        }
        function binary(name, op) {
            proto[name] = function (other) {
                var a = parts(this);
                var out = [];
                for (var i = 0; i < count; i++) { out[i] = op(a[i], operand(other, i)); }
                return make(out);
            };
        }
        function unary(name, op) {
            proto[name] = function () {
                var a = parts(this);
                var out = [];
                for (var i = 0; i < count; i++) { out[i] = op(a[i]); }
                return make(out);
            };
        }

        proto.copy = function () { return make(parts(this)); };
        proto.toArray = function () { return parts(this); };
        proto.toString = function () { return parts(this).join(' '); };
        proto.toConfigString = function () { return parts(this).join(' '); };
        proto.lengthSqr = function () {
            var a = parts(this), total = 0;
            for (var i = 0; i < count; i++) { total += a[i] * a[i]; }
            return total;
        };
        proto.length = function () { return Math.sqrt(this.lengthSqr()); };
        proto.dot = function (other) {
            var a = parts(this), total = 0;
            for (var i = 0; i < count; i++) { total += a[i] * operand(other, i); }
            return total;
        };
        proto.distanceSqr = function (other) { return this.subtract(other).lengthSqr(); };
        proto.distance = function (other) { return this.subtract(other).length(); };
        proto.isFinite = function () {
            var a = parts(this);
            for (var i = 0; i < count; i++) { if (!isFinite(a[i])) { return false; } }
            return true;
        };
        proto.equals = function (other) {
            var a = parts(this);
            for (var i = 0; i < count; i++) { if (Math.abs(a[i] - operand(other, i)) > 0.00001) { return false; } }
            return true;
        };
        proto.normalize = function () {
            var scale = this.length();
            // A zero vector normalises to zero rather than to NaN, so a bad
            // value cannot spread through the rest of the scene.
            return scale > 0 ? this.divide(scale) : make([0, 0, 0, 0]);
        };
        proto.mix = function (other, amount) {
            var t = __weNumber(amount, 0);
            var a = parts(this);
            var out = [];
            for (var i = 0; i < count; i++) { out[i] = a[i] + (operand(other, i) - a[i]) * t; }
            return out.length ? make(out) : this;
        };
        proto.clamp = function (low, high) {
            var a = parts(this);
            var out = [];
            for (var i = 0; i < count; i++) { out[i] = Math.min(Math.max(a[i], operand(low, i)), operand(high, i)); }
            return make(out);
        };

        binary('add', function (a, b) { return a + b; });
        binary('subtract', function (a, b) { return a - b; });
        binary('multiply', function (a, b) { return a * b; });
        binary('divide', function (a, b) { return b === 0 ? 0 : a / b; });
        binary('min', function (a, b) { return Math.min(a, b); });
        binary('max', function (a, b) { return Math.max(a, b); });
        binary('mod', function (a, b) { return b === 0 ? 0 : a - Math.floor(a / b) * b; });
        binary('step', function (a, b) { return b < a ? 0 : 1; });
        unary('negate', function (a) { return -a; });
        unary('abs', Math.abs);
        unary('floor', Math.floor);
        unary('ceil', Math.ceil);
        unary('round', Math.round);
        unary('sign', Math.sign);
        unary('fract', function (a) { return a - Math.floor(a); });

        if (count === 3) {
            proto.cross = function (other) {
                var a = parts(this);
                var b = [operand(other, 0), operand(other, 1), operand(other, 2)];
                return make([
                    a[1] * b[2] - a[2] * b[1],
                    a[2] * b[0] - a[0] * b[2],
                    a[0] * b[1] - a[1] * b[0]
                ]);
            };
        }
    }

    var __weVec2 = function (x, y) {
        var c = __weComponents(2, x, y);
        this.x = c[0];
        this.y = c[1];
    };
    var __weVec3 = function (x, y, z) {
        var c = __weComponents(3, x, y, z);
        this.x = c[0];
        this.y = c[1];
        this.z = c[2];
    };
    var __weVec4 = function (x, y, z, w) {
        var c = __weComponents(4, x, y, z, w);
        this.x = c[0];
        this.y = c[1];
        this.z = c[2];
        this.w = c[3];
    };
    __weInstallVector(__weVec2, ['x', 'y']);
    __weInstallVector(__weVec3, ['x', 'y', 'z']);
    __weInstallVector(__weVec4, ['x', 'y', 'z', 'w']);

    globalThis.Vec2 = __weVec2;
    globalThis.Vec3 = __weVec3;
    globalThis.Vec4 = __weVec4;
    globalThis.deg2rad = Math.PI / 180;
    globalThis.rad2deg = 180 / Math.PI;

    globalThis.__weVec = function (x, y, z, w) {
        if (arguments.length >= 4) { return new globalThis.Vec4(x, y, z, w); }
        if (arguments.length === 3) { return new globalThis.Vec3(x, y, z); }
        return new globalThis.Vec2(x, y);
    };

    globalThis.WEMath = {
        deg2rad: Math.PI / 180,
        rad2deg: 180 / Math.PI,
        smoothStep: function (min, max, v) {
            if (max === min) { return v < min ? 0 : 1; }
            var x = Math.max(0, Math.min(1, (v - min) / (max - min)));
            return x * x * (3 - 2 * x);
        },
        mix: function (a, b, v) { return a + (b - a) * v; },
        clamp: function (v, min, max) { return Math.min(Math.max(v, min), max); },
        saturate: function (v) { return Math.min(Math.max(v, 0), 1); },
        fract: function (v) { return v - Math.floor(v); }
    };

    globalThis.WEVector = {
        angleVector2: function (angle) {
            var radians = __weNumber(angle, 0) * globalThis.WEMath.deg2rad;
            return new globalThis.Vec2(Math.cos(radians), Math.sin(radians));
        },
        vectorAngle2: function (direction) {
            var d = direction || {};
            return Math.atan2(__weNumber(d.y, 0), __weNumber(d.x, 0)) * globalThis.WEMath.rad2deg;
        }
    };

    globalThis.WEColor = {
        rgb2hsv: function (color) {
            var r = __weNumber((color || {}).x, 0);
            var g = __weNumber((color || {}).y, 0);
            var b = __weNumber((color || {}).z, 0);
            var max = Math.max(r, g, b);
            var min = Math.min(r, g, b);
            var d = max - min;
            var h = 0;
            if (d !== 0) {
                if (max === r) { h = ((g - b) / d + (g < b ? 6 : 0)) / 6; }
                else if (max === g) { h = ((b - r) / d + 2) / 6; }
                else { h = ((r - g) / d + 4) / 6; }
            }
            return new globalThis.Vec3(h, max === 0 ? 0 : d / max, max);
        },
        hsv2rgb: function (color) {
            var h = __weNumber((color || {}).x, 0);
            var s = __weNumber((color || {}).y, 0);
            var v = __weNumber((color || {}).z, 0);
            var i = Math.floor(h * 6);
            var f = h * 6 - i;
            var p = v * (1 - s);
            var q = v * (1 - f * s);
            var t = v * (1 - (1 - f) * s);
            var table = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]];
            var rgb = table[((i % 6) + 6) % 6];
            return new globalThis.Vec3(rgb[0], rgb[1], rgb[2]);
        },
        normalizeColor: function (color) {
            var c = color || {};
            return new globalThis.Vec3(__weNumber(c.x, 0) / 255, __weNumber(c.y, 0) / 255, __weNumber(c.z, 0) / 255);
        },
        expandColor: function (color) {
            var c = color || {};
            return new globalThis.Vec3(__weNumber(c.x, 0) * 255, __weNumber(c.y, 0) * 255, __weNumber(c.z, 0) * 255);
        }
    };

    function __weText(value) {
        if (typeof value === 'string') { return value; }
        if (value === null || typeof value === 'undefined') { return String(value); }
        try {
            if (typeof value === 'object') { return JSON.stringify(value); }
        } catch (error) {
            return '[object]';
        }
        return String(value);
    }

    globalThis.console = {
        log: function () { __weLog('log', Array.prototype.map.call(arguments, __weText).join(' ')); },
        info: function () { __weLog('info', Array.prototype.map.call(arguments, __weText).join(' ')); },
        warn: function () { __weLog('warn', Array.prototype.map.call(arguments, __weText).join(' ')); },
        error: function () { __weLog('error', Array.prototype.map.call(arguments, __weText).join(' ')); },
        debug: function () { __weLog('debug', Array.prototype.map.call(arguments, __weText).join(' ')); }
    };

    globalThis.setTimeout = function (callback, delay) { return __weSetTimer(callback, __weNumber(delay, 0), false); };
    globalThis.setInterval = function (callback, delay) { return __weSetTimer(callback, __weNumber(delay, 0), true); };
    globalThis.clearTimeout = function (id) { __weClearTimer(__weNumber(id, -1)); };
    globalThis.clearInterval = globalThis.clearTimeout;
    globalThis.requestAnimationFrame = function (callback) { return __weSetTimer(callback, 0, false); };
    globalThis.cancelAnimationFrame = globalThis.clearTimeout;

    globalThis.localStorage = {
        getItem: function (key) {
            var value = __weStorageGet(String(key));
            return (typeof value === 'undefined' || value === null) ? null : value;
        },
        setItem: function (key, value) { __weStorageSet(String(key), __weText(value)); },
        removeItem: function (key) { __weStorageRemove(String(key)); },
        clear: function () { __weStorageClear(); },
        key: function () { return null; }
    };

    globalThis.shared = globalThis.shared || {};

    globalThis.engine = {
        frametime: 0,
        runtime: 0,
        timeOfDay: 0,
        canvasSize: new globalThis.Vec2(1920, 1080),
        userProperties: {},
        setTimeout: globalThis.setTimeout,
        setInterval: globalThis.setInterval,
        clearTimeout: globalThis.clearTimeout,
        clearInterval: globalThis.clearTimeout,
        registerAudioBuffers: function (resolution) {
            // Mirage has no system audio capture yet, so the buffer stays flat
            // rather than missing: scripts read it without a guard.
            var count = Math.max(1, Math.min(4096, Math.floor(__weNumber(resolution, 16))));
            var zeros = [];
            for (var i = 0; i < count; i++) { zeros.push(0); }
            return {
                average: 0,
                length: count,
                left: zeros.slice(),
                right: zeros.slice(),
                buffer: zeros.slice()
            };
        },
        registerNotification: function () {}
    };

    globalThis.input = {
        cursorPosition: new globalThis.Vec2(0, 0),
        cursorScreenPosition: new globalThis.Vec2(0, 0),
        cursorWorldPosition: new globalThis.Vec3(0, 0, 0)
    };

    // Layer stubs. Mirage does not hand its scene objects to scripts, so a
    // script's writes land here and the engine reads back the one property it
    // drives. That still covers the common clock scripts, which assign
    // `thisLayer.text` and return nothing.
    globalThis.__weLayers = Object.create(null);

    // Playback states, the one part of the media API that scripts read as a
    // constant rather than receive as an event.
    globalThis.MediaPlaybackEvent = {
        PLAYBACK_STOPPED: 0,
        PLAYBACK_PLAYING: 1,
        PLAYBACK_PAUSED: 2
    };
    globalThis.MediaPropertiesEvent = {};
    globalThis.MediaThumbnailEvent = {};
    globalThis.MediaTimelineEvent = {};

    function __weMakeMaterial() {
        return {
            setProperty: function () {},
            getProperty: function () { return 0; },
            setTexture: function () {},
            getTexture: function () { return null; },
            setVisible: function () {},
            visible: true
        };
    }

    function __weMakeEffect(name) {
        var material = __weMakeMaterial();
        return {
            name: String(name || ''),
            visible: true,
            setVisible: function () {},
            getMaterial: function () { return material; },
            getMaterials: function () { return [material]; },
            getPass: function () { return material; }
        };
    }

    globalThis.__weMakeLayer = function (name) {
        var effects = Object.create(null);
        var animationLayers = Object.create(null);
        var material = __weMakeMaterial();
        var animation = {
            playing: false,
            play: function () {},
            stop: function () {},
            pause: function () {},
            reset: function () {},
            setSpeed: function () {},
            setPlaybackSpeed: function () {}
        };
        // Puppet animation is not implemented, so an animation layer is inert.
        // It still has to exist and answer every call, because a script that
        // drives a puppet reaches for one before it does anything else.
        var makeAnimationLayer = function (layerName) {
            return {
                name: String(layerName || ''),
                visible: true,
                rate: 1,
                blend: 1,
                weight: 1,
                playing: false,
                play: function () {},
                stop: function () {},
                pause: function () {},
                reset: function () {},
                setRate: function () {},
                setBlend: function () {},
                setSpeed: function () {},
                setPlaybackSpeed: function () {}
            };
        };
        return {
            name: String(name || ''),
            visible: true,
            alpha: 1,
            brightness: 1,
            color: new globalThis.Vec3(1, 1, 1),
            origin: new globalThis.Vec3(0, 0, 0),
            scale: new globalThis.Vec3(1, 1, 1),
            angles: new globalThis.Vec3(0, 0, 0),
            size: new globalThis.Vec2(0, 0),
            parallaxDepth: new globalThis.Vec2(0, 0),
            text: '',
            font: '',
            pointsize: 12,
            maxwidth: 0,
            getAnimation: function () { return animation; },
            getAnimations: function () { return []; },
            getAnimationLayer: function (layerName) {
                var key = String(layerName);
                if (!animationLayers[key]) { animationLayers[key] = makeAnimationLayer(key); }
                return animationLayers[key];
            },
            getAnimationLayers: function () { return []; },
            playSingleAnimation: function (animationName) { return makeAnimationLayer(animationName); },
            playAnimation: function (animationName) { return makeAnimationLayer(animationName); },
            stopAnimation: function () {},
            getEffect: function (effectName) {
                if (!effects[effectName]) { effects[effectName] = __weMakeEffect(effectName); }
                return effects[effectName];
            },
            getEffects: function () { return []; },
            getMaterial: function () { return material; }
        };
    };

    globalThis.__weGetLayer = function (name) {
        var key = String(name);
        if (!globalThis.__weLayers[key]) { globalThis.__weLayers[key] = globalThis.__weMakeLayer(key); }
        return globalThis.__weLayers[key];
    };

    globalThis.thisScene = {
        getLayer: function (name) { return globalThis.__weGetLayer(name); },
        getObject: function (name) { return globalThis.__weGetLayer(name); },
        getLayerIndex: function () { return 0; },
        sortLayer: function () {},
        createLayer: function (name) { return globalThis.__weMakeLayer(name); },
        removeLayer: function () {}
    };

    // Real wallpaper scripts declare their editable properties by calling this,
    // so the builder has to exist and to chain. The values stored in the
    // scene's `scriptproperties` win over the defaults declared here.
    globalThis.__weScriptProperties = {};

    globalThis.createScriptProperties = function () {
        var defaults = {};
        var stored = globalThis.__weScriptProperties || {};
        var builder = {};
        var proxy;

        function add(descriptor) {
            if (descriptor && typeof descriptor.name === 'string') {
                var value = descriptor.value;
                if (typeof value === 'undefined' && Array.isArray(descriptor.options) && descriptor.options.length > 0) {
                    value = descriptor.options[0].value;
                }
                defaults[descriptor.name] = value;
            }
            return proxy;
        }

        builder.finish = function () {
            var out = {};
            var key;
            for (key in defaults) { out[key] = defaults[key]; }
            for (key in stored) { out[key] = stored[key]; }
            return out;
        };

        // A proxy so an unknown `addSomething` chains instead of throwing.
        proxy = new Proxy(builder, {
            get: function (target, property) {
                if (typeof property === 'symbol') { return undefined; }
                if (property in target) { return target[property]; }
                return add;
            }
        });
        return proxy;
    };
    """#
}
