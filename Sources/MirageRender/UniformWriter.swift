import Foundation
import simd
import WEKit

/// A value bound to a shader uniform.
public enum ShaderValue {
    case scalar(Float)
    case vec2(SIMD2<Float>)
    case vec3(SIMD3<Float>)
    case vec4(SIMD4<Float>)
    case mat3(simd_float3x3)
    case mat4(simd_float4x4)
    case integer(Int32)
    case boolean(Bool)
    case floatArray([Float])
    case vec4Array([SIMD4<Float>])
    case vec3Array([SIMD3<Float>])
    /// A bone palette. Each matrix contributes its four columns, three floats
    /// each, which is exactly how a `mat4x3` array is laid out.
    case mat4x3Array([simd_float4x4])

    /// Component values of one element (used for scalars, vectors and array elements).
    var components: [Float] {
        switch self {
        case .scalar(let f): return [f]
        case .vec2(let v): return [v.x, v.y]
        case .vec3(let v): return [v.x, v.y, v.z]
        case .vec4(let v): return [v.x, v.y, v.z, v.w]
        case .integer(let i): return [Float(i)]
        case .boolean(let b): return [b ? 1 : 0]
        case .mat3(let m): return (0..<3).flatMap { c in [m[c].x, m[c].y, m[c].z] }
        case .mat4(let m): return (0..<4).flatMap { c in [m[c].x, m[c].y, m[c].z, m[c].w] }
        case .floatArray(let a): return a
        case .vec4Array(let a): return a.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        case .vec3Array(let a): return a.flatMap { [$0.x, $0.y, $0.z] }
        case .mat4x3Array(let a): return a.flatMap { m in (0..<4).flatMap { [m[$0].x, m[$0].y, m[$0].z] } }
        }
    }

    /// Per-element component vectors for array-valued uniforms.
    var elements: [[Float]] {
        switch self {
        case .floatArray(let a): return a.map { [$0] }
        case .vec4Array(let a): return a.map { [$0.x, $0.y, $0.z, $0.w] }
        case .vec3Array(let a): return a.map { [$0.x, $0.y, $0.z] }
        case .mat3(let m): return (0..<3).map { [m[$0].x, m[$0].y, m[$0].z] }
        case .mat4(let m): return (0..<4).map { [m[$0].x, m[$0].y, m[$0].z, m[$0].w] }
        case .mat4x3Array(let a): return a.flatMap { m in (0..<4).map { [m[$0].x, m[$0].y, m[$0].z] } }
        default: return [components]
        }
    }

    /// Interpret a Wallpaper Engine JSON constant (number, bool, "1 0.5 0" string).
    public init?(json: JSON) {
        switch json {
        case .number(let n): self = .scalar(Float(n))
        case .bool(let b): self = .boolean(b)
        case .string:
            guard let f = json.floats else { return nil }
            switch f.count {
            case 1: self = .scalar(f[0])
            case 2: self = .vec2(SIMD2(f[0], f[1]))
            case 3: self = .vec3(SIMD3(f[0], f[1], f[2]))
            default: self = .vec4(SIMD4(f[0], f[1], f[2], f[3]))
            }
        case .array:
            guard let f = json.floats else { return nil }
            switch f.count {
            case 1: self = .scalar(f[0])
            case 2: self = .vec2(SIMD2(f[0], f[1]))
            case 3: self = .vec3(SIMD3(f[0], f[1], f[2]))
            case 4: self = .vec4(SIMD4(f[0], f[1], f[2], f[3]))
            default: self = .floatArray(f)
            }
        default: return nil
        }
    }
}

/// Named shader values for one draw.
public struct ShaderValueBag {
    public private(set) var values: [String: ShaderValue] = [:]

    public init() {}

    public subscript(name: String) -> ShaderValue? {
        get { values[name] }
        set { values[name] = newValue }
    }

    public mutating func set(_ name: String, _ value: ShaderValue) { values[name] = value }
    public mutating func set(_ name: String, _ value: Float) { values[name] = .scalar(value) }
    public mutating func set(_ name: String, _ value: SIMD2<Float>) { values[name] = .vec2(value) }
    public mutating func set(_ name: String, _ value: SIMD3<Float>) { values[name] = .vec3(value) }
    public mutating func set(_ name: String, _ value: SIMD4<Float>) { values[name] = .vec4(value) }
    public mutating func set(_ name: String, _ value: simd_float4x4) { values[name] = .mat4(value) }
    public mutating func set(_ name: String, _ value: simd_float3x3) { values[name] = .mat3(value) }

