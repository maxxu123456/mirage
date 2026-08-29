import Foundation
import simd

/// Reader for Wallpaper Engine puppet-warp models (`.mdl`).
///
/// A puppet is a skinned mesh: a triangle list whose vertices carry four bone
/// indices and weights, a bone hierarchy with bind transforms, and a set of
/// keyframed animations. The renderer feeds `boneMatrices` into `g_Bones[]`
/// with `SKINNING=1` / `BONECOUNT=n`, which is why the parser hands back
/// finished skinning matrices rather than raw poses.
///
/// Layout (little endian), verified against two independent reimplementations:
/// ```
/// "MDLV00xx" NUL          versions 13, 21 and 23 seen
/// i32 flag                9 means the puppet was never finished, so it is unusable
/// i32 1; i32 1
/// u32 len + material path
/// i32 0
/// u32 herald              0x01800009 standard, else scan for 0x0180000F (alternate)
/// u32 vertexBytes + vertex data     stride 52 (standard) or 80 (alternate)
/// u32 indexBytes  + u16 indices
/// "MDLS00xx" NUL          bones
/// "MDAT00xx" NUL          optional, skipped
/// "MDLA00xx" NUL          animations
/// ```
/// Wallpaper files are third-party input, so every read is bounds checked and
/// anything malformed yields `nil` or a shortened result instead of a trap.
public struct PuppetVertex {
    public let position: SIMD3<Float>
    public let blendIndices: SIMD4<UInt32>
    public let blendWeights: SIMD4<Float>
    public let uv: SIMD2<Float>

    public init(position: SIMD3<Float>, blendIndices: SIMD4<UInt32>,
                blendWeights: SIMD4<Float>, uv: SIMD2<Float>) {
        self.position = position
        self.blendIndices = blendIndices
        self.blendWeights = blendWeights
        self.uv = uv
    }
}

public struct PuppetBone {
    public let name: String
    /// Index into `PuppetModel.bones`, `nil` for a root. Always smaller than the
    /// bone's own index, so a single forward pass can evaluate the hierarchy.
    public let parent: Int?
    public let bindTransform: simd_float4x4

    public init(name: String, parent: Int?, bindTransform: simd_float4x4) {
        self.name = name
        self.parent = parent
        self.bindTransform = bindTransform
    }
}

public struct PuppetAnimation {
    public let id: Int
    public let name: String

    public enum Mode {
        case loop, mirror, single
    }

    public let mode: Mode
    public let fps: Float
    public let frameCount: Int
    /// tracks[bone][frame] = (position, eulerAngles, scale)
    public let tracks: [[(position: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>)]]

    public init(id: Int, name: String, mode: Mode, fps: Float, frameCount: Int,
                tracks: [[(position: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>)]]) {
        self.id = id
        self.name = name
        self.mode = mode
        self.fps = fps
        self.frameCount = frameCount
        self.tracks = tracks
    }
}

public struct PuppetModel {
    public let materialPath: String
    public let vertices: [PuppetVertex]
    public let indices: [UInt16]
    public let bones: [PuppetBone]
    public let animations: [PuppetAnimation]

    public init(materialPath: String, vertices: [PuppetVertex], indices: [UInt16],
                bones: [PuppetBone], animations: [PuppetAnimation]) {
        self.materialPath = materialPath
        self.vertices = vertices
        self.indices = indices
        self.bones = bones
        self.animations = animations
    }

    /// Parses `.mdl` bytes, returning `nil` for anything this reader cannot make
    /// sense of. Animations are optional: a file whose animation section is
    /// missing or damaged still yields a mesh that draws in its bind pose.
    public static func parse(_ data: Data) -> PuppetModel? {
        PuppetReader.parse(data)
    }

    /// Index of the first animation with this name, for callers that hold names
    /// (`animationlayers` in `scene.json`) rather than indices.
    public func animationIndex(named name: String) -> Int? {
        animations.firstIndex { $0.name == name }
    }
}

// MARK: - Skinning

