import XCTest
@testable import WEKit

final class WEKitTests: XCTestCase {
    func testJSONVectors() throws {
        let j = try JSON.parse(#"{"a": "1 0.5 0.25", "b": 2, "c": true, "d": {"user": "x", "value": false}}"#)
        XCTAssertEqual(j["a"].vec3, SIMD3<Float>(1, 0.5, 0.25))
        XCTAssertEqual(j["b"].int, 2)
        XCTAssertEqual(j["c"].bool, true)
        let d = DynamicValue.parse(j["d"])
        XCTAssertEqual(d.user, "x")
        XCTAssertEqual(d.value, .bool(false))
    }

    func testHostileNumericConversionsFailSoft() {
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            XCTAssertNil(JSON.number(value).int)
            XCTAssertNil(JSON.number(value).float)
        }
        XCTAssertEqual(JSON.number(1.6).int, 2)

        let project = WEProject(directory: URL(fileURLWithPath: "/tmp/example"),
                                json: .object(["workshopid": .number(.nan)]))
        XCTAssertNil(project.workshopId)

        let escapingProject = WEProject(directory: URL(fileURLWithPath: "/tmp/example"),
                                        json: .object(["file": .string("../secret.mp4")]))
        XCTAssertNil(escapingProject.fileURL)
    }

    func testJSONBoundsDocumentSizeAndNesting() {
        XCTAssertThrowsError(try JSON.parse(Data(count: JSON.maximumDocumentByteCount + 1)))
        let deeplyNested = String(repeating: "[", count: JSON.maximumNestingDepth + 1)
            + "0" + String(repeating: "]", count: JSON.maximumNestingDepth + 1)
        XCTAssertThrowsError(try JSON.parse(deeplyNested))

        var nested: Any = 1
        for _ in 0..<200 { nested = [nested] }
        var value = JSON(any: nested)
        for _ in 0..<JSON.maximumNestingDepth { value = value[0] }
        XCTAssertTrue(value.isNull)
    }

    func testPixelSizingAndBlockDecodeRejectInvalidDimensions() {
        XCTAssertNil(WEPixelLayout.rgba8.checkedByteCount(width: Int.max, height: 2))
        XCTAssertNil(WEPixelLayout.bc3.checkedByteCount(width: -1, height: 4))
        XCTAssertNil(BlockCompression.decodeToRGBA8(Data(), width: -1, height: 4, layout: .rgba8))
        XCTAssertNil(BlockCompression.decodeToRGBA8(Data(count: 3), width: 1, height: 1, layout: .rgba8))
        XCTAssertThrowsError(try WETexture.lz4DecompressRaw(Data([0]),
                                                            expectedSize: WEPixelLayout.maximumAllocationByteCount + 1))
    }

    func testPackageRejectsImpossibleEntryCount() throws {
        var data = Data()
        func appendU32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let magic = Data("PKGV0020".utf8)
        appendU32(UInt32(magic.count))
        data.append(magic)
        appendU32(UInt32.max)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pkg")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        XCTAssertThrowsError(try WEPackage(url: url))
    }

    func testAssetLocatorRejectsParentTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = AssetLocator(projectDirectory: project, package: nil,
                                   assetsDirectories: [], fallbackDirectory: nil)
        XCTAssertNil(locator.data("../secret.txt"))
    }

    func testConditionEvaluator() {
        let props = [
            WEUserProperty(name: "bloom", json: .object(["type": .string("bool"), "value": .bool(true)]), index: 0),
            WEUserProperty(name: "weather", json: .object(["type": .string("combo"), "value": .string("1")]), index: 1),
            WEUserProperty(name: "amount", json: .object(["type": .string("slider"), "value": .number(0.7)]), index: 2),
        ]
        let store = PropertyStore(properties: props)
        XCTAssertTrue(store.evaluateCondition("bloom.value == true"))
        XCTAssertTrue(store.evaluateCondition("weather.value == 1"))
        XCTAssertFalse(store.evaluateCondition("weather.value == 0"))
        XCTAssertTrue(store.evaluateCondition("amount > 0.5 && bloom"))
        XCTAssertFalse(store.evaluateCondition("!bloom"))
        let bound = DynamicValue(value: .bool(true), user: "weather", condition: "1")
        XCTAssertEqual(bound.resolve(store), .bool(true))
        let bound0 = DynamicValue(value: .bool(true), user: "weather", condition: "0")
        XCTAssertEqual(bound0.resolve(store), .bool(false))
    }

    func testIncludeInsertion() {
        let lines = [
            "uniform float a;",
            "#if MASK",
            "uniform float b;",
            "#endif",
            "varying vec2 v;",
            "#if AUDIO",
            "float helper(float x) { return x; }",
            "#endif",
            "void main() {}",
        ]
        XCTAssertEqual(ShaderPreprocessor.includeInsertionIndex(lines), 5)
    }

    func testFinalize() {
        let v = """
        #version 450
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
        """
        let f = """
        #version 450
        varying vec4 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture2;
        void main() { gl_FragColor = texture(g_Texture0, v_TexCoord.xy); }
        """
        let fin = ShaderPreprocessor.finalize(vertexPreprocessed: v, fragmentPreprocessed: f)
        XCTAssertTrue(fin.vertex.contains("layout(location = 0) in vec3 a_Position;"))
        XCTAssertTrue(fin.vertex.contains("layout(location = 0) out vec2 v_TexCoord;"))
        XCTAssertTrue(fin.fragment.contains("layout(location = 0) in vec2 v_TexCoord_vin;"))
        XCTAssertTrue(fin.fragment.contains("v_TexCoord = vec4(v_TexCoord_vin, 0.0, 1.0);"))
        XCTAssertTrue(fin.fragment.contains("layout(set = 0, binding = 2) uniform sampler2D g_Texture2;"))
        XCTAssertTrue(fin.fragment.contains("out_FragColor"))
        XCTAssertEqual(fin.textureBindings["g_Texture2"], 2)
    }

    func testFinalizeCastsSameWidthVaryingsWithDifferentBaseTypes() {
        let vertex = "varying vec2 value;\nvoid main() { value = vec2(1.0); gl_Position = vec4(0.0); }"
        let fragment = "varying ivec2 value;\nvoid main() { gl_FragColor = vec4(value, 0, 1); }"
        let result = ShaderPreprocessor.finalize(vertexPreprocessed: vertex, fragmentPreprocessed: fragment)
        XCTAssertTrue(result.fragment.contains("value = ivec2(value_vin);"))
    }

    func testFragmentSamplerDefaultOverridesVertexDefault() {
        let locator = AssetLocator(projectDirectory: URL(fileURLWithPath: "/tmp"), package: nil,
                                   assetsDirectories: [], fallbackDirectory: nil)
        let preprocessor = ShaderPreprocessor(locator: locator)
        let vertex = "uniform sampler2D g_Texture0; // {\"default\":\"vertex\"}\nvoid main() {}"
        let fragment = "uniform sampler2D g_Texture0; // {\"default\":\"fragment\"}\nvoid main() {}"
        let source = preprocessor.load(name: "defaults", vertex: vertex, fragment: fragment)
        XCTAssertEqual(source.uniform(named: "g_Texture0")?.defaultValue.string, "fragment")
    }

    func testConditionEvaluatorBoundsRecursiveInput() {
        let store = PropertyStore(properties: [])
        XCTAssertFalse(store.evaluateCondition(String(repeating: "!", count: 300) + "true"))
    }

    /// The bloom chain is manufactured rather than loaded, so nothing else would
    /// catch a typo in the pass order or a bind that names the wrong target.
    func testBloomChainShape() {
        func pass(_ material: String, _ target: String, _ binds: [(String, Int)]) -> JSON {
            .object([
                "material": .string(material),
                "target": .string(target),
                "bind": .array(binds.map { .object(["name": .string($0.0), "index": .number(Double($0.1))]) }),
            ])
        }
        let effect = WEEffect(json: .object(["name": .string("bloom"), "passes": .array([
            pass("materials/util/downsample_quarter_bloom.json", "_rt_4FrameBuffer", [("_rt_FullFrameBuffer", 0)]),
            pass("materials/util/downsample_eighth_blur_v.json", "_rt_8FrameBuffer", [("_rt_4FrameBuffer", 0)]),
            pass("materials/util/blur_h_bloom.json", "_rt_Bloom", [("_rt_8FrameBuffer", 0)]),
            pass("materials/util/combine.json", "_rt_FullFrameBuffer",
                 [("_rt_imageLayerComposite_-1_a", 0), ("_rt_Bloom", 1)]),
        ])]))
        XCTAssertEqual(effect.passes.count, 4)
        XCTAssertEqual(effect.passes.map(\.target),
                       ["_rt_4FrameBuffer", "_rt_8FrameBuffer", "_rt_Bloom", "_rt_FullFrameBuffer"])
        // The scene copy the combine reads has to be the bloom object's own
        // composite, which is named from its id.
        XCTAssertEqual(effect.passes[3].binds.first?.name, "_rt_imageLayerComposite_-1_a")
    }

    /// Bloom strength and threshold are usually bound to user properties, and
    /// have to stay bound so the sliders keep working.
    func testBloomStrengthStaysBound() {
        let bound = DynamicValue.parse(.object(["user": .string("bloomstrength"), "value": .number(4)]))
        XCTAssertTrue(bound.isBound)
        let store = PropertyStore(properties: [], overrides: ["bloomstrength": .number(1.5)])
        XCTAssertEqual(bound.resolveFloat(store), 1.5)
    }

    func testSceneDefaultsMatchRendererSpec() {
        let scene = WEScene(json: .object([:]))
        XCTAssertEqual(scene.general.clearColor.resolve(nil).vec3, SIMD3<Float>(1, 1, 1))
        let object = WESceneObject(json: .object(["image": .string("models/a.json")]))
        XCTAssertEqual(object.parallaxDepth.resolve(nil).vec2, SIMD2<Float>(0, 0))
    }
}
