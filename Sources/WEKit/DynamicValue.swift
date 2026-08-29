import Foundation

/// Live values of a wallpaper's user properties plus a tiny expression
/// evaluator for the JavaScript-like `condition` strings WE uses.
public final class PropertyStore {
    public private(set) var definitions: [String: WEUserProperty] = [:]
    public private(set) var values: [String: JSON] = [:]
    public var orderedProperties: [WEUserProperty]

    public init(properties: [WEUserProperty], overrides: [String: JSON] = [:]) {
        orderedProperties = properties
        for p in properties {
            definitions[p.name] = p
            values[p.name] = overrides[p.name] ?? p.defaultValue
        }
        for (k, v) in overrides where definitions[k] == nil { values[k] = v }
    }

    public func value(_ name: String) -> JSON? { values[name] }

    public func set(_ name: String, _ value: JSON) { values[name] = value }

    public func reset(_ name: String) {
        if let def = definitions[name] { values[name] = def.defaultValue }
    }

    /// Values that differ from the defaults (for persistence).
    public var overrides: [String: JSON] {
        var out: [String: JSON] = [:]
        for (k, v) in values {
            if let def = definitions[k], def.defaultValue == v { continue }
            out[k] = v
        }
        return out
    }

    public func evaluateCondition(_ expression: String) -> Bool {
        ConditionEvaluator(store: self).evaluate(expression)
    }
}

/// A scene value that is either a literal or bound to a user property / script.
public struct DynamicValue: Equatable {
    public let value: JSON
    public let user: String?
    public let condition: String?
    public let script: String?
    public let scriptProperties: JSON

    public init(value: JSON, user: String? = nil, condition: String? = nil, script: String? = nil, scriptProperties: JSON = .null) {
        self.value = value; self.user = user; self.condition = condition; self.script = script; self.scriptProperties = scriptProperties
    }

    public static func parse(_ json: JSON) -> DynamicValue {
        guard case .object(let o) = json, o["user"] != nil || o["script"] != nil || o["value"] != nil else {
            return DynamicValue(value: json)
        }
        var user: String? = nil
        var condition: String? = nil
        switch json["user"] {
        case .string(let s): user = s
        case .object:
            user = json["user"]["name"].string
            switch json["user"]["condition"] {
            case .string(let s): condition = s
            case .number(let n): condition = JSON.numberString(n)
            case .bool(let b): condition = b ? "true" : "false"
            default: break
            }
        default: break
        }
        return DynamicValue(value: json["value"], user: user, condition: condition,
                            script: json["script"].string, scriptProperties: json["scriptproperties"])
    }

    public var isBound: Bool { user != nil || script != nil }

    /// Resolve against the property store. Script-driven values fall back to
    /// their stored default (scripts are evaluated elsewhere).
    public func resolve(_ store: PropertyStore?) -> JSON {
        guard let user, let store, let bound = store.value(user) else { return value }
        if let condition {
            return .bool(ConditionEvaluator.matches(propertyValue: bound, condition: condition, store: store, propertyName: user))
        }
        // Combo property values are strings ("0", "1"); convert to the literal's type.
        switch value {
        case .bool: return .bool(bound.bool ?? (value.bool ?? false))
        case .number: return .number(bound.double ?? (value.double ?? 0))
        default: return bound
        }
    }

    public func resolveBool(_ store: PropertyStore?, default def: Bool = true) -> Bool { resolve(store).bool ?? def }
    public func resolveFloat(_ store: PropertyStore?, default def: Float = 0) -> Float { resolve(store).float ?? def }
    public func resolveVec2(_ store: PropertyStore?, default def: SIMD2<Float>) -> SIMD2<Float> { resolve(store).vec2 ?? def }
    public func resolveVec3(_ store: PropertyStore?, default def: SIMD3<Float>) -> SIMD3<Float> { resolve(store).vec3 ?? def }
}

// MARK: - Condition evaluator

