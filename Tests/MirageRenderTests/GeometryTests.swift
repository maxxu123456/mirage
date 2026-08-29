import XCTest
import simd
@testable import MirageRender
@testable import WEKit

/// Wallpaper Engine scene space is pixels with the origin at the **bottom-left**
/// and y growing up. The renderer mirrors it into a centred space and the present
/// pass leaves it alone, so these tests pin the orientation end to end: get one of
/// them wrong and every wallpaper renders upside down.
final class GeometryTests: XCTestCase {
    let sceneW: Float = 1920
    let sceneH: Float = 1080

    func testObjectLowInSceneSpaceEndsUpAtTheBottomOfTheScreen() {
        // A bed at scene y = 200 belongs near the bottom of the frame.
        let rect = SceneGeometry.rect(origin: SIMD3(960, 200, 0), size: SIMD2(400, 200),
                                      scale: SIMD3(repeating: 1), alignment: "center",
                                      sceneWidth: sceneW, sceneHeight: sceneH)
        // yHigh is the screen-bottom edge and must be the larger value.
        XCTAssertGreaterThan(rect.yHigh, rect.yLow)
        XCTAssertEqual(rect.yLow, 540 - 300, accuracy: 0.001)   // H/2 - (origin.y + h/2)
        XCTAssertEqual(rect.yHigh, 540 - 100, accuracy: 0.001)  // H/2 - (origin.y - h/2)
        // Both edges sit below the centre line (positive = lower half after mirroring).
        XCTAssertGreaterThan(rect.yLow, 0)
    }

    func testObjectHighInSceneSpaceEndsUpAtTheTopOfTheScreen() {
        let rect = SceneGeometry.rect(origin: SIMD3(960, 1000, 0), size: SIMD2(400, 200),
                                      scale: SIMD3(repeating: 1), alignment: "center",
                                      sceneWidth: sceneW, sceneHeight: sceneH)
        XCTAssertLessThan(rect.yHigh, 0)
    }

    func testAlignmentMovesTheQuadSoTheOriginSitsOnTheNamedEdge() {
        let centered = SceneGeometry.rect(origin: SIMD3(960, 540, 0), size: SIMD2(400, 200),
                                          scale: SIMD3(repeating: 1), alignment: "center",
                                          sceneWidth: sceneW, sceneHeight: sceneH)
        // "top" pushes the quad down in WE space, i.e. to larger mirrored y.
        let top = SceneGeometry.rect(origin: SIMD3(960, 540, 0), size: SIMD2(400, 200),
                                     scale: SIMD3(repeating: 1), alignment: "top",
                                     sceneWidth: sceneW, sceneHeight: sceneH)
        XCTAssertEqual(top.yLow, centered.yLow + 100, accuracy: 0.001)
        XCTAssertEqual(top.yHigh, centered.yHigh + 100, accuracy: 0.001)
        // Compound tokens shift both axes.
        let topLeft = SceneGeometry.rect(origin: SIMD3(960, 540, 0), size: SIMD2(400, 200),
                                         scale: SIMD3(repeating: 1), alignment: "topleft",
                                         sceneWidth: sceneW, sceneHeight: sceneH)
        XCTAssertEqual(topLeft.left, centered.left + 200, accuracy: 0.001)
        XCTAssertEqual(topLeft.yLow, top.yLow, accuracy: 0.001)
    }

    func testAlignmentScalesWithTheObjectScale() {
        let rect = SceneGeometry.rect(origin: SIMD3(0, 0, 0), size: SIMD2(400, 200),
                                      scale: SIMD3(2, 2, 1), alignment: "left",
                                      sceneWidth: 0, sceneHeight: 0)
        XCTAssertEqual(rect.left, 0, accuracy: 0.001)          // -400 + 400
        XCTAssertEqual(rect.right, 800, accuracy: 0.001)
    }

    func testCopyQuadPutsTheImageTopRowAtTheTopOfTheScreen() {
        let quad = SceneGeometry.copyQuad(size: SIMD2(100, 50), ratio: SIMD2(1, 1))
        // The vertex at ortho y = 0 maps to clip y = -1, which FLIP_VERTEX_Y turns into
        // Metal's top row, and it must carry v = 0, the first row of the texture.
        let atOrthoZero = quad.filter { $0.y == 0 }
        XCTAssertFalse(atOrthoZero.isEmpty)
        for vertex in atOrthoZero { XCTAssertEqual(vertex.v, 0, accuracy: 0.0001) }
        let atOrthoTop = quad.filter { $0.y == 50 }
        for vertex in atOrthoTop { XCTAssertEqual(vertex.v, 1, accuracy: 0.0001) }
    }

