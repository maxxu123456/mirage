import Foundation
import simd
import WEKit

/// One vertex of a Wallpaper Engine quad. Tightly packed (20 bytes) so it can be
/// handed straight to `setVertexBytes` with `VertexLayout.quad`.
public struct QuadVertex {
    public var x: Float, y: Float, z: Float
    public var u: Float, v: Float

    public init(_ x: Float, _ y: Float, _ z: Float, _ u: Float, _ v: Float) {
        self.x = x; self.y = y; self.z = z; self.u = u; self.v = v
    }
}

/// The object transform after folding in the `parent` chain.
public struct ResolvedTransform {
    public var origin: SIMD3<Float>
    public var scale: SIMD3<Float>
    public var angle: Float          // radians, angles.z

    public init(origin: SIMD3<Float> = .zero, scale: SIMD3<Float> = SIMD3(repeating: 1), angle: Float = 0) {
        self.origin = origin; self.scale = scale; self.angle = angle
    }
}

/// The object's quad in centred, y-mirrored render space.
///
/// Wallpaper Engine scene space is **pixels, origin bottom-left, y up**. The
/// renderer converts to a centred space mirrored in y (`y' = H/2 - y`), exactly
/// as linux-wallpaperengine does, and the present pass flips once more so the
/// two cancel.
public struct LayerRect {
    public var left: Float      // m_pos.x
    public var right: Float     // m_pos.z
    /// The larger value, the edge that ends up at the **bottom** of the screen (`m_pos.y`).
    public var yHigh: Float
    /// The smaller value, the edge that ends up at the **top** of the screen (`m_pos.w`).
    public var yLow: Float

    public var center: SIMD3<Float> { SIMD3((left + right) / 2, (yLow + yHigh) / 2, 0) }
}

public enum SceneGeometry {

    /// Maps a puppet mesh's own space into the renderer's centred, y-mirrored
    /// scene space.
    ///
    /// A `.mdl` stores positions in pixels about its own centre with y up, over
    /// the same extent the layer's quad covers, so this is the quad's placement
    /// expressed as a matrix. The y scale is negative because the scene space is
    /// mirrored, which also reverses the winding: the puppet draw turns culling
    /// off rather than relying on the material to have done so.
    public static func meshMatrix(rect: LayerRect, modelCenter: SIMD2<Float>,
                                  modelExtent: SIMD2<Float>) -> simd_float4x4 {
        let width = modelExtent.x != 0 ? modelExtent.x : 1
        let height = modelExtent.y != 0 ? modelExtent.y : 1
        let center = rect.center
        return Mat.translation(center.x, center.y, 0)
            * Mat.scale((rect.right - rect.left) / width, -(rect.yHigh - rect.yLow) / height, 1)
            * Mat.translation(-modelCenter.x, -modelCenter.y, 0)
    }

    // MARK: Transforms

    /// Folds `parent` chains: `origin = parentOrigin + rotateCCW(childOrigin * parentScale, parentAngle)`,
    /// scales multiply, angles add. Depth-capped like lwe (32).
    /// A value a script wrote onto this object's layer, if any.
    ///
    /// Scripts animate objects they do not drive, so a layer write outranks the
    /// object's own stored value. It is read through the property store because
    /// that is already threaded everywhere a scene value is resolved.
    static func scripted(_ object: WESceneObject, _ property: String, _ store: PropertyStore?) -> JSON? {
        guard let values = store?.scriptValues, values.hasLayerValues else { return nil }
        return values.layerValue(object: object.scriptName, property: property)
    }