    public mutating func merge(_ other: ShaderValueBag) {
        for (k, v) in other.values { values[k] = v }
    }

    public mutating func setIfAbsent(_ name: String, _ value: ShaderValue) {
        if values[name] == nil { values[name] = value }
    }
}

/// Fills a Metal constant buffer from SPIRV-Cross reflection of the default
/// uniform block. Offsets, array strides and matrix strides all come from the
/// reflection, so the layout always matches the generated MSL struct.
public struct UniformWriter {
    // Metal's setVertexBytes/setFragmentBytes inline-data limit is 4 KiB.
    static let maximumByteCount = 4 * 1024
    public let block: ShaderCompiler.UniformBlock
    /// Uniform name → member, precomputed.
    private let members: [String: ShaderCompiler.UniformMember]

    public init(block: ShaderCompiler.UniformBlock) {
        self.block = block
        var map: [String: ShaderCompiler.UniformMember] = [:]
        for m in block.members { map[m.name] = m }
        self.members = map
    }

    public var byteCount: Int {
        guard block.size > 0 else { return 16 }
        let bounded = min(block.size, UniformWriter.maximumByteCount)
        return (bounded + 15) & ~15
    }

    public func contains(_ name: String) -> Bool { members[name] != nil }
    public var memberNames: [String] { block.members.map(\.name) }

    /// Writes every member it can find a value for. Members without a value keep
    /// whatever the buffer already held (callers zero it first).
    public func write(_ bag: ShaderValueBag, into buffer: inout [UInt8]) {
        if buffer.count < byteCount { buffer.append(contentsOf: [UInt8](repeating: 0, count: byteCount - buffer.count)) }
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for member in block.members {
                guard let value = bag.values[member.name] else { continue }
                write(value, member: member, base: base, capacity: raw.count)
            }
        }
    }

    private func write(_ value: ShaderValue, member: ShaderCompiler.UniformMember,
                       base: UnsafeMutableRawPointer, capacity: Int) {
        let columns = max(1, member.columns)
        let count = max(1, member.vecSize)
        let arrayLength = member.arrayLength
        let elements = value.elements
        guard (1...4).contains(columns), (1...4).contains(count), arrayLength >= 0,
              arrayLength <= capacity / 4 + 1 else { return }

        func advanced(_ offset: Int, _ index: Int, _ stride: Int) -> Int? {
            guard offset >= 0, index >= 0, stride >= 0 else { return nil }
            let (delta, multiplyOverflow) = index.multipliedReportingOverflow(by: stride)
            let (result, addOverflow) = offset.addingReportingOverflow(delta)
            return multiplyOverflow || addOverflow ? nil : result
        }

        func int32(_ value: Float) -> Int32 {
            guard value.isFinite else { return 0 }
            let value = Double(value)
            if value >= Double(Int32.max) { return Int32.max }
            if value <= Double(Int32.min) { return Int32.min }
            return Int32(value.rounded(.towardZero))
        }

        func uint32(_ value: Float) -> UInt32 {
            guard value.isFinite, value > 0 else { return 0 }
            let value = Double(value)
            if value >= Double(UInt32.max) { return UInt32.max }
            return UInt32(value.rounded(.towardZero))
        }

        func store(_ floats: [Float], at offset: Int) {
            guard offset >= 0 else { return }
            let (byteWidth, widthOverflow) = count.multipliedReportingOverflow(by: 4)
            let (needed, endOverflow) = offset.addingReportingOverflow(byteWidth)
            guard !widthOverflow, !endOverflow, needed <= capacity else { return }
            func copy<T>(_ value: T, to scalarOffset: Int) {
                var value = value
                withUnsafeBytes(of: &value) { source in
                    guard source.count == 4, let sourceBase = source.baseAddress else { return }
                    base.advanced(by: scalarOffset).copyMemory(from: sourceBase, byteCount: source.count)
                }
            }
            switch member.baseType {
            case "int":
                for i in 0..<count {
                    let v = int32(i < floats.count ? floats[i] : 0)
                    copy(v, to: offset + i * 4)
                }
            case "uint":
                for i in 0..<count {
                    let f = i < floats.count ? floats[i] : 0
                    copy(uint32(f), to: offset + i * 4)
                }
            case "bool":
                // MSL lowers bool members to uint-sized fields inside constant buffers.
                for i in 0..<count {
                    let f = i < floats.count ? floats[i] : 0
                    copy(UInt32(f.isFinite && f != 0 ? 1 : 0), to: offset + i * 4)
                }
            default:
                // A single supplied component broadcasts (matches GLSL's CAST3(x) idiom).
                let broadcast = floats.count == 1 && count > 1
                for i in 0..<count {
                    let f = broadcast ? floats[0] : (i < floats.count ? floats[i] : 0)
                    copy(f, to: offset + i * 4)
                }
            }
        }

        if arrayLength > 0 {
            let stride = member.arrayStride > 0 ? member.arrayStride : count * 4
            if columns > 1 {
                // Array of matrices: element stride covers all columns.
                let matStride = member.matrixStride > 0 ? member.matrixStride : count * 4
                for e in 0..<arrayLength {
                    for c in 0..<columns {
                        let index = e * columns + c
                        let floats = index < elements.count ? elements[index] : []
                        guard let elementOffset = advanced(member.offset, e, stride),
                              let columnOffset = advanced(elementOffset, c, matStride) else { continue }
                        store(floats, at: columnOffset)
                    }
                }
            } else {
                for e in 0..<arrayLength {
                    let floats = e < elements.count ? elements[e] : (elements.count == 1 ? elements[0] : [])
                    guard let elementOffset = advanced(member.offset, e, stride) else { continue }
                    store(floats, at: elementOffset)
                }
            }
        } else if columns > 1 {
            let matStride = member.matrixStride > 0 ? member.matrixStride : count * 4
            for c in 0..<columns {
                let floats = c < elements.count ? elements[c] : []
                guard let columnOffset = advanced(member.offset, c, matStride) else { continue }
                store(floats, at: columnOffset)
            }
        } else {
            store(value.components, at: member.offset)
        }
    }
}

