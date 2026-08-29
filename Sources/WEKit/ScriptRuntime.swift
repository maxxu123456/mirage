import Foundation
import simd

/// Drives every scripted value in one wallpaper.
///
/// `ScriptEngine` runs the JavaScript; this is the bookkeeping around it. It
/// registers each scripted `DynamicValue` once, evaluates every registered
/// script exactly once per frame, and publishes the results into the
/// `ScriptValues` table the property store hands to `DynamicValue.resolve`.
///
/// Evaluating up front rather than lazily from `resolve` is deliberate: a
/// scene value is resolved several times per frame (geometry, uniforms, the
/// text rasteriser), and a script's `update()` must run once per frame, not
/// once per reader.
public final class ScriptRuntime {
    private struct Binding {
        let handle: ScriptHandle
        /// The stored default. `evaluate` needs the caller's value, and feeding
        /// a script its own previous result would compound it every frame.
        let current: JSON
        let label: String
    }

    /// The layer properties read back after every frame. Wallpaper Engine's own
    /// names, because that is what a script assigns to.
    private static let writableProperties = [
        "origin", "scale", "angles", "size", "alpha", "color", "brightness", "visible", "text",
    ]

    private let engine: ScriptEngine
    private let values = ScriptValues()
    private var bindings: [Int: Binding] = [:]
    private var registered = Set<Int>()
    private var seededObjects: [String] = []
    private var lastSnapshot: [String: [String: JSON]] = [:]

    public private(set) var diagnostics: [String] = []

    /// How many scripted values are registered, for diagnostics.
    public var boundCount: Int { bindings.count }

    /// What scripts have written onto each layer, for diagnostics.
    public var layerWrites: [String: [String: JSON]] { lastSnapshot }

    public init(workshopId: String?, canvasSize: SIMD2<Float>, store: PropertyStore?, locator: AssetLocator?) {
        engine = ScriptEngine(workshopId: workshopId)
        engine.canvasSize = canvasSize
        // Wallpaper Engine's own classes, when the user has the assets folder.
        // They declare the same names as the built-in fallbacks and shadow
        // them, so a wallpaper behaves the same with or without them.
        // `baseclasses.js` is a plain script; the jsmodules are ES modules whose
        // exports scripts reach as globals, because their `import` lines are
        // stripped on the way in.
        if let source = locator?.text("scripts/jsclasses/baseclasses.js") {
            engine.installRuntime(source: source, name: "baseclasses.js")
        }
        for (path, global) in [("scripts/jsmodules/wemath.js", "WEMath"),
                               ("scripts/jsmodules/wevector.js", "WEVector"),
                               ("scripts/jsmodules/wecolor.js", "WEColor")] {
            guard let source = locator?.text(path) else { continue }
            engine.installModule(source: source, name: path, global: global)
        }
        engine.setUserProperties(store)
        store?.scriptValues = values
    }

    /// Publishes one scene object's values to the scripts, so they can read the
    /// layer they drive and its neighbours. Call before `register`.
    public func seed(object: String, values: [String: JSON]) {
        engine.seedLayer(named: object, values: values)
        seededObjects.append(object)
        // The baseline is what the layer holds after seeding, not what was
        // seeded: a layer object also carries defaults for properties the scene
        // never set, and those must not be mistaken for a script's writes.
        lastSnapshot[object] = engine.layerSnapshot(named: object,
                                                    properties: ScriptRuntime.writableProperties)
        // Seeding writes through the same setters that mark a layer dirty.
        engine.clearDirtyLayers()
    }

    /// Registers one scripted value. Safe to call twice for the same value.
    public func register(_ value: DynamicValue, object: String, property: String) {
        guard let script = value.script, value.scriptID != 0 else { return }
        guard !registered.contains(value.scriptID) else { return }
        registered.insert(value.scriptID)
        guard let handle = engine.register(script: script, scriptProperties: value.scriptProperties,
                                           object: object, property: property) else { return }
        bindings[value.scriptID] = Binding(handle: handle, current: value.value,
                                           label: "\(object).\(property)")
    }

    /// Re-resolves the script properties that are bound to user properties.
    /// Nothing observes the store, so the caller says when it changed.
    public func userPropertiesChanged(_ store: PropertyStore?) {
        engine.setUserProperties(store)
        engine.applyUserProperties()
    }

    /// Runs every script for this frame. Call once, before anything resolves.
    public func beginFrame(time: Double, frameTime: Double, dayTime: Double, cursor: SIMD2<Float>) {
        engine.beginFrame(time: time, frameTime: frameTime, dayTime: dayTime, cursor: cursor)
        for (id, binding) in bindings {
            guard let produced = engine.evaluate(binding.handle, current: binding.current) else { continue }
            values.set(id, produced)
        }
        // Scripts animate layers they do not drive, so their writes only exist
        // on the JavaScript objects until they are read back here.
        publishLayerWrites()
        collectDiagnostics()
    }

    private func publishLayerWrites() {
        // Only the layers a script actually wrote to: reading every property of
        // every object back each frame costs more than the scripts do.
        for object in engine.takeDirtyLayers() {
            let snapshot = engine.layerSnapshot(named: object, properties: ScriptRuntime.writableProperties)
            guard !snapshot.isEmpty else { continue }
            var previous = lastSnapshot[object] ?? [:]
            for (property, value) in snapshot where previous[property] != value {
                previous[property] = value
                values.setLayer(object, property, value)
            }
            lastSnapshot[object] = previous
        }
    }

    private var reportedDiagnostics = 0

    private func collectDiagnostics() {
        let all = engine.diagnostics
        guard all.count > reportedDiagnostics else { return }
        diagnostics.append(contentsOf: all[reportedDiagnostics...])
        reportedDiagnostics = all.count
    }
}
