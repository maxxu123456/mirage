import Foundation

/// Wallpaper Engine shaders are authored against HLSL rules and compiled to
/// HLSL on Windows, so many of them rely on conversions GLSL rejects:
/// truncating a larger vector to a smaller one in a binary operation or an
/// assignment, mixing `int`/`uint`/`float`, `%` on floats, and functions that
/// fall off the end without returning.
///
/// Rather than guessing with blanket regexes, we let glslang point at the exact
/// line and column and apply one targeted edit per diagnostic, recompiling until
/// the shader is accepted or no further repair applies.
public enum ShaderRepair {

    // MARK: Diagnostics

    public struct Diagnostic {
        public let isError: Bool
        public let line: Int          // as reported by glslang (1-based over the whole source string)
        public let column: Int        // 1-based, 0 when unknown
        public let token: String      // the quoted token, e.g. "*", "=", ""
        public let message: String
    }

    private static let diagRegex = try! NSRegularExpression(
        pattern: #"^(ERROR|WARNING):\s*\d+:(\d+)(?::(\d+))?:\s*'([^']*)'\s*:\s*(.*)$"#)

    public static func parse(log: String) -> [Diagnostic] {
        var out: [Diagnostic] = []
        for raw in log.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = diagRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func group(_ i: Int) -> String? { Range(m.range(at: i), in: line).map { String(line[$0]) } }
            guard let severity = group(1), let lineNo = group(2).flatMap(Int.init) else { continue }
            out.append(Diagnostic(isError: severity == "ERROR", line: lineNo,
                                  column: group(3).flatMap(Int.init) ?? 0,
                                  token: group(4) ?? "", message: group(5) ?? ""))
        }
        return out
    }

    // MARK: GLSL type descriptors

    struct TypeInfo {
        let components: Int
        let base: String     // "float" | "int" | "uint" | "bool"
        let isMatrix: Bool

        var glslName: String {
            if isMatrix { return "mat\(components)" }
            switch (base, components) {
            case (_, 1): return base
            case ("float", let n): return "vec\(n)"
            case ("int", let n): return "ivec\(n)"
            case ("uint", let n): return "uvec\(n)"
            case ("bool", let n): return "bvec\(n)"
            default: return base
            }
        }

        var swizzle: String { components >= 4 ? "" : "." + String("xyzw".prefix(components)) }
    }

    /// Parses glslang's human-readable type strings, e.g.
    /// `" temp highp 2-component vector of float"`, `" const float"`,
    /// `"layout( location=1) smooth in highp 4-component vector of float"`.
    static func parseType(_ text: String) -> TypeInfo? {
        let base: String
        if text.contains("of float") || text.hasSuffix("float") { base = "float" }
        else if text.contains("of uint") || text.hasSuffix("uint") { base = "uint" }
        else if text.contains("of int") || text.hasSuffix("int") { base = "int" }
        else if text.contains("of bool") || text.hasSuffix("bool") { base = "bool" }
        else { return nil }

        if let r = text.range(of: #"(\d+)-component vector"#, options: .regularExpression) {
            let digits = text[r].prefix { $0.isNumber }
            return TypeInfo(components: Int(digits) ?? 1, base: base, isMatrix: false)
        }
        if let r = text.range(of: #"(\d+)X(\d+) matrix"#, options: .regularExpression) {
            let digits = text[r].prefix { $0.isNumber }
            return TypeInfo(components: Int(digits) ?? 4, base: base, isMatrix: true)
        }
        return TypeInfo(components: 1, base: base, isMatrix: false)
    }

    // MARK: Expression scanning