/// Evaluates expressions such as `bloom.value == true`, `weather.value == 1`,
/// `posy > 0.5 && showclock`, or a bare literal `1` (compared with the bound property).
public struct ConditionEvaluator {
    let store: PropertyStore

    public init(store: PropertyStore) { self.store = store }

    private static let maximumExpressionByteCount = 64 * 1024

    static func matches(propertyValue: JSON, condition: String, store: PropertyStore, propertyName: String) -> Bool {
        let trimmed = condition.trimmingCharacters(in: .whitespaces)
        // Bare literal: compare with the property value.
        if let n = Double(trimmed) {
            if let v = propertyValue.double { return v == n }
            return false
        }
        if trimmed == "true" || trimmed == "false" {
            return (propertyValue.bool ?? false) == (trimmed == "true")
        }
        if trimmed.first == "\"" || trimmed.first == "'" {
            let inner = String(trimmed.dropFirst().dropLast())
            return propertyValue.string == inner
        }
        return ConditionEvaluator(store: store).evaluate(trimmed)
    }

    public func evaluate(_ expression: String) -> Bool {
        guard expression.utf8.count <= ConditionEvaluator.maximumExpressionByteCount else { return false }
        let tokens = Lexer(expression).tokenize()
        // The parser is recursive for unary operators and parentheses.
        guard tokens.count <= 256 else { return false }
        var parser = Parser(tokens: tokens, store: store)
        guard let v = parser.parseExpression() else { return false }
        return v.truthy
    }

    // MARK: Values

    enum Value {
        case number(Double), string(String), bool(Bool), null

        var truthy: Bool {
            switch self {
            case .number(let n): return n != 0 && !n.isNaN
            case .string(let s): return !s.isEmpty
            case .bool(let b): return b
            case .null: return false
            }
        }
        var asNumber: Double? {
            switch self {
            case .number(let n): return n
            case .bool(let b): return b ? 1 : 0
            case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
            case .null: return nil
            }
        }
        static func looseEqual(_ a: Value, _ b: Value) -> Bool {
            switch (a, b) {
            case (.string(let x), .string(let y)): return x == y
            case (.null, .null): return true
            case (.null, _), (_, .null): return false
            default:
                if let x = a.asNumber, let y = b.asNumber { return x == y }
                if case .string(let x) = a, case .bool(let y) = b { return (x == "true") == y }
                if case .bool(let x) = a, case .string(let y) = b { return (y == "true") == x }
                return false
            }
        }
        init(_ json: JSON) {
            switch json {
            case .bool(let b): self = .bool(b)
            case .number(let n): self = .number(n)
            case .string(let s): self = .string(s)
            case .null: self = .null
            default: self = .string(json.description)
            }
        }
    }

    // MARK: Lexer

    enum Token: Equatable {
        case number(Double), string(String), ident(String), op(String), lparen, rparen, end
    }

    struct Lexer {
        let chars: [Character]
        init(_ s: String) { chars = Array(s) }

