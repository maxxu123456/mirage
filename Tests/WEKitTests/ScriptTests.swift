import XCTest
@testable import WEKit

/// The scripting layer: identity for scripted values, the per-frame value
/// table, and the JavaScript host itself.
final class ScriptTests: XCTestCase {

    // MARK: Identity

    func testOnlyScriptedValuesGetAnIdentity() {
        let plain = DynamicValue.parse(.string("1 0 0"))
        XCTAssertEqual(plain.scriptID, 0)
        let bound = DynamicValue.parse(.object(["user": .string("colour"), "value": .string("1 0 0")]))
        XCTAssertEqual(bound.scriptID, 0)
        let scripted = DynamicValue.parse(.object(["script": .string("x"), "value": .string("1 0 0")]))
        XCTAssertNotEqual(scripted.scriptID, 0)
    }

    func testEachScriptedValueGetsItsOwnIdentityAndKeepsItWhenCopied() {
        let json = JSON.object(["script": .string("same source"), "value": .number(1)])
        let first = DynamicValue.parse(json)
        let second = DynamicValue.parse(json)
        XCTAssertNotEqual(first.scriptID, second.scriptID, "two values sharing a script are still two values")
        let copy = first
        XCTAssertEqual(copy.scriptID, first.scriptID)
    }

    /// The id says which copy this is, not what the value means, so it must not
    /// leak into equality: the renderer compares values to spot real changes.
    func testEqualityIgnoresIdentity() {
        let json = JSON.object(["script": .string("s"), "value": .number(1)])
        XCTAssertEqual(DynamicValue.parse(json), DynamicValue.parse(json))
    }

    // MARK: Resolution

    func testScriptedValueFallsBackToItsStoredDefaultUntilAScriptProduces() {
        let store = PropertyStore(properties: [])
        let value = DynamicValue.parse(.object(["script": .string("s"), "value": .string("12:34")]))
        XCTAssertEqual(value.resolve(store).string, "12:34")

        let values = ScriptValues()
        store.scriptValues = values
        XCTAssertEqual(value.resolve(store).string, "12:34", "registered but nothing produced yet")

        values.set(value.scriptID, .string("23:59"))
        XCTAssertEqual(value.resolve(store).string, "23:59")
    }

    func testOneScriptResultDoesNotLeakIntoAnother() {
        let store = PropertyStore(properties: [])
        let values = ScriptValues()
        store.scriptValues = values
        let clock = DynamicValue.parse(.object(["script": .string("s"), "value": .string("12:34")]))
        let date = DynamicValue.parse(.object(["script": .string("s"), "value": .string("<Date>")]))
        values.set(clock.scriptID, .string("23:59"))
        XCTAssertEqual(clock.resolve(store).string, "23:59")
        XCTAssertEqual(date.resolve(store).string, "<Date>")
    }

    // MARK: The JavaScript host

    /// `update(value)` receives the property as it currently stands, which is
    /// its own last result: `return value + engine.frametime * speed` is how
    /// every rotating layer in the wild works, and it only accumulates if the
    /// engine feeds the previous frame's value back in. The caller keeps
    /// passing the stored default, and the engine ignores it once the script
    /// has moved the value on.
    func testUpdateAccumulatesAcrossFrames() {
        let engine = ScriptEngine(workshopId: nil)
        let script = "export function update(value) { return value + 1; }"
        guard let handle = engine.register(script: script, scriptProperties: .null,
                                           object: "counter", property: "alpha") else {
            return XCTFail("script did not register")
        }
        engine.beginFrame(time: 0, frameTime: 1.0 / 60, dayTime: 0.5, cursor: SIMD2(0.5, 0.5))
        XCTAssertEqual(engine.evaluate(handle, current: .number(1))?.double, 2)
        engine.beginFrame(time: 1.0 / 60, frameTime: 1.0 / 60, dayTime: 0.5, cursor: SIMD2(0.5, 0.5))
        XCTAssertEqual(engine.evaluate(handle, current: .number(1))?.double, 3)
        engine.beginFrame(time: 2.0 / 60, frameTime: 1.0 / 60, dayTime: 0.5, cursor: SIMD2(0.5, 0.5))
        XCTAssertEqual(engine.evaluate(handle, current: .number(1))?.double, 4)
    }

    /// A clock script ignores the incoming value, so it must not drift.
    func testAScriptThatIgnoresItsValueStaysPut() {
        let engine = ScriptEngine(workshopId: nil)
        let script = "export function update(value) { return 'fixed'; }"
        guard let handle = engine.register(script: script, scriptProperties: .null,
                                           object: "clock", property: "text") else {
            return XCTFail("script did not register")
        }
        for _ in 0..<5 {
            engine.beginFrame(time: 0, frameTime: 0, dayTime: 0, cursor: SIMD2(0.5, 0.5))
            XCTAssertEqual(engine.evaluate(handle, current: .string("placeholder"))?.string, "fixed")
        }
    }

    /// Roughly half the clock scripts in the wild return nothing and assign
    /// `thisLayer.text` instead.
    func testAValueWrittenOntoTheLayerIsPickedUp() {
        let engine = ScriptEngine(workshopId: nil)
        let script = "export function update(value) { thisLayer.text = 'written'; }"
        guard let handle = engine.register(script: script, scriptProperties: .null,
                                           object: "clock", property: "text") else {
            return XCTFail("script did not register")
        }
        engine.beginFrame(time: 0, frameTime: 0, dayTime: 0, cursor: SIMD2(0.5, 0.5))
        XCTAssertEqual(engine.evaluate(handle, current: .string("placeholder"))?.string, "written")
    }