// MARK: - Matrix helpers

public enum Mat {
    public static let identity = matrix_identity_float4x4

    /// Right-handed orthographic projection with **Metal's** clip-space depth range.
    ///
    /// `glOrtho` maps z into `[-1, 1]`; Metal (like Vulkan) clips to `[0, 1]`, so an
    /// OpenGL-style matrix sends Wallpaper Engine's z = 0 geometry to ≈ -1 and the
    /// rasteriser discards every triangle. All WE quads are flat at z = 0 and depth
    /// testing is disabled, so callers pass `near: -1, far: 1`, putting them at 0.5.
    public static func ortho(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        let rl = right - left, tb = top - bottom, fn = far - near
        guard rl != 0, tb != 0, fn != 0 else { return identity }
        return simd_float4x4(columns: (
            SIMD4(2 / rl, 0, 0, 0),
            SIMD4(0, 2 / tb, 0, 0),
            SIMD4(0, 0, -1 / fn, 0),
            SIMD4(-(right + left) / rl, -(top + bottom) / tb, -near / fn, 1)
        ))
    }

    public static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = identity
        m.columns.3 = SIMD4(x, y, z, 1)
        return m
    }

    public static func scale(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(x, y, z, 1))
    }

    public static func rotationZ(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians), s = sin(radians)
        return simd_float4x4(columns: (
            SIMD4(c, s, 0, 0),
            SIMD4(-s, c, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    public static func rotation(_ angles: SIMD3<Float>) -> simd_float4x4 {
        let cx = cos(angles.x), sx = sin(angles.x)
        let cy = cos(angles.y), sy = sin(angles.y)
        let cz = cos(angles.z), sz = sin(angles.z)
        let rx = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cx, sx, 0), SIMD4(0, -sx, cx, 0), SIMD4(0, 0, 0, 1)))
        let ry = simd_float4x4(columns: (SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0), SIMD4(sy, 0, cy, 0), SIMD4(0, 0, 0, 1)))
        let rz = simd_float4x4(columns: (SIMD4(cz, sz, 0, 0), SIMD4(-sz, cz, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        return rz * ry * rx
    }

    public static func upperLeft3x3(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
    }
}
