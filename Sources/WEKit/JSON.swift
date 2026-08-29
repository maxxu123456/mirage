import Foundation
import simd

public enum JSONParseError: Error, CustomStringConvertible {
    case documentTooLarge(Int)
    case nestingTooDeep

    public var description: String {
        switch self {
        case .documentTooLarge(let count): return "JSON document is too large (\(count) bytes)"
        case .nestingTooDeep: return "JSON document is nested too deeply"
        }
    }
}

/// A small dynamic JSON value used for Wallpaper Engine's loosely typed files.
/// WE stores vectors/colours as strings such as `"1.0 0.5 0.25"`, numbers as
/// either numbers or numeric strings, and many properties may be replaced by a
/// binding object (`{"user": "name", "value": ...}`), so a dynamic tree is much
/// more convenient than Codable.
public enum JSON: Equatable, CustomStringConvertible {
    static let maximumDocumentByteCount = 16 * 1024 * 1024
    static let maximumNestingDepth = 128
    private static let maximumNumericComponentCount = 4096

    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> JSON {
        guard data.count <= maximumDocumentByteCount else {
            throw JSONParseError.documentTooLarge(data.count)
        }
        guard nestingIsBounded(data) else { throw JSONParseError.nestingTooDeep }
        do {
            let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return JSON(any: any)
        } catch {
            // Some workshop files contain comments or trailing commas; retry leniently.
            if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                let cleaned = JSON.stripCommentsAndTrailingCommas(text)
                if let cleanedData = cleaned.data(using: .utf8),
                   let any = try? JSONSerialization.jsonObject(with: cleanedData, options: [.fragmentsAllowed]) {
                    return JSON(any: any)
                }
            }
            throw error
        }
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    private static func nestingIsBounded(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var depth = 0
            var index = 0
            var inString = false
            var escaped = false
            var inLineComment = false
            var inBlockComment = false
            while index < bytes.count {
                let byte = bytes[index]
                let next = index + 1 < bytes.count ? bytes[index + 1] : 0
                if inLineComment {
                    if byte == 0x0A || byte == 0x0D { inLineComment = false }
                } else if inBlockComment {
                    if byte == 0x2A, next == 0x2F { inBlockComment = false; index += 1 }
                } else if inString {
                    if escaped { escaped = false }
                    else if byte == 0x5C { escaped = true }
                    else if byte == 0x22 { inString = false }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x2F, next == 0x2F {
                    inLineComment = true
                    index += 1
                } else if byte == 0x2F, next == 0x2A {
                    inBlockComment = true
                    index += 1
                } else if byte == 0x7B || byte == 0x5B {
                    depth += 1
                    if depth > maximumNestingDepth { return false }
                } else if byte == 0x7D || byte == 0x5D {
                    depth = max(0, depth - 1)
                }
                index += 1
            }
            return true
        }
    }

    public init(any: Any) {
        self.init(any: any, depth: 0)
    }

    private init(any: Any, depth: Int) {
        guard depth < JSON.maximumNestingDepth else {
            self = .null
            return
        }
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSON(any: $0, depth: depth + 1) })
        case let d as [String: Any]:
            var out: [String: JSON] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d { out[k] = JSON(any: v, depth: depth + 1) }
            self = .object(out)
        default:
            self = .null
        }
    }

    /// Remove `//` and `/* */` comments outside of strings plus trailing commas.
    static func stripCommentsAndTrailingCommas(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var chars = Array(text.unicodeScalars)
        var i = 0
        var inString = false
        var escaped = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.unicodeScalars.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.unicodeScalars.append(c); i += 1; continue }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.unicodeScalars.append(c)
            i += 1
        }
        chars = Array(out.unicodeScalars)
        // trailing commas: `,` followed by whitespace then `}` or `]`
        var result = ""
        result.unicodeScalars.reserveCapacity(chars.count)
        i = 0
        inString = false
        escaped = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                result.unicodeScalars.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; result.unicodeScalars.append(c); i += 1; continue }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\r" || chars[j] == "\t" { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            result.unicodeScalars.append(c)
            i += 1
        }
        return result
    }

    // MARK: Accessors

    public subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var exists: Bool { !isNull }

    public var object: [String: JSON]? { if case .object(let o) = self { return o } else { return nil } }
    public var array: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
    public var string: String? { if case .string(let s) = self { return s } else { return nil } }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var float: Float? {
        guard let value = double, value.isFinite else { return nil }
        let result = Float(value)
        return result.isFinite ? result : nil
    }

    public var int: Int? {
        guard let value = double, value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    public static func numberString(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), let integer = Int64(exactly: value) {
            return String(integer)
        }
        return value.description
    }

    /// Numbers from a string like "1 0.5 0.25", from a single number, or an array.
    public var floats: [Float]? {
        switch self {
        case .number: return float.map { [$0] }
        case .bool(let b): return [b ? 1 : 0]
        case .string(let s):
            let parts = s.split(maxSplits: JSON.maximumNumericComponentCount,
                                whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
            guard parts.count <= JSON.maximumNumericComponentCount else { return nil }
            let values = parts.compactMap { part -> Float? in
                guard let value = Float(part), value.isFinite else { return nil }
                return value
            }
            return values.isEmpty ? nil : values
        case .array(let a):
            guard a.count <= JSON.maximumNumericComponentCount else { return nil }
            let values = a.compactMap { $0.float }
            return values.isEmpty ? nil : values
        default: return nil
        }
    }

    public var vec2: SIMD2<Float>? {
        guard let f = floats, !f.isEmpty else { return nil }
        return SIMD2(f[0], f.count > 1 ? f[1] : f[0])
    }

    public var vec3: SIMD3<Float>? {
        guard let f = floats, !f.isEmpty else { return nil }
        if f.count == 1 { return SIMD3(repeating: f[0]) }
        return SIMD3(f[0], f.count > 1 ? f[1] : 0, f.count > 2 ? f[2] : 0)
    }

    public var vec4: SIMD4<Float>? {
        guard let f = floats, !f.isEmpty else { return nil }
        if f.count == 1 { return SIMD4(repeating: f[0]) }
        return SIMD4(f[0], f.count > 1 ? f[1] : 0, f.count > 2 ? f[2] : 0, f.count > 3 ? f[3] : 1)
    }

    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b.description
        case .number(let n): return JSON.numberString(n)
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[" + a.map(\.description).joined(separator: ",") + "]"
        case .object(let o):
            let members = o.keys.sorted().compactMap { key in o[key].map { "\"\(key)\":\($0.description)" } }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    /// Serialise back to a Foundation object (useful for persistence / scripting bridges).
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    public func merging(_ other: JSON) -> JSON {
        guard case .object(var a) = self, case .object(let b) = other else { return other.isNull ? self : other }
        for (k, v) in b { a[k] = v }
        return .object(a)
    }
}

public extension JSON {
    /// Convenience for building literal values in code.
    static func vec(_ v: SIMD3<Float>) -> JSON { .string("\(v.x) \(v.y) \(v.z)") }
    static func vec(_ v: SIMD2<Float>) -> JSON { .string("\(v.x) \(v.y)") }
}