    public static func resolveTransform(of object: WESceneObject,
                                        objects: [Int: WESceneObject],
                                        store: PropertyStore?) -> ResolvedTransform {
        var chain: [WESceneObject] = [object]
        var seen: Set<Int> = [object.id]
        var current = object
        while let parentId = current.parent, let parent = objects[parentId], !seen.contains(parentId), chain.count < 32 {
            chain.append(parent)
            seen.insert(parentId)
            current = parent
        }
        func local(_ o: WESceneObject) -> ResolvedTransform {
            ResolvedTransform(origin: scripted(o, "origin", store)?.vec3 ?? o.origin.resolve(store).vec3 ?? .zero,
                              scale: scripted(o, "scale", store)?.vec3 ?? o.scale.resolve(store).vec3 ?? SIMD3(repeating: 1),
                              angle: (scripted(o, "angles", store)?.vec3 ?? o.angles.resolve(store).vec3 ?? .zero).z)
        }
        var resolved = local(chain[chain.count - 1])
        var index = chain.count - 2
        while index >= 0 {
            var localT = local(chain[index])
            let offset = rotateCCW(SIMD2(localT.origin.x * resolved.scale.x, localT.origin.y * resolved.scale.y),
                                   resolved.angle)
            localT.origin = SIMD3(resolved.origin.x + offset.x,
                                  resolved.origin.y + offset.y,
                                  resolved.origin.z + localT.origin.z * resolved.scale.z)
            resolved = ResolvedTransform(origin: localT.origin,
                                         scale: localT.scale * resolved.scale,
                                         angle: localT.angle + resolved.angle)
            index -= 1
        }
        return resolved
    }

    public static func rotateCCW(_ v: SIMD2<Float>, _ angle: Float) -> SIMD2<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    /// Quad corners, applying `alignment` and converting to the centred mirrored space.
    public static func rect(origin: SIMD3<Float>, size: SIMD2<Float>, scale: SIMD3<Float>,
                            alignment: String, sceneWidth: Float, sceneHeight: Float) -> LayerRect {
        let scaled = SIMD2(size.x * scale.x, size.y * scale.y)
        var left = origin.x - scaled.x / 2
        var right = origin.x + scaled.x / 2
        var bottom = origin.y - scaled.y / 2
        var top = origin.y + scaled.y / 2

        // Substring tests, exactly like lwe: "topleft" shifts both axes.
        if alignment.contains("top") { bottom -= scaled.y / 2; top -= scaled.y / 2 }
        else if alignment.contains("bottom") { bottom += scaled.y / 2; top += scaled.y / 2 }
        if alignment.contains("left") { left += scaled.x / 2; right += scaled.x / 2 }
        else if alignment.contains("right") { left -= scaled.x / 2; right -= scaled.x / 2 }

        return LayerRect(left: left - sceneWidth / 2,
                         right: right - sceneWidth / 2,
                         yHigh: sceneHeight / 2 - bottom,
                         yLow: sceneHeight / 2 - top)
    }

    // MARK: Vertex buffers

    /// Buffer A, the first ("copy") pass: positions in `(0…size)`, UVs cropped to the
    /// non-padded content. `ortho y = 0` carries `v = 0`, i.e. the image's top row.
    public static func copyQuad(size: SIMD2<Float>, ratio: SIMD2<Float>) -> [QuadVertex] {
        let w = size.x, h = size.y, cw = ratio.x, ch = ratio.y
        return [
            QuadVertex(0, h, 0, 0, ch),
            QuadVertex(0, 0, 0, 0, 0),
            QuadVertex(w, h, 0, cw, ch),
            QuadVertex(w, h, 0, cw, ch),
            QuadVertex(0, 0, 0, 0, 0),
            QuadVertex(w, 0, 0, cw, 0),
        ]
    }

    /// Buffer A for a `passthrough` model: the quad is already in scene space and
    /// `MVP_copy == MVP_screen`; UVs are the full rect.
    public static func passthroughCopyQuad(_ rect: LayerRect) -> [QuadVertex] {
        // lwe's realX/realY/realWidth/realHeight = m_pos.x / m_pos.w / m_pos.z / m_pos.y
        let x = rect.left, y = rect.yLow, w = rect.right, h = rect.yHigh
        return [
            QuadVertex(x, h, 0, 0, 1),
            QuadVertex(x, y, 0, 0, 0),
            QuadVertex(w, h, 0, 1, 1),
            QuadVertex(w, h, 0, 1, 1),
            QuadVertex(x, y, 0, 0, 0),
            QuadVertex(w, y, 0, 1, 0),
        ]
    }