    /// A script reads the layer it drives and its neighbours, so seeded values
    /// have to be visible to `init()` and to `thisScene.getLayer`.
    func testSeededLayerValuesReachTheScript() {
        let engine = ScriptEngine(workshopId: nil)
        engine.seedLayer(named: "mover", values: ["origin": .string("10 20 30")])
        engine.seedLayer(named: "other", values: ["origin": .string("1 2 3")])
        let script = """
        export function update(value) {
            return thisLayer.origin.x + thisScene.getLayer('other').origin.y;
        }
        """
        guard let handle = engine.register(script: script, scriptProperties: .null,
                                           object: "mover", property: "alpha") else {
            return XCTFail("script did not register")
        }
        engine.beginFrame(time: 0, frameTime: 0, dayTime: 0, cursor: SIMD2(0.5, 0.5))
        XCTAssertEqual(engine.evaluate(handle, current: .number(0))?.double, 12)
    }

    func testAVectorReturnComesBackInWallpaperEngineForm() {
        let engine = ScriptEngine(workshopId: nil)
        let script = "export function update(value) { return new Vec3(1, 2, 3); }"
        guard let handle = engine.register(script: script, scriptProperties: .null,
                                           object: "layer", property: "origin") else {
            return XCTFail("script did not register")
        }
        engine.beginFrame(time: 0, frameTime: 0, dayTime: 0, cursor: SIMD2(0.5, 0.5))
        XCTAssertEqual(engine.evaluate(handle, current: .string("0 0 0"))?.vec3, SIMD3<Float>(1, 2, 3))
    }

    /// Wallpaper files are hostile input: a script that throws must be switched
    /// off rather than cost a frame forever.
    func testAThrowingScriptIsDisabledInsteadOfRunningForever() {
        let engine = ScriptEngine(workshopId: nil)
        let script = "export function update(value) { throw new Error('nope'); }"
        guard let handle = engine.register(script: script, scriptProperties: .null,
                                           object: "bad", property: "alpha") else {
            return XCTFail("script did not register")
        }
        for _ in 0..<12 {
            engine.beginFrame(time: 0, frameTime: 0, dayTime: 0, cursor: SIMD2(0.5, 0.5))
            XCTAssertNil(engine.evaluate(handle, current: .number(1)))
        }
        XCTAssertTrue(engine.diagnostics.contains { $0.contains("disabled") })
    }

    func testASyntaxErrorIsReportedRatherThanCrashing() {
        let engine = ScriptEngine(workshopId: nil)
        XCTAssertNil(engine.register(script: "export function update( {{{", scriptProperties: .null,
                                     object: "bad", property: "alpha"))
        XCTAssertFalse(engine.diagnostics.isEmpty)
    }

    /// Real scripts do their layout in `applyUserProperties` and leave `init`
    /// to look up layers, so a script that never receives it runs `update`
    /// against undefined state and throws on the first frame. WE's order is
    /// init, then the properties, then the first update.
    func testUserPropertiesReachTheScriptBeforeTheFirstUpdate() {
        let property = WEUserProperty(name: "scale", json: .object(["type": .string("slider"), "value": .number(2)]), index: 0)
        let store = PropertyStore(properties: [property])
        let engine = ScriptEngine(workshopId: nil)
        engine.setUserProperties(store)
        let script = """
        var factor;
        export function applyUserProperties(properties) { factor = properties.scale; }
        export function update(value) { return factor * 10; }
        """
        guard let handle = engine.register(script: script, scriptProperties: .null,
                                           object: "layer", property: "alpha") else {
            return XCTFail("script did not register")
        }
        engine.beginFrame(time: 0, frameTime: 0, dayTime: 0, cursor: SIMD2(0.5, 0.5))
        XCTAssertEqual(engine.evaluate(handle, current: .number(0))?.double, 20)
    }

    /// Puppet animation is not implemented, but a script that drives one still
    /// has to run: the calls are inert, not missing.
    func testAnimationCallsOnALayerAreInertRatherThanMissing() {
        let engine = ScriptEngine(workshopId: nil)
        let script = """
        export function update(value) {
            var arm = thisScene.getLayer('arm');
            var idle = arm.getAnimationLayer('Idle');
            idle.rate = 0.5;
            arm.playSingleAnimation('Start playing');
            return idle.rate;
        }
        """
        guard let handle = engine.register(script: script, scriptProperties: .null,
                                           object: "turntable", property: "alpha") else {
            return XCTFail("script did not register")
        }
        engine.beginFrame(time: 0, frameTime: 0, dayTime: 0, cursor: SIMD2(0.5, 0.5))
        XCTAssertEqual(engine.evaluate(handle, current: .number(0))?.double, 0.5)
        XCTAssertTrue(engine.diagnostics.isEmpty, "\(engine.diagnostics)")
    }

    func testTimeOfDayReachesTheScript() {
        let engine = ScriptEngine(workshopId: nil)
        let script = "export function update(value) { return engine.timeOfDay; }"
        guard let handle = engine.register(script: script, scriptProperties: .null,
                                           object: "sky", property: "alpha") else {
            return XCTFail("script did not register")
        }
        engine.beginFrame(time: 0, frameTime: 0, dayTime: 0.25, cursor: SIMD2(0.5, 0.5))
        XCTAssertEqual(engine.evaluate(handle, current: .number(0))?.double ?? 0, 0.25, accuracy: 1e-9)
    }
}