public extension PuppetModel {
    /// Skinning matrices for a set of weighted animation layers at `time`.
    ///
    /// Each layer samples its animation, the samples are averaged by `blend`,
    /// the result is composed as `T(pos) * R(euler zyx) * S(scale)`, walked up
    /// the parent chain and multiplied by `inverse(bindTransform)`. A bone no
    /// layer touches keeps its local bind pose, so the identity result of an
    /// empty `layers` array leaves the mesh exactly as authored.
    func boneMatrices(layers: [(animation: Int, blend: Float, rate: Float)],
                      time: Double) -> [simd_float4x4] {
        guard !bones.isEmpty else { return [] }
        let count = bones.count

        // Local bind pose, the fallback for bones with no animation influence.
        var locals = [simd_float4x4](repeating: matrix_identity_float4x4, count: count)
        for i in 0..<count {
            if let parent = bones[i].parent, parent < i {
                locals[i] = safeInverse(bones[parent].bindTransform) * bones[i].bindTransform
            } else {
                locals[i] = bones[i].bindTransform
            }
        }

        // The accumulator sums weighted poses, so it starts at zero on every
        // component, including scale, and is divided by the total weight below.
        let zeroPose = Pose(position: .zero, euler: .zero, scale: .zero)
        var accumulated = [Pose](repeating: zeroPose, count: count)
        var weights = [Float](repeating: 0, count: count)
        for layer in layers {
            guard layer.animation >= 0, layer.animation < animations.count else { continue }
            let weight = layer.blend
            guard weight.isFinite, weight > 0 else { continue }
            let animation = animations[layer.animation]
            guard let sample = frameSample(animation, time: time, rate: layer.rate) else { continue }
            let trackCount = min(count, animation.tracks.count)
            for bone in 0..<trackCount {
                let track = animation.tracks[bone]
                guard !track.isEmpty else { continue }
                let a = track[min(sample.frame0, track.count - 1)]
                let b = track[min(sample.frame1, track.count - 1)]
                let t = sample.blend
                accumulated[bone].position += weight * mix(a.position, b.position, t: t)
                accumulated[bone].euler += weight * mix(a.euler, b.euler, t: t)
                accumulated[bone].scale += weight * mix(a.scale, b.scale, t: t)
                weights[bone] += weight
            }
        }

        for bone in 0..<count where weights[bone] > 0 {
            let inverseWeight = 1 / weights[bone]
            let pose = Pose(position: accumulated[bone].position * inverseWeight,
                            euler: accumulated[bone].euler * inverseWeight,
                            scale: accumulated[bone].scale * inverseWeight)
            locals[bone] = pose.matrix
        }

        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: count)
        var result = [simd_float4x4](repeating: matrix_identity_float4x4, count: count)
        for bone in 0..<count {
            if let parent = bones[bone].parent, parent < bone {
                world[bone] = world[parent] * locals[bone]
            } else {
                world[bone] = locals[bone]
            }
            result[bone] = sanitized(world[bone] * safeInverse(bones[bone].bindTransform))
        }
        return result
    }
}

/// A bone's local transform in the form the animation tracks store it.
private struct Pose {
    var position = SIMD3<Float>(repeating: 0)
    var euler = SIMD3<Float>(repeating: 0)
    var scale = SIMD3<Float>(repeating: 1)

    /// `T(position) * Rz * Ry * Rx * S(scale)`, the order Wallpaper Engine uses
    /// everywhere else (see the particle model matrix in the renderer notes).
    var matrix: simd_float4x4 {
        let (sx, cx) = (sin(euler.x), cos(euler.x))
        let (sy, cy) = (sin(euler.y), cos(euler.y))
        let (sz, cz) = (sin(euler.z), cos(euler.z))
        let rx = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                        SIMD4<Float>(0, cx, sx, 0),
                                        SIMD4<Float>(0, -sx, cx, 0),
                                        SIMD4<Float>(0, 0, 0, 1)))
        let ry = simd_float4x4(columns: (SIMD4<Float>(cy, 0, -sy, 0),
                                        SIMD4<Float>(0, 1, 0, 0),
                                        SIMD4<Float>(sy, 0, cy, 0),
                                        SIMD4<Float>(0, 0, 0, 1)))
        let rz = simd_float4x4(columns: (SIMD4<Float>(cz, sz, 0, 0),
                                        SIMD4<Float>(-sz, cz, 0, 0),
                                        SIMD4<Float>(0, 0, 1, 0),
                                        SIMD4<Float>(0, 0, 0, 1)))
        let s = simd_float4x4(diagonal: SIMD4<Float>(scale.x, scale.y, scale.z, 1))
        var m = rz * ry * rx * s
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }
}