    func testSceneQuadPairsTheScreenTopEdgeWithVZero() {
        let rect = LayerRect(left: -100, right: 100, yHigh: 50, yLow: -50)
        let quad = SceneGeometry.sceneQuad(rect, uvRatio: nil)
        for vertex in quad where vertex.y == rect.yLow { XCTAssertEqual(vertex.v, 0, accuracy: 0.0001) }
        for vertex in quad where vertex.y == rect.yHigh { XCTAssertEqual(vertex.v, 1, accuracy: 0.0001) }
    }

    func testPotPaddingCropsTheUVsToTheContent() {
        let quad = SceneGeometry.copyQuad(size: SIMD2(1920, 1080), ratio: SIMD2(1920.0 / 2048, 1080.0 / 2048))
        XCTAssertEqual(quad.map(\.u).max()!, 1920.0 / 2048, accuracy: 0.0001)
        XCTAssertEqual(quad.map(\.v).max()!, 1080.0 / 2048, accuracy: 0.0001)
    }

    func testOrthographicProjectionKeepsFlatGeometryInsideMetalsClipVolume() {
        // Metal clips z to [0, 1]; an OpenGL-style matrix would send z = 0 to -1 and
        // silently discard every quad.
        let projection = SceneGeometry.sceneProjection(width: sceneW, height: sceneH,
                                                       nearZ: 0.01, farZ: 10000, zoom: 1)
        let clip = projection * SIMD4<Float>(0, 0, 0, 1)
        XCTAssertGreaterThanOrEqual(clip.z, 0)
        XCTAssertLessThanOrEqual(clip.z, clip.w)
        // Corners map to the edges of the viewport.
        let topRight = projection * SIMD4<Float>(sceneW / 2, sceneH / 2, 0, 1)
        XCTAssertEqual(topRight.x, 1, accuracy: 0.0001)
        XCTAssertEqual(topRight.y, 1, accuracy: 0.0001)
    }

    func testParentChainFoldsOriginScaleAndAngle() {
        let parent = WESceneObject(json: .object([
            "id": .number(1), "origin": .string("100 200 0"), "scale": .string("2 2 1"), "angles": .string("0 0 0"),
        ]))
        let child = WESceneObject(json: .object([
            "id": .number(2), "parent": .number(1), "image": .string("models/x.json"),
            "origin": .string("10 20 0"), "scale": .string("3 3 1"), "angles": .string("0 0 0"),
        ]))
        let resolved = SceneGeometry.resolveTransform(of: child, objects: [1: parent, 2: child], store: nil)
        XCTAssertEqual(resolved.origin.x, 100 + 10 * 2, accuracy: 0.001)
        XCTAssertEqual(resolved.origin.y, 200 + 20 * 2, accuracy: 0.001)
        XCTAssertEqual(resolved.scale.x, 6, accuracy: 0.001)
    }