        func tokenize() -> [Token] {
            var tokens: [Token] = []
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                if c == "(" { tokens.append(.lparen); i += 1; continue }
                if c == ")" { tokens.append(.rparen); i += 1; continue }
                if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                    var j = i
                    while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                    tokens.append(.number(Double(String(chars[i..<j])) ?? 0))
                    i = j
                    continue
                }
                if c == "\"" || c == "'" {
                    var j = i + 1
                    var s = ""
                    while j < chars.count, chars[j] != c { s.append(chars[j]); j += 1 }
                    tokens.append(.string(s))
                    i = j + 1
                    continue
                }
                if c.isLetter || c == "_" || c == "$" {
                    var j = i
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." || chars[j] == "$" { j += 1 }
                    tokens.append(.ident(String(chars[i..<j])))
                    i = j
                    continue
                }
                // operators
                let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
                let three = i + 2 < chars.count ? String(chars[i...i + 2]) : ""
                if three == "===" || three == "!==" { tokens.append(.op(String(three.prefix(2)))); i += 3; continue }
                if ["==", "!=", "<=", ">=", "&&", "||"].contains(two) { tokens.append(.op(two)); i += 2; continue }
                if ["<", ">", "!", "+", "-", "*", "/"].contains(String(c)) { tokens.append(.op(String(c))); i += 1; continue }
                i += 1 // skip unknown
            }
            tokens.append(.end)
            return tokens
        }
    }

    // MARK: Parser (precedence climbing)

    struct Parser {
        let tokens: [Token]
        var pos = 0
        let store: PropertyStore

        init(tokens: [Token], store: PropertyStore) { self.tokens = tokens; self.store = store }

        var peek: Token { tokens[min(pos, tokens.count - 1)] }
        mutating func next() -> Token { let t = peek; pos += 1; return t }

        mutating func parseExpression() -> Value? { parseOr() }

        mutating func parseOr() -> Value? {
            guard var left = parseAnd() else { return nil }
            while peek == .op("||") { _ = next(); guard let r = parseAnd() else { return nil }; left = .bool(left.truthy || r.truthy) }
            return left
        }
        mutating func parseAnd() -> Value? {
            guard var left = parseEquality() else { return nil }
            while peek == .op("&&") { _ = next(); guard let r = parseEquality() else { return nil }; left = .bool(left.truthy && r.truthy) }
            return left
        }
        mutating func parseEquality() -> Value? {
            guard var left = parseComparison() else { return nil }
            while true {
                if peek == .op("==") { _ = next(); guard let r = parseComparison() else { return nil }; left = .bool(Value.looseEqual(left, r)) }
                else if peek == .op("!=") { _ = next(); guard let r = parseComparison() else { return nil }; left = .bool(!Value.looseEqual(left, r)) }
                else { return left }
            }
        }
        mutating func parseComparison() -> Value? {
            guard var left = parseAdditive() else { return nil }
            while true {
                guard case .op(let o) = peek, ["<", ">", "<=", ">="].contains(o) else { return left }
                _ = next()
                guard let r = parseAdditive(), let a = left.asNumber, let b = r.asNumber else { return .bool(false) }
                switch o {
                case "<": left = .bool(a < b)
                case ">": left = .bool(a > b)
                case "<=": left = .bool(a <= b)
                default: left = .bool(a >= b)
                }
            }
        }
        mutating func parseAdditive() -> Value? {
            guard var left = parseUnary() else { return nil }
            while true {
                guard case .op(let o) = peek, o == "+" || o == "-" || o == "*" || o == "/" else { return left }
                _ = next()
                guard let r = parseUnary(), let a = left.asNumber, let b = r.asNumber else { return nil }
                switch o {
                case "+": left = .number(a + b)
                case "-": left = .number(a - b)
                case "*": left = .number(a * b)
                default: left = .number(b == 0 ? .nan : a / b)
                }
            }
        }
        mutating func parseUnary() -> Value? {
            if peek == .op("!") { _ = next(); guard let v = parseUnary() else { return nil }; return .bool(!v.truthy) }
            if peek == .op("-") { _ = next(); guard let v = parseUnary(), let n = v.asNumber else { return nil }; return .number(-n) }
            return parsePrimary()
        }
        mutating func parsePrimary() -> Value? {
            switch next() {
            case .number(let n): return .number(n)
            case .string(let s): return .string(s)
            case .lparen:
                let v = parseExpression()
                if peek == .rparen { _ = next() }
                return v
            case .ident(let name):
                switch name {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "null", "undefined": return .null
                default:
                    var key = name
                    if key.hasSuffix(".value") { key = String(key.dropLast(6)) }
                    if let v = store.value(key) { return Value(v) }
                    // Unknown identifiers evaluate to undefined.
                    return .null
                }
            default:
                return nil
            }
        }
    }
}