    /// Characters that can appear inside a primary expression's identifier part.
    private static func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }

    /// Start index of the primary expression that ends just before `end`.
    static func scanLeftPrimary(_ chars: [Character], end: Int) -> Int? {
        var i = end - 1
        while i >= 0, chars[i] == " " || chars[i] == "\t" { i -= 1 }
        guard i >= 0 else { return nil }
        var start = i + 1
        var guard_ = 0
        while i >= 0, guard_ < 4096 {
            guard_ += 1
            let c = chars[i]
            if c == ")" || c == "]" {
                let open: Character = c == ")" ? "(" : "["
                var depth = 0
                while i >= 0 {
                    if chars[i] == c { depth += 1 }
                    else if chars[i] == open {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    i -= 1
                }
                guard i >= 0 else { return nil }
                start = i
                i -= 1
                // A function call: the identifier before '(' belongs to the expression.
                while i >= 0, isIdentChar(chars[i]) { start = i; i -= 1 }
                continue
            }
            if isIdentChar(c) {
                while i >= 0, isIdentChar(chars[i]) { start = i; i -= 1 }
                continue
            }
            break
        }
        return start < end ? start : nil
    }

    /// End index (exclusive) of the primary expression beginning at or after `start`.
    static func scanRightPrimary(_ chars: [Character], start: Int) -> Int? {
        var i = start
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        while i < chars.count, chars[i] == "-" || chars[i] == "+" || chars[i] == "!" || chars[i] == "~" {
            i += 1
            while i < chars.count, chars[i] == " " { i += 1 }
        }
        guard i < chars.count else { return nil }
        var guard_ = 0
        var sawSomething = false
        while i < chars.count, guard_ < 4096 {
            guard_ += 1
            let c = chars[i]
            if isIdentChar(c) {
                while i < chars.count, isIdentChar(chars[i]) { i += 1 }
                sawSomething = true
                continue
            }
            if c == "(" || c == "[" {
                let close: Character = c == "(" ? ")" : "]"
                var depth = 0
                while i < chars.count {
                    if chars[i] == c { depth += 1 }
                    else if chars[i] == close {
                        depth -= 1
                        if depth == 0 { i += 1; break }
                    }
                    i += 1
                }
                sawSomething = true
                continue
            }
            break
        }
        return sawSomething ? i : nil
    }

    /// Index of `token` on `line` nearest to the reported (1-based) column.
    static func locate(_ token: String, in line: [Character], column: Int) -> Int? {
        guard !token.isEmpty else { return nil }
        let t = Array(token)
        var hits: [Int] = []
        var i = 0
        while i + t.count <= line.count {
            if Array(line[i..<(i + t.count)]) == t {
                // Skip compound operators: "==", "<=", "*=", "!=" and friends.
                let nextOK = i + t.count >= line.count || line[i + t.count] != "="
                let prevOK = token != "=" || i == 0 || !"<>!=+-*/%&|^".contains(line[i - 1])
                if nextOK && prevOK { hits.append(i) }
            }
            i += 1
        }
        guard !hits.isEmpty else { return nil }
        let target = max(0, column - 1)
        return hits.min(by: { abs($0 - target) < abs($1 - target) })
    }

    // MARK: Repairs

    /// Applies one repair for the first actionable error. Returns the edited
    /// source, or nil when nothing could be done.
    public static func apply(diagnostics: [Diagnostic], to source: String) -> (String, String)? {
        var lines = source.components(separatedBy: "\n")
        for diag in diagnostics where diag.isError {
            // glslang counts from 1, but has been observed to report the index of
            // the line as well; try the exact line first, then its neighbours.
            for candidate in [diag.line - 1, diag.line, diag.line - 2] {
                guard candidate >= 0, candidate < lines.count else { continue }
                if let (edited, note) = repair(diag, line: lines[candidate]) {
                    lines[candidate] = edited
                    return (lines.joined(separator: "\n"), "line \(candidate + 1): \(note)")
                }
            }
            // Whole-source repairs.
            if let (edited, note) = repairWholeSource(diag, lines: lines) {
                return (edited.joined(separator: "\n"), note)
            }
        }
        return nil
    }

    private static func repair(_ diag: Diagnostic, line: String) -> (String, String)? {
        if diag.message.contains("wrong operand types") {
            return repairBinaryOperator(diag, line: line)
        }
        if ShaderRepair.assignmentTokens.contains(diag.token) && diag.message.contains("cannot convert from") {
            return repairAssignment(diag, line: line)
        }
        return nil
    }

    /// glslang names a declaration initializer `'='` and a statement assignment `'assign'`.
    static let assignmentTokens: Set<String> = ["=", "assign", "+=", "-=", "*=", "/=", "%="]

    private static let convertRegex = try! NSRegularExpression(pattern: #"cannot convert from '([^']*)' to '([^']*)'"#)
    private static let operandRegex = try! NSRegularExpression(
        pattern: #"left-hand operand of type '([^']*)' and a right operand of type '([^']*)'"#)

    /// `a OP b` where the operand vector sizes or base types disagree.
    private static func repairBinaryOperator(_ diag: Diagnostic, line: String) -> (String, String)? {
        let ns = diag.message as NSString
        guard let m = operandRegex.firstMatch(in: diag.message, range: NSRange(location: 0, length: ns.length)),
              let leftType = parseType(ns.substring(with: m.range(at: 1))),
              let rightType = parseType(ns.substring(with: m.range(at: 2))),
              !leftType.isMatrix, !rightType.isMatrix else { return nil }
        var chars = Array(line)
        guard let opIndex = locate(diag.token, in: chars, column: diag.column) else { return nil }
        let opLength = diag.token.count
        guard let leftStart = scanLeftPrimary(chars, end: opIndex),
              let rightEnd = scanRightPrimary(chars, start: opIndex + opLength) else { return nil }
        let rightStart = { () -> Int in
            var i = opIndex + opLength
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            return i
        }()

        // `%` needs integers in GLSL; WE relies on HLSL's float modulo.
        if diag.token == "%" && (leftType.base == "float" || rightType.base == "float") {
            var out = chars
            if rightType.base == "float" {
                out.replaceSubrange(rightStart..<rightEnd, with: Array("int(" + String(chars[rightStart..<rightEnd]) + ")"))
            }
            if leftType.base == "float" {
                out.replaceSubrange(leftStart..<opIndex, with: Array("int(" + String(chars[leftStart..<opIndex]).trimmingCharacters(in: .whitespaces) + ") "))
            }
            return (String(out), "cast operands of '%' to int")
        }

        // Different vector widths: HLSL truncates to the narrower one.
        if leftType.components != rightType.components,
           leftType.components > 0, rightType.components > 0,
           min(leftType.components, rightType.components) >= 1 {
            let target = min(leftType.components, rightType.components)
            let swizzle = "." + String("xyzw".prefix(target))
            if leftType.components > rightType.components {
                let text = String(chars[leftStart..<opIndex])
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                chars.replaceSubrange(leftStart..<opIndex, with: Array(trimmed + swizzle + " "))
                return (String(chars), "truncate left operand of '\(diag.token)' to \(target) components")
            } else {
                let text = String(chars[rightStart..<rightEnd])
                guard !text.isEmpty else { return nil }
                chars.replaceSubrange(rightStart..<rightEnd, with: Array(text + swizzle))
                return (String(chars), "truncate right operand of '\(diag.token)' to \(target) components")
            }
        }

        // Same width, different base type: promote the narrower operand.
        if leftType.base != rightType.base {
            let rank = ["bool": 0, "int": 1, "uint": 2, "float": 3]
            let promote = (rank[leftType.base] ?? 0) > (rank[rightType.base] ?? 0)
            let targetName = promote ? leftType.glslName : rightType.glslName
            if promote {
                let text = String(chars[rightStart..<rightEnd])
                chars.replaceSubrange(rightStart..<rightEnd, with: Array("\(targetName)(\(text))"))
                return (String(chars), "promote right operand of '\(diag.token)' to \(targetName)")
            } else {
                let text = String(chars[leftStart..<opIndex]).trimmingCharacters(in: .whitespaces)
                chars.replaceSubrange(leftStart..<opIndex, with: Array("\(targetName)(\(text)) "))
                return (String(chars), "promote left operand of '\(diag.token)' to \(targetName)")
            }
        }
        return nil
    }

    /// `T name = expr;` / `name = expr;` where `expr` has the wrong shape.
    private static func repairAssignment(_ diag: Diagnostic, line: String) -> (String, String)? {
        let ns = diag.message as NSString
        guard let m = convertRegex.firstMatch(in: diag.message, range: NSRange(location: 0, length: ns.length)),
              let target = parseType(ns.substring(with: m.range(at: 2))), !target.isMatrix else { return nil }
        var chars = Array(line)
        // Compound assignments carry the operator in the line, not in the token. Pick the
        // candidate nearest the reported column rather than the first in the list, so a
        // line like `a *= b; c = d;` repairs the operator the diagnostic actually names.
        var eq: Int? = nil
        var bestDistance = Int.max
        let column = max(0, diag.column - 1)
        for op in ["*=", "/=", "+=", "-=", "%="] {
            guard let i = locate(op, in: chars, column: diag.column) else { continue }
            let distance = abs(i - column)
            if distance < bestDistance { bestDistance = distance; eq = i + 1 }
        }
        if let plain = locate("=", in: chars, column: diag.column), abs(plain - column) < bestDistance {
            eq = plain
        }
        guard let eq, eq + 1 < chars.count else { return nil }
        // The initializer runs to the next `,` or `;` at paren depth zero. If neither is on
        // this line the statement continues on the next one; wrapping the fragment we can
        // see would silently change the arithmetic, so refuse the repair instead.
        var i = eq + 1
        var depth = 0
        var end: Int? = nil
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == "[" { depth += 1 }
            else if c == ")" || c == "]" { depth -= 1 }
            else if depth == 0 && (c == ";" || c == ",") { end = i; break }
            i += 1
        }
        guard let end else { return nil }
        let expr = String(chars[(eq + 1)..<end]).trimmingCharacters(in: .whitespaces)
        guard !expr.isEmpty, !expr.hasPrefix("{") else { return nil }
        chars.replaceSubrange((eq + 1)..<end, with: Array(" \(target.glslName)(\(expr))"))
        return (String(chars), "coerce initializer to \(target.glslName)")
    }

    private static let functionHeadRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:lowp|mediump|highp)\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\([^;]*\)\s*\{?\s*$"#)

    /// `function does not return a value: NAME` — HLSL tolerates it, GLSL does not.
    private static func repairWholeSource(_ diag: Diagnostic, lines: [String]) -> ([String], String)? {
        guard let range = diag.message.range(of: "function does not return a value:") else { return nil }
        let name = diag.message[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        for (index, line) in lines.enumerated() {
            guard let m = functionHeadRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let typeRange = Range(m.range(at: 1), in: line), let nameRange = Range(m.range(at: 2), in: line),
                  String(line[nameRange]) == name else { continue }
            let returnType = String(line[typeRange])
            guard returnType != "void" else { return nil }
            // Walk to the matching closing brace of the body.
            var depth = 0
            var started = false
            for j in index..<lines.count {
                for c in lines[j] {
                    if c == "{" { depth += 1; started = true }
                    else if c == "}" { depth -= 1 }
                }
                if started && depth == 0 {
                    var edited = lines
                    let zero = returnType == "float" ? "0.0" : (returnType == "int" ? "0" : (returnType == "uint" ? "0u" : (returnType == "bool" ? "false" : "\(returnType)(0.0)")))
                    edited.insert("    return \(zero);", at: j)
                    return (edited, "add fallback return to \(name)()")
                }
            }
        }
        return nil
    }
}