    /// Buffer A for `passthrough && fullscreen`: a literal NDC quad (the stock
    /// `passthrough.vert` ignores the MVP entirely).
    public static let fullscreenPassthroughQuad: [QuadVertex] = [
        QuadVertex(-1, 1, 0, 0, 1),
        QuadVertex(-1, -1, 0, 0, 0),
        QuadVertex(1, 1, 0, 1, 1),
        QuadVertex(1, 1, 0, 1, 1),
        QuadVertex(-1, -1, 0, 0, 0),
        QuadVertex(1, -1, 0, 1, 0),
    ]

    /// Buffer B, every intermediate effect pass: an NDC quad with identity MVP.
    public static let effectQuad: [QuadVertex] = [
        QuadVertex(-1, 1, 0, 0, 1),
        QuadVertex(-1, -1, 0, 0, 0),
        QuadVertex(1, 1, 0, 1, 1),
        QuadVertex(1, 1, 0, 1, 1),
        QuadVertex(-1, -1, 0, 0, 0),
        QuadVertex(1, -1, 0, 1, 0),
    ]

    /// Buffer C, the final pass, drawn into the scene with `MVP_screen`.
    /// The UVs are buffer B's, unless this is also the object's first pass.
    public static func sceneQuad(_ rect: LayerRect, uvRatio: SIMD2<Float>?) -> [QuadVertex] {
        let cw = uvRatio?.x ?? 1, ch = uvRatio?.y ?? 1
        let x = rect.left, z = rect.right, yh = rect.yHigh, yl = rect.yLow
        return [
            QuadVertex(x, yh, 0, 0, ch),
            QuadVertex(x, yl, 0, 0, 0),
            QuadVertex(z, yh, 0, cw, ch),
            QuadVertex(z, yh, 0, cw, ch),
            QuadVertex(x, yl, 0, 0, 0),
            QuadVertex(z, yl, 0, cw, 0),
        ]
    }

    // MARK: Matrices

    /// `ortho(-W/2, W/2, -H/2, H/2, nearz, farz)`. The camera `eye` cancels against
    /// `lookAt` for every scene seen in the wild, so the view matrix is the identity.
    public static func sceneProjection(width: Float, height: Float, nearZ: Float, farZ: Float, zoom: Float) -> simd_float4x4 {
        let z = zoom > 0.0001 ? zoom : 1
        let w = width / z, h = height / z
        // The scene's nearz/farz (typically 0.01 / 10000) would put z = 0 outside the
        // clip volume; every quad is flat at z = 0 and nothing depth-tests, so use a
        // symmetric range instead. See Mat.ortho.
        _ = (nearZ, farZ)
        return Mat.ortho(left: -w / 2, right: w / 2, bottom: -h / 2, top: h / 2, near: -1, far: 1)
    }

    /// `MVP_screen = P · T(c) · Rz(-angle) · T(-c) · T(parallax)`.
    public static func screenMatrix(projection: simd_float4x4, rect: LayerRect, angle: Float,
                                    parallax: SIMD2<Float>) -> simd_float4x4 {
        var m = projection
        if angle != 0 {
            let c = rect.center
            m = m * Mat.translation(c.x, c.y, c.z) * Mat.rotationZ(-angle) * Mat.translation(-c.x, -c.y, -c.z)
        }
        if parallax != .zero {
            m = m * Mat.translation(parallax.x, parallax.y, 0)
        }
        return m
    }

    /// `MVP_copy` for a normal (non-passthrough) model.
    public static func copyMatrix(size: SIMD2<Float>) -> simd_float4x4 {
        Mat.ortho(left: 0, right: max(size.x, 1), bottom: 0, top: max(size.y, 1), near: -1, far: 1)
    }
}