    func testUniformWriterPacksMatricesAtReflectedOffsets() {
        let block = ShaderCompiler.UniformBlock(bufferIndex: 0, size: 96, members: [
            .init(name: "m", offset: 0, baseType: "float", vecSize: 4, columns: 4,
                  arrayLength: 0, arrayStride: 0, matrixStride: 16),
            .init(name: "v", offset: 64, baseType: "float", vecSize: 3, columns: 1,
                  arrayLength: 0, arrayStride: 0, matrixStride: 0),
            .init(name: "f", offset: 80, baseType: "float", vecSize: 1, columns: 1,
                  arrayLength: 0, arrayStride: 0, matrixStride: 0),
        ])
        let writer = UniformWriter(block: block)
        var bag = ShaderValueBag()
        bag.set("m", Mat.translation(1, 2, 3))
        bag.set("v", SIMD3<Float>(4, 5, 6))
        bag.set("f", 7 as Float)
        var bytes = [UInt8](repeating: 0, count: writer.byteCount)
        writer.write(bag, into: &bytes)
        bytes.withUnsafeBytes { raw in
            // Column 3 of the translation matrix holds the offset.
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: 48, as: Float.self), 1)
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: 52, as: Float.self), 2)
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: 64, as: Float.self), 4)
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: 72, as: Float.self), 6)
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: 80, as: Float.self), 7)
        }
    }

    func testUniformWriterBroadcastsScalarsIntoVectors() {
        let block = ShaderCompiler.UniformBlock(bufferIndex: 0, size: 16, members: [
            .init(name: "color", offset: 0, baseType: "float", vecSize: 3, columns: 1,
                  arrayLength: 0, arrayStride: 0, matrixStride: 0),
        ])
        let writer = UniformWriter(block: block)
        var bag = ShaderValueBag()
        bag.set("color", 0.5 as Float)
        var bytes = [UInt8](repeating: 0, count: writer.byteCount)
        writer.write(bag, into: &bytes)
        bytes.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: 12, by: 4) {
                XCTAssertEqual(raw.loadUnaligned(fromByteOffset: offset, as: Float.self), 0.5)
            }
        }
    }

    func testUniformWriterClampsNonFiniteAndOutOfRangeIntegers() {
        let block = ShaderCompiler.UniformBlock(bufferIndex: 0, size: 16, members: [
            .init(name: "i", offset: 0, baseType: "int", vecSize: 1, columns: 1,
                  arrayLength: 0, arrayStride: 0, matrixStride: 0),
            .init(name: "u", offset: 4, baseType: "uint", vecSize: 1, columns: 1,
                  arrayLength: 0, arrayStride: 0, matrixStride: 0),
            .init(name: "b", offset: 8, baseType: "bool", vecSize: 1, columns: 1,
                  arrayLength: 0, arrayStride: 0, matrixStride: 0),
        ])
        let writer = UniformWriter(block: block)
        var bag = ShaderValueBag()
        bag["i"] = .scalar(-Float.greatestFiniteMagnitude)
        bag["u"] = .scalar(Float.greatestFiniteMagnitude)
        bag["b"] = .scalar(.nan)
        var bytes: [UInt8] = []
        writer.write(bag, into: &bytes)
        bytes.withUnsafeBytes { raw in
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: 0, as: Int32.self), .min)
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self), .max)
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self), 0)
        }
    }

    func testUniformWriterRejectsHostileReflectionShapeWithoutOverrunning() {
        let block = ShaderCompiler.UniformBlock(bufferIndex: 0, size: Int.max, members: [
            .init(name: "bad", offset: Int.max, baseType: "float", vecSize: Int.max, columns: Int.max,
                  arrayLength: Int.max, arrayStride: Int.max, matrixStride: Int.max),
        ])
        let writer = UniformWriter(block: block)
        // Clamped, not honoured: the cap is generous enough for a large bone
        // palette and far short of what a corrupt reflection would ask for.
        XCTAssertEqual(writer.byteCount, 64 * 1024)
        var bag = ShaderValueBag()
        bag.set("bad", 1 as Float)
        var bytes: [UInt8] = []
        writer.write(bag, into: &bytes)
        XCTAssertEqual(bytes.count, 64 * 1024)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
    }

    func testSceneSizeBoundsHostileProjectionDimensions() {
        let scene = WEScene(json: .object([
            "general": .object([
                "orthogonalprojection": .object([
                    "width": .number(1_000_000_000),
                    "height": .number(1_000_000_000),
                ]),
            ]),
        ]))
        XCTAssertEqual(SceneRenderer.resolveSceneSize(scene: scene, store: nil).0, 16_384)
        XCTAssertEqual(SceneRenderer.resolveSceneSize(scene: scene, store: nil).1, 16_384)
    }

    func testSamplerComboRequirementsUseMaterialCombosNotDeclaredDefaults() {
        let locator = AssetLocator(projectDirectory: URL(fileURLWithPath: "/tmp"), package: nil,
                                   assetsDirectories: [], fallbackDirectory: nil)
        let source = ShaderPreprocessor(locator: locator).load(
            name: "combo",
            vertex: "void main() {}",
            fragment: #"""
            // [COMBO] {"combo":"MASK","default":0}
            // [COMBO] {"combo":"MODE","default":1}
            uniform sampler2D g_Texture0; // {"combo":"MASK","default":2,"require":{"MODE":1}}
            """#
        )

        XCTAssertEqual(SceneRenderer.samplerCombos(source: source, passTextures: [:], overrideTextures: [:],
                                                    materialCombos: ["MODE": 0], overrideCombos: [:])["MASK"], 2)
        XCTAssertNil(SceneRenderer.samplerCombos(source: source, passTextures: [:], overrideTextures: [:],
                                                 materialCombos: ["MODE": 1], overrideCombos: [:])["MASK"])
        XCTAssertEqual(SceneRenderer.samplerCombos(source: source, passTextures: [0: "asset"], overrideTextures: [:],
                                                    materialCombos: [:], overrideCombos: [:])["MASK"], 1)
    }
}