private struct FrameSample {
    let frame0: Int
    let frame1: Int
    let blend: Float
}

/// Frame lookup for one animation: `fmod(time * rate, length / fps)` with
/// linear interpolation, `mirror` ping-ponging over twice that span and
/// `single` holding the last frame once it is past the end.
private func frameSample(_ animation: PuppetAnimation, time: Double, rate: Float) -> FrameSample? {
    let length = animation.frameCount > 0
        ? animation.frameCount
        : (animation.tracks.map(\.count).max() ?? 0)
    guard length > 0 else { return nil }
    guard animation.fps.isFinite, animation.fps > 0, rate.isFinite, time.isFinite else { return nil }
    let fps = Double(animation.fps)
    let duration = Double(length) / fps
    guard duration.isFinite, duration > 0 else { return nil }
    let elapsed = time * Double(rate)
    guard elapsed.isFinite else { return nil }

    var position: Double
    let wraps: Bool
    switch animation.mode {
    case .loop:
        position = elapsed.truncatingRemainder(dividingBy: duration)
        if position < 0 { position += duration }
        wraps = true
    case .mirror:
        // A ping-pong reverses on the last stored frame, not one frame past it,
        // otherwise the pose dwells at each end for a frame before turning.
        let half = length > 1 ? Double(length - 1) / fps : duration
        let span = half * 2
        var p = elapsed.truncatingRemainder(dividingBy: span)
        if p < 0 { p += span }
        if p > half { p = span - p }
        position = p
        wraps = false
    case .single:
        position = min(max(elapsed, 0), duration)
        wraps = false
    }

    var frame = position * fps
    guard frame.isFinite else { return nil }
    frame = min(max(frame, 0), Double(length))
    var index0 = Int(frame.rounded(.down))
    let blend = Float(frame - Double(index0))
    if index0 > length - 1 { index0 = length - 1 }
    let index1 = wraps ? (index0 + 1) % length : min(index0 + 1, length - 1)
    return FrameSample(frame0: index0, frame1: index1, blend: min(max(blend, 0), 1))
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

/// Bind transforms come from a file and may be singular; falling back to the
/// identity keeps the skinning matrix finite instead of poisoning the mesh.
private func safeInverse(_ m: simd_float4x4) -> simd_float4x4 {
    let determinant = m.determinant
    guard determinant.isFinite, abs(determinant) > 1e-12 else { return matrix_identity_float4x4 }
    return sanitized(m.inverse)
}

private func sanitized(_ m: simd_float4x4) -> simd_float4x4 {
    for column in 0..<4 {
        let c = m[column]
        if !(c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite) {
            return matrix_identity_float4x4
        }
    }
    return m
}

private func finite(_ v: SIMD3<Float>, default fallback: SIMD3<Float>) -> SIMD3<Float> {
    (v.x.isFinite && v.y.isFinite && v.z.isFinite) ? v : fallback
}

// MARK: - Parsing

/// Cursor over the raw file bytes. Every accessor returns `nil` rather than
/// reading past the end, so the parser never has to trust a length field.
private struct Cursor {
    let data: Data
    var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { max(0, data.count - offset) }

    @discardableResult
    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, count <= remaining else { return false }
        offset += count
        return true
    }

    mutating func seek(_ target: Int) -> Bool {
        guard target >= 0, target <= data.count else { return false }
        offset = target
        return true
    }

    mutating func u32() -> UInt32? {
        guard 4 <= remaining else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func u16() -> UInt16? {
        guard 2 <= remaining else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        offset += 2
        return UInt16(littleEndian: value)
    }

    mutating func i32() -> Int32? {
        guard let value = u32() else { return nil }
        return Int32(bitPattern: value)
    }

    mutating func f32() -> Float? {
        guard let value = u32() else { return nil }
        return Float(bitPattern: value)
    }

    mutating func float3() -> SIMD3<Float>? {
        guard let x = f32(), let y = f32(), let z = f32() else { return nil }
        return SIMD3<Float>(x, y, z)
    }

    /// Length-prefixed string, the only string form in the body of the file.
    /// A NUL-terminated string.
    ///
    /// Unlike `scene.pkg`, which length-prefixes its names, `.mdl` writes plain
    /// C strings: the material path sits at byte 21 as `materials/arm.json\0`.
    /// Reading a length word here consumes the first four characters as a size
    /// and the whole file fails to parse.
    mutating func sizedString() -> String? {
        let start = data.startIndex + offset
        var end = start
        let limit = min(data.endIndex, start + PuppetReader.maximumStringByteCount)
        while end < limit, data[end] != 0 { end = data.index(after: end) }
        guard end < limit, data[end] == 0 else { return nil }
        let text = String(decoding: data[start..<end], as: UTF8.self)
        offset += data.distance(from: start, to: end) + 1
        return text
    }

    /// Nine byte section tag, e.g. `"MDLS0001\0"`.
    mutating func tag() -> String? {
        guard 9 <= remaining else { return nil }
        let start = data.startIndex + offset
        let field = data[start..<(start + 9)]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        offset += 9
        return String(decoding: field[field.startIndex..<end], as: UTF8.self)
    }

    mutating func peekTag() -> String? {
        let saved = offset
        let value = tag()
        offset = saved
        return value
    }

    /// Finds the next section whose tag starts with `prefix`, positioning the
    /// cursor after the tag. Used because the optional blocks between sections
    /// are the least certain part of the format: a misread there costs the
    /// animations rather than the whole model.
    mutating func findTag(prefix: String) -> String? {
        let needle = Array(prefix.utf8)
        guard !needle.isEmpty, needle.count <= 9 else { return nil }
        let base = data.startIndex + offset
        let limit = remaining - 9
        guard limit >= 0 else { return nil }
        var i = 0
        while i <= limit {
            var matched = 0
            while matched < needle.count, data[base + i + matched] == needle[matched] {
                matched += 1
            }
            if matched == needle.count {
                offset += i
                return tag()
            }
            i += 1
        }
        return nil
    }
}

private enum PuppetReader {
    static let maximumStringByteCount = 1 << 20
    /// A puppet with more frames than this is not a puppet, it is a decompression bomb.
    static let maximumFrameCount = 1 << 20
    static let maximumHeraldScan = 4096
    static let standardHerald: UInt32 = 0x0180_0009
    static let alternateHerald: UInt32 = 0x0180_000F

    enum VertexLayout {
        case standard
        case alternate

        var stride: Int { self == .standard ? 52 : 80 }
    }

    static func parse(_ data: Data) -> PuppetModel? {
        var c = Cursor(data)
        guard let magic = c.tag(), magic.hasPrefix("MDLV") else { return nil }
        // Flag 9 marks a puppet the editor never finished rigging; there is
        // nothing skinnable in the file even though the mesh section parses.
        guard let flag = c.i32(), flag != 9 else { return nil }
        guard c.skip(8) else { return nil }                 // two i32, both 1 in every file seen
        guard let materialPath = c.sizedString() else { return nil }
        guard c.skip(4) else { return nil }                 // i32 0
        guard let layout = vertexLayout(&c) else { return nil }
        guard let rawVertices = vertices(&c, layout: layout) else { return nil }
        guard let rawIndices = indices(&c) else { return nil }
        guard let bones = bones(&c) else { return nil }

        // Bad indices would make Metal read outside the vertex buffer, so drop
        // any triangle that does not address a vertex this file actually has.
        var triangles: [UInt16] = []
        triangles.reserveCapacity(rawIndices.count)
        let vertexCount = rawVertices.count
        var i = 0
        while i + 2 < rawIndices.count {
            let a = rawIndices[i], b = rawIndices[i + 1], d = rawIndices[i + 2]
            if Int(a) < vertexCount, Int(b) < vertexCount, Int(d) < vertexCount {
                triangles.append(a); triangles.append(b); triangles.append(d)
            }
            i += 3
        }

        // Clamp blend indices now: the vertex shader uses them to index
        // `g_Bones[]` directly and a stale index there reads past the buffer.
        let boneLimit = bones.isEmpty ? 0 : UInt32(bones.count - 1)
        let clamped = SIMD4<UInt32>(repeating: boneLimit)
        let mesh = rawVertices.map { v in
            PuppetVertex(position: v.position,
                         blendIndices: simd_min(v.blendIndices, clamped),
                         blendWeights: v.blendWeights,
                         uv: v.uv)
        }

        // Optional data sections sit between the bones and the animations.
        let afterBones = c.offset
        while let next = c.peekTag(), next.hasPrefix("MDAT") {
            guard skipDataSection(&c) else { break }
        }
        var animations: [PuppetAnimation] = []
        var animationTag = c.findTag(prefix: "MDLA")
        if animationTag == nil, c.seek(afterBones) {
            animationTag = c.findTag(prefix: "MDLA")
        }
        if let tag = animationTag {
            animations = self.animations(&c, tag: tag, layout: layout)
        }

        return PuppetModel(materialPath: materialPath, vertices: mesh, indices: triangles,
                           bones: bones, animations: animations)
    }

    /// The herald word picks the vertex stride. Files that do not open with the
    /// standard value carry a run of unknown words before the alternate one.
    private static func vertexLayout(_ c: inout Cursor) -> VertexLayout? {
        guard var value = c.u32() else { return nil }
        if value == standardHerald { return .standard }
        var scanned = 0
        while value != alternateHerald {
            guard scanned < maximumHeraldScan, let next = c.u32() else { return nil }
            value = next
            scanned += 1
        }
        return .alternate
    }

    private static func vertices(_ c: inout Cursor, layout: VertexLayout) -> [PuppetVertex]? {
        guard let raw = c.u32() else { return nil }
        let byteCount = Int(raw)
        guard byteCount <= c.remaining else { return nil }
        let stride = layout.stride
        let count = byteCount / stride
        let start = c.offset
        var result: [PuppetVertex] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard c.seek(start + index * stride) else { return nil }
            guard let position = c.float3() else { return nil }
            // The alternate layout pads the slot after the position with seven
            // words no reimplementation has identified.
            if layout == .alternate, !c.skip(28) { return nil }
            guard let i0 = c.u32(), let i1 = c.u32(), let i2 = c.u32(), let i3 = c.u32(),
                  let w0 = c.f32(), let w1 = c.f32(), let w2 = c.f32(), let w3 = c.f32(),
                  let u = c.f32(), let v = c.f32() else { return nil }
            let weights = SIMD4<Float>(w0, w1, w2, w3)
            let uv = SIMD2<Float>(u, v)
            result.append(PuppetVertex(
                position: finite(position, default: SIMD3<Float>(repeating: 0)),
                blendIndices: SIMD4<UInt32>(i0, i1, i2, i3),
                blendWeights: weights.replacing(with: SIMD4<Float>(repeating: 0),
                                                where: .!(weights .== weights)),
                uv: (u.isFinite && v.isFinite) ? uv : SIMD2<Float>(repeating: 0)))
        }
        guard c.seek(start + byteCount) else { return nil }
        return result
    }

    private static func indices(_ c: inout Cursor) -> [UInt16]? {
        guard let raw = c.u32() else { return nil }
        let byteCount = Int(raw)
        guard byteCount <= c.remaining else { return nil }
        let start = c.offset
        var result: [UInt16] = []
        result.reserveCapacity(byteCount / 2)
        for _ in 0..<(byteCount / 2) {
            guard let value = c.u16() else { return nil }
            result.append(value)
        }
        guard c.seek(start + byteCount) else { return nil }
        return result
    }

    private static func bones(_ c: inout Cursor) -> [PuppetBone]? {
        guard let tag = c.findTag(prefix: "MDLS") else { return nil }
        guard c.skip(4) else { return nil }                 // section end offset
        guard let rawCount = c.u16(), c.skip(2) else { return nil }
        let count = Int(rawCount)
        // Smallest possible bone: two empty strings, three words and the matrix.
        guard count <= c.remaining / 84 else { return nil }

        var result: [PuppetBone] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let name = c.sizedString() else { return nil }
            guard c.skip(4) else { return nil }             // unused i32
            guard let parentRaw = c.u32(), let sizeRaw = c.u32() else { return nil }
            var bind = matrix_identity_float4x4
            if sizeRaw == 64 {
                var values = [Float](repeating: 0, count: 16)
                for i in 0..<16 {
                    guard let value = c.f32() else { return nil }
                    values[i] = value.isFinite ? value : (i % 5 == 0 ? 1 : 0)
                }
                bind = simd_float4x4(columns: (SIMD4<Float>(values[0], values[1], values[2], values[3]),
                                               SIMD4<Float>(values[4], values[5], values[6], values[7]),
                                               SIMD4<Float>(values[8], values[9], values[10], values[11]),
                                               SIMD4<Float>(values[12], values[13], values[14], values[15])))
            } else {
                guard c.skip(Int(sizeRaw)) else { return nil }
            }
            guard c.sizedString() != nil else { return nil } // simulation json, unused
            // Parents always precede their children here. Anything else would
            // let the hierarchy walk loop, so treat it as a root instead.
            let parent = (parentRaw != 0xFFFF_FFFF && Int(parentRaw) < index) ? Int(parentRaw) : nil
            result.append(PuppetBone(name: name, parent: parent, bindTransform: bind))
        }

        if (trailingVersion(tag) ?? 1) > 1 {
            skipSkinningExtras(&c, boneCount: count)
        }
        return result
    }

    /// Post-bone blocks in MDLS versions above 1. Nothing here is used yet, and
    /// a failure only costs the animations, so it reports nothing.
    private static func skipSkinningExtras(_ c: inout Cursor, boneCount: Int) {
        guard c.skip(2) else { return }                     // i16 0
        guard let hasTransforms = c.u8() else { return }
        if hasTransforms != 0, !c.skip(boneCount * 64) { return }
        guard let groupCount = c.u32(), Int(groupCount) <= c.remaining / 12 else { return }
        guard c.skip(Int(groupCount) * 12) else { return }
        guard c.skip(4) else { return }
        guard let hasOffsets = c.u8() else { return }
        if hasOffsets != 0, !c.skip(boneCount * 76) { return }
        guard let hasIndices = c.u8() else { return }
        if hasIndices != 0, !c.skip(boneCount * 4) { return }
    }

    private static func skipDataSection(_ c: inout Cursor) -> Bool {
        guard c.tag() != nil, c.skip(4) else { return false }
        guard let rawCount = c.u16() else { return false }
        let count = Int(rawCount)
        guard count <= c.remaining / 70 else { return false }
        for _ in 0..<count {
            guard c.skip(2), c.sizedString() != nil, c.skip(64) else { return false }
        }
        return true
    }

    private static func animations(_ c: inout Cursor, tag: String,
                                   layout: VertexLayout) -> [PuppetAnimation] {
        guard c.skip(4) else { return [] }                  // section end offset
        guard let rawCount = c.u32() else { return [] }
        let count = Int(rawCount)
        guard count <= c.remaining / 24 else { return [] }
        let version = trailingVersion(tag) ?? 1
        var result: [PuppetAnimation] = []
        result.reserveCapacity(min(count, 64))
        for _ in 0..<count {
            guard let animation = animation(&c, version: version, layout: layout) else { break }
            result.append(animation)
        }
        return result
    }

    private static func animation(_ c: inout Cursor, version: Int,
                                  layout: VertexLayout) -> PuppetAnimation? {
        // The id is preceded by a variable run of zero words.
        var idValue: UInt32 = 0
        var attempts = 0
        repeat {
            guard let value = c.u32() else { return nil }
            idValue = value
            attempts += 1
        } while idValue == 0 && attempts < 16
        guard c.skip(4) else { return nil }
        guard let name = c.sizedString(), let modeText = c.sizedString() else { return nil }
        guard var fps = c.f32(), let length = c.i32(), c.skip(4) else { return nil }
        if !fps.isFinite || fps <= 0 { fps = 30 }
        let frameCount = max(0, min(Int(length), maximumFrameCount))
        guard let rawTrackCount = c.u32(), Int(rawTrackCount) <= c.remaining / 8 else { return nil }

        var tracks: [[(position: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>)]] = []
        tracks.reserveCapacity(Int(rawTrackCount))
        for _ in 0..<Int(rawTrackCount) {
            guard c.skip(4) else { return nil }             // bone id, tracks are in bone order
            guard let rawBytes = c.u32() else { return nil }
            let byteCount = Int(rawBytes)
            guard byteCount <= c.remaining else { return nil }
            let start = c.offset
            var frames: [(position: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>)] = []
            frames.reserveCapacity(min(byteCount / 36, 4096))
            for _ in 0..<(byteCount / 36) {
                guard let position = c.float3(), let euler = c.float3(),
                      let scale = c.float3() else { return nil }
                frames.append((position: finite(position, default: SIMD3<Float>(repeating: 0)),
                               euler: finite(euler, default: SIMD3<Float>(repeating: 0)),
                               scale: finite(scale, default: SIMD3<Float>(repeating: 1))))
            }
            guard c.seek(start + byteCount) else { return nil }
            tracks.append(frames)
        }

        // Trailer shape depends on the vertex layout and the section version.
        if layout == .alternate {
            guard c.skip(2) else { return nil }
        } else if version >= 3 {
            // u32 event count, then a flag saying whether per-bone alpha curves
            // follow, and if so one curve per track: a bone id, a byte count and
            // that many bytes, one float per frame. Skipping a single byte here
            // leaves the cursor inside the count and every later animation in
            // the file is read as garbage.
            guard let rawEvents = c.u32(), Int(rawEvents) <= c.remaining / 8 else { return nil }
            for _ in 0..<Int(rawEvents) {
                guard c.skip(4), c.sizedString() != nil else { return nil }
            }
            guard let hasBoneAlpha = c.u8() else { return nil }
            if hasBoneAlpha != 0 {
                for _ in 0..<tracks.count {
                    guard c.skip(4), let byteCount = c.u32(),
                          Int(byteCount) <= c.remaining, c.skip(Int(byteCount)) else { return nil }
                }
            }
        } else {
            guard let rawEvents = c.u32(), Int(rawEvents) <= c.remaining / 8 else { return nil }
            for _ in 0..<Int(rawEvents) {
                guard c.skip(4), c.sizedString() != nil else { return nil }
            }
        }

        return PuppetAnimation(id: Int(Int32(bitPattern: idValue)), name: name,
                               mode: mode(modeText), fps: fps, frameCount: frameCount,
                               tracks: tracks)
    }

    private static func mode(_ text: String) -> PuppetAnimation.Mode {
        switch text.lowercased() {
        case "mirror": return .mirror
        case "single": return .single
        default: return .loop
        }
    }

    /// `"MDLS0002"` -> `2`. Sections carry their version in the tag itself.
    private static func trailingVersion(_ tag: String) -> Int? {
        let digits = tag.suffix(while: { $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }
}

private extension Cursor {
    mutating func u8() -> UInt8? {
        guard 1 <= remaining else { return nil }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }
}

private extension String {
    /// Trailing run matching `predicate`, used to pull a version out of a tag.
    func suffix(while predicate: (Character) -> Bool) -> String {
        var result = ""
        for character in reversed() {
            guard predicate(character) else { break }
            result.insert(character, at: result.startIndex)
        }
        return result
    }
}
