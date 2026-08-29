import Foundation

// MARK: - Metadata

public struct ShaderUniformInfo: Hashable {
    public let name: String
    public let type: String
    public let arraySize: String?
    public let annotation: JSON

    public var materialKey: String? { annotation["material"].string }
    public var defaultValue: JSON { annotation["default"] }
    public var isSampler: Bool { type.hasPrefix("sampler") }
    /// Texture slot for `g_TextureN` samplers.
    public var textureSlot: Int? {
        guard isSampler, name.hasPrefix("g_Texture") else { return nil }
        return Int(name.dropFirst("g_Texture".count))
    }

    public static func == (a: ShaderUniformInfo, b: ShaderUniformInfo) -> Bool { a.name == b.name && a.type == b.type }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

public struct ShaderComboDecl {
    public let name: String
    public let defaultValue: Int
    public let annotation: JSON
}

/// A shader pair loaded from `shaders/<name>.vert` + `.frag` with includes expanded.
public struct ShaderProgramSource {
    public let name: String
    public let vertex: String
    public let fragment: String
    public let uniforms: [ShaderUniformInfo]      // union of both stages
    public let combos: [ShaderComboDecl]          // declared via // [COMBO]
    public let requiresLighting: Bool

    public func uniform(named n: String) -> ShaderUniformInfo? { uniforms.first { $0.name == n } }
    public func samplerInfo(slot: Int) -> ShaderUniformInfo? { uniforms.first { $0.textureSlot == slot } }
    public var samplerSlots: [Int] { uniforms.compactMap(\.textureSlot).sorted() }
    public func comboDefault(_ name: String) -> Int? { combos.first { $0.name == name }?.defaultValue }
}

public enum ShaderPreprocessorError: Error, CustomStringConvertible {
    case shaderNotFound(String)
    public var description: String {
        switch self { case .shaderNotFound(let n): return "shader not found: \(n)" }
    }
}

// MARK: - Preprocessor

public final class ShaderPreprocessor {
    public let locator: AssetLocator

    public init(locator: AssetLocator) { self.locator = locator }

    /// Vertex attribute locations shared with the renderer's vertex descriptors.
    public static let attributeLocations: [String: Int] = [
        "a_Position": 0, "a_PositionVec4": 0,
        "a_TexCoord": 1, "a_TexCoordVec3": 1, "a_TexCoordVec4": 1,
        "a_Color": 2,
        "a_Normal": 3,
        "a_Tangent": 4,
        "a_Bitangent": 5,
        "a_TexCoordC1": 6, "a_TexCoordVec3C1": 6, "a_TexCoordVec4C1": 6,
        "a_TexCoordC2": 7, "a_TexCoordVec3C2": 7, "a_TexCoordVec4C2": 7,
        "a_TexCoordC3": 8, "a_TexCoordVec3C3": 8, "a_TexCoordVec4C3": 8,
        "a_TexCoordC4": 9, "a_TexCoordVec3C4": 9, "a_TexCoordVec4C4": 9,
        "a_TexCoordC5": 10, "a_TexCoordVec4C5": 10,
        "a_BlendIndices": 11,
        "a_BlendWeights": 12,
    ]

    // MARK: Loading

    public func load(_ name: String) throws -> ShaderProgramSource {
        guard let vert = locator.shaderSource(name, ext: "vert") else { throw ShaderPreprocessorError.shaderNotFound("shaders/\(name).vert") }
        guard let frag = locator.shaderSource(name, ext: "frag") else { throw ShaderPreprocessorError.shaderNotFound("shaders/\(name).frag") }
        return load(name: name, vertex: vert, fragment: frag)
    }

    public func load(name: String, vertex: String, fragment: String) -> ShaderProgramSource {
        var seenV = Set<String>(), seenF = Set<String>()
        let v = expandIncludes(normalize(vertex), seen: &seenV, depth: 0)
        let f = expandIncludes(normalize(fragment), seen: &seenF, depth: 0)
        var uniforms: [ShaderUniformInfo] = []
        var names = Set<String>()
        let vertexUniforms = ShaderPreprocessor.extractUniforms(v)
        let fragmentUniforms = ShaderPreprocessor.extractUniforms(f)
        for (stage, stageUniforms) in [(ShaderStage.vertex, vertexUniforms), (.fragment, fragmentUniforms)] {
            for u in stageUniforms {
                if names.insert(u.name).inserted { uniforms.append(u) }
                else if let i = uniforms.firstIndex(where: { $0.name == u.name }),
                        (stage == .fragment && u.isSampler && !u.annotation.isNull)
                            || (uniforms[i].annotation.isNull && !u.annotation.isNull) {
                    // Fragment sampler defaults have higher lookup priority than vertex defaults.
                    uniforms[i] = u
                }
            }
        }
        var combos: [ShaderComboDecl] = []
        var comboNames = Set<String>()
        for c in ShaderPreprocessor.extractCombos(v) + ShaderPreprocessor.extractCombos(f) where comboNames.insert(c.name).inserted {
            combos.append(c)
        }
        let requiresLighting = v.contains("#require") || f.contains("#require")
        return ShaderProgramSource(name: name, vertex: v, fragment: f, uniforms: uniforms, combos: combos, requiresLighting: requiresLighting)
    }

    private func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        return t
    }

    // MARK: Includes

    private static let includeRegex = try! NSRegularExpression(pattern: #"^\s*#\s*include\s+["<]([^">]+)[">]"#)
    private static let functionDefRegex = try! NSRegularExpression(pattern: #"^\s*(?:const\s+|highp\s+|mediump\s+|lowp\s+)?(void|float|vec[234]|mat[234](?:x[234])?|int|uint|bool|[iub]vec[234]|[A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\("#)
    private static let maximumIncludeDepth = 64

    func expandIncludes(_ source: String, seen: inout Set<String>, depth: Int) -> String {
        var lines = source.components(separatedBy: "\n")
        var blocks: [String] = []
        for i in lines.indices {
            let line = lines[i]
            guard let m = ShaderPreprocessor.includeRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line) else { continue }
            let name = String(line[r])
            lines[i] = "// \(line.trimmingCharacters(in: .whitespaces))"
            guard depth < ShaderPreprocessor.maximumIncludeDepth else {
                lines[i] += " // (include depth limit)"
                continue
            }
            if seen.contains(name) { continue }
            seen.insert(name)
            guard let content = locator.includeSource(name) else {
                lines[i] += " // (not found)"
                continue
            }
            let expanded = expandIncludes(normalize(content), seen: &seen, depth: depth + 1)
            let block = "// ---- begin \(name) ----\n\(expanded)\n// ---- end \(name) ----"
            if depth > 0 {
                lines[i] = block
            } else {
                blocks.append(block)
            }
        }
        guard depth == 0, !blocks.isEmpty else { return lines.joined(separator: "\n") }
        let at = ShaderPreprocessor.includeInsertionIndex(lines)
        lines.insert(blocks.joined(separator: "\n"), at: at)
        return lines.joined(separator: "\n")
    }

    /// Index of the first function definition at brace depth 0. If that line
    /// is inside a `#if` block, the index of the outermost `#if` instead.
    static func includeInsertionIndex(_ lines: [String]) -> Int {
        var ifStack: [Int] = []
        var braceDepth = 0
        var inBlockComment = false
        for (i, raw) in lines.enumerated() {
            var line = raw
            if inBlockComment {
                if let end = line.range(of: "*/") { line = String(line[end.upperBound...]); inBlockComment = false } else { continue }
            }
            if let c = line.range(of: "//") { line = String(line[..<c.lowerBound]) }
            if let s = line.range(of: "/*") {
                if let e = line.range(of: "*/", range: s.upperBound..<line.endIndex) {
                    line = String(line[..<s.lowerBound]) + String(line[e.upperBound...])
                } else { line = String(line[..<s.lowerBound]); inBlockComment = true }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let directive = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if directive.hasPrefix("if") { ifStack.append(i) }
                else if directive.hasPrefix("endif") { _ = ifStack.popLast() }
                continue
            }
            if braceDepth == 0, trimmed.first?.isLetter == true,
               let m = functionDefRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                let keyword = (Range(m.range(at: 1), in: trimmed)).map { String(trimmed[$0]) } ?? ""
                if !["uniform", "attribute", "varying", "in", "out", "inout", "struct", "layout", "precision", "return", "else", "if", "for", "while", "switch"].contains(keyword) {
                    return ifStack.first ?? i
                }
            }
            for ch in trimmed {
                if ch == "{" { braceDepth += 1 } else if ch == "}" { braceDepth = max(0, braceDepth - 1) }
            }
        }
        // No function found: append at the end.
        return lines.count
    }

    // MARK: Metadata extraction

    private static let uniformRegex = try! NSRegularExpression(
        pattern: #"^\s*uniform\s+(?:(?:lowp|mediump|highp)\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*(?:\[\s*([A-Za-z0-9_]+)\s*\])?\s*;\s*(?://\s*(\{.*\}))?"#)
    private static let comboRegex = try! NSRegularExpression(pattern: #"^\s*//\s*\[COMBO\]\s*(\{.*\})"#)

    public static func extractUniforms(_ source: String) -> [ShaderUniformInfo] {
        var out: [ShaderUniformInfo] = []
        for line in source.components(separatedBy: "\n") {
            guard let m = uniformRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func group(_ i: Int) -> String? { Range(m.range(at: i), in: line).map { String(line[$0]) } }
            guard let type = group(1), let name = group(2) else { continue }
            var annotation: JSON = .null
            if let a = group(4), let j = try? JSON.parse(a) { annotation = j }
            out.append(ShaderUniformInfo(name: name, type: type, arraySize: group(3), annotation: annotation))
        }
        return out
    }

    public static func extractCombos(_ source: String) -> [ShaderComboDecl] {
        var out: [ShaderComboDecl] = []
        for line in source.components(separatedBy: "\n") {
            guard let m = comboRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line), let j = try? JSON.parse(String(line[r])),
                  let name = j["combo"].string else { continue }
            out.append(ShaderComboDecl(name: name.uppercased(), defaultValue: j["default"].int ?? 0, annotation: j))
        }
        return out
    }

    // MARK: Stage 1: GLSL fed to glslang's preprocessor

    public static let prelude = """
    #define GLSL 1
    #define mul(x, y) ((y) * (x))
    #define lerp mix
    #define frac fract
    #define CAST2(x) (vec2(x))
    #define CAST3(x) (vec3(x))
    #define CAST4(x) (vec4(x))
    #define CAST3X3(x) (mat3(x))
    #define CASTU(x) (uint(x))
    #define float2 vec2
    #define float3 vec3
    #define float4 vec4
    #define float1 float
    #define int2 ivec2
    #define int3 ivec3
    #define int4 ivec4
    #define uint2 uvec2
    #define uint3 uvec3
    #define uint4 uvec4
    #define float2x2 mat2
    #define float3x3 mat3
    #define float4x4 mat4
    #define saturate(x) (clamp((x), 0.0, 1.0))
    #define texSample2D(tex, uv) texture(tex, (uv))
    #define texSample2DLod(tex, uv, lod) textureLod(tex, (uv), (lod))
    #define texSample2DGrad(tex, uv, dx, dy) textureGrad(tex, (uv), (dx), (dy))
    #define texSample2DComparison(tex, uv, z) texture(tex, vec3((uv), (z)))
    #define texSample2DProj(tex, uv) textureProj(tex, (uv))
    #define texSampleCube(tex, uv) texture(tex, (uv))
    #define log10(x) (log2(x) * 0.301029995663981)
    #define atan2(y, x) atan((y), (x))
    #define fmod(x, y) ((x) - (y) * trunc((x) / (y)))
    #define ddx dFdx
    #define ddy dFdy
    #define clip(x) if ((x) < 0.0) discard
    #define sampler2DComparison sampler2DShadow
    float we_pow(float x, float y) { return pow(x, y); }
    vec2 we_pow(vec2 x, vec2 y) { return pow(x, y); }
    vec3 we_pow(vec3 x, vec3 y) { return pow(x, y); }
    vec4 we_pow(vec4 x, vec4 y) { return pow(x, y); }
    vec2 we_pow(vec2 x, float y) { return pow(x, vec2(y)); }
    vec3 we_pow(vec3 x, float y) { return pow(x, vec3(y)); }
    vec4 we_pow(vec4 x, float y) { return pow(x, vec4(y)); }
    vec2 we_pow(float x, vec2 y) { return pow(vec2(x), y); }
    vec3 we_pow(float x, vec3 y) { return pow(vec3(x), y); }
    vec4 we_pow(float x, vec4 y) { return pow(vec4(x), y); }
    #define pow we_pow
    float we_max(float a, float b) { return max(a, b); }
    int we_max(int a, int b) { return max(a, b); }
    uint we_max(uint a, uint b) { return max(a, b); }
    vec2 we_max(vec2 a, vec2 b) { return max(a, b); }
    vec3 we_max(vec3 a, vec3 b) { return max(a, b); }
    vec4 we_max(vec4 a, vec4 b) { return max(a, b); }
    vec2 we_max(vec2 a, float b) { return max(a, vec2(b)); }
    vec3 we_max(vec3 a, float b) { return max(a, vec3(b)); }
    vec4 we_max(vec4 a, float b) { return max(a, vec4(b)); }
    vec2 we_max(float a, vec2 b) { return max(vec2(a), b); }
    vec3 we_max(float a, vec3 b) { return max(vec3(a), b); }
    vec4 we_max(float a, vec4 b) { return max(vec4(a), b); }
    float we_max(int a, float b) { return max(float(a), b); }
    float we_max(float a, int b) { return max(a, float(b)); }
    ivec2 we_max(ivec2 a, ivec2 b) { return max(a, b); }
    ivec3 we_max(ivec3 a, ivec3 b) { return max(a, b); }
    ivec4 we_max(ivec4 a, ivec4 b) { return max(a, b); }
    #define max we_max
    float we_min(float a, float b) { return min(a, b); }
    int we_min(int a, int b) { return min(a, b); }
    uint we_min(uint a, uint b) { return min(a, b); }
    vec2 we_min(vec2 a, vec2 b) { return min(a, b); }
    vec3 we_min(vec3 a, vec3 b) { return min(a, b); }
    vec4 we_min(vec4 a, vec4 b) { return min(a, b); }
    vec2 we_min(vec2 a, float b) { return min(a, vec2(b)); }
    vec3 we_min(vec3 a, float b) { return min(a, vec3(b)); }
    vec4 we_min(vec4 a, float b) { return min(a, vec4(b)); }
    vec2 we_min(float a, vec2 b) { return min(vec2(a), b); }
    vec3 we_min(float a, vec3 b) { return min(vec3(a), b); }
    vec4 we_min(float a, vec4 b) { return min(vec4(a), b); }
    float we_min(int a, float b) { return min(float(a), b); }
    float we_min(float a, int b) { return min(a, float(b)); }
    ivec2 we_min(ivec2 a, ivec2 b) { return min(a, b); }
    ivec3 we_min(ivec3 a, ivec3 b) { return min(a, b); }
    ivec4 we_min(ivec4 a, ivec4 b) { return min(a, b); }
    #define min we_min
    float we_step(float e, float x) { return step(e, x); }
    vec2 we_step(vec2 e, vec2 x) { return step(e, x); }
    vec3 we_step(vec3 e, vec3 x) { return step(e, x); }
    vec4 we_step(vec4 e, vec4 x) { return step(e, x); }
    vec2 we_step(float e, vec2 x) { return step(vec2(e), x); }
    vec3 we_step(float e, vec3 x) { return step(vec3(e), x); }
    vec4 we_step(float e, vec4 x) { return step(vec4(e), x); }
    vec2 we_step(vec2 e, float x) { return step(e, vec2(x)); }
    vec3 we_step(vec3 e, float x) { return step(e, vec3(x)); }
    vec4 we_step(vec4 e, float x) { return step(e, vec4(x)); }
    #define step we_step
    float we_smoothstep(float a, float b, float x) { return smoothstep(a, b, x); }
    vec2 we_smoothstep(vec2 a, vec2 b, vec2 x) { return smoothstep(a, b, x); }
    vec3 we_smoothstep(vec3 a, vec3 b, vec3 x) { return smoothstep(a, b, x); }
    vec4 we_smoothstep(vec4 a, vec4 b, vec4 x) { return smoothstep(a, b, x); }
    vec2 we_smoothstep(float a, float b, vec2 x) { return smoothstep(a, b, x); }
    vec3 we_smoothstep(float a, float b, vec3 x) { return smoothstep(a, b, x); }
    vec4 we_smoothstep(float a, float b, vec4 x) { return smoothstep(a, b, x); }
    vec2 we_smoothstep(vec2 a, vec2 b, float x) { return smoothstep(a, b, vec2(x)); }
    vec3 we_smoothstep(vec3 a, vec3 b, float x) { return smoothstep(a, b, vec3(x)); }
    vec4 we_smoothstep(vec4 a, vec4 b, float x) { return smoothstep(a, b, vec4(x)); }
    #define smoothstep we_smoothstep
    float we_mix(float a, float b, float t) { return mix(a, b, t); }
    vec2 we_mix(vec2 a, vec2 b, vec2 t) { return mix(a, b, t); }
    vec3 we_mix(vec3 a, vec3 b, vec3 t) { return mix(a, b, t); }
    vec4 we_mix(vec4 a, vec4 b, vec4 t) { return mix(a, b, t); }
    vec2 we_mix(vec2 a, vec2 b, float t) { return mix(a, b, t); }
    vec3 we_mix(vec3 a, vec3 b, float t) { return mix(a, b, t); }
    vec4 we_mix(vec4 a, vec4 b, float t) { return mix(a, b, t); }
    vec2 we_mix(float a, vec2 b, float t) { return mix(vec2(a), b, t); }
    vec3 we_mix(float a, vec3 b, float t) { return mix(vec3(a), b, t); }
    vec4 we_mix(float a, vec4 b, float t) { return mix(vec4(a), b, t); }
    vec2 we_mix(vec2 a, float b, float t) { return mix(a, vec2(b), t); }
    vec3 we_mix(vec3 a, float b, float t) { return mix(a, vec3(b), t); }
    vec4 we_mix(vec4 a, float b, float t) { return mix(a, vec4(b), t); }
    #define mix we_mix
    float we_clamp(float x, float a, float b) { return clamp(x, a, b); }
    vec2 we_clamp(vec2 x, vec2 a, vec2 b) { return clamp(x, a, b); }
    vec3 we_clamp(vec3 x, vec3 a, vec3 b) { return clamp(x, a, b); }
    vec4 we_clamp(vec4 x, vec4 a, vec4 b) { return clamp(x, a, b); }
    vec2 we_clamp(vec2 x, float a, float b) { return clamp(x, a, b); }
    vec3 we_clamp(vec3 x, float a, float b) { return clamp(x, a, b); }
    vec4 we_clamp(vec4 x, float a, float b) { return clamp(x, a, b); }
    vec2 we_clamp(float x, vec2 a, vec2 b) { return clamp(vec2(x), a, b); }
    vec3 we_clamp(float x, vec3 a, vec3 b) { return clamp(vec3(x), a, b); }
    vec4 we_clamp(float x, vec4 a, vec4 b) { return clamp(vec4(x), a, b); }
    #define clamp we_clamp

    """

    /// GLSL 4.5 keywords that Wallpaper Engine's dialect allows as identifiers.
    private static let reservedWordRegex = try! NSRegularExpression(pattern: #"\b(sample|filter|input|output|buffer|shared|resource|patch|precise|half|fixed|unsigned|long|short|common|partition|active|packed|inline|noinline|volatile|static|extern|external|interface|using|this|template|class|union|enum|typedef|goto|sizeof|cast|namespace|superp|public|subroutine|coherent|restrict|readonly|writeonly)\b"#)
    private static let textureIdentRegex = try! NSRegularExpression(pattern: #"\btexture\b(?!\s*\()"#)
    private static let comboTernaryRegex = try! NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9_]{2,})\s*\?"#)

    /// Textual fix-ups for HLSL-isms that strict GLSL rejects.
    static func applySourceFixups(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        for i in lines.indices {
            var line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Preprocessor expressions must be integer expressions; WE tolerates junk like
            // `#if g_Texture0Resolution.x < g_Texture0Resolution.y` (evaluates false).
            if trimmed.hasPrefix("#if ") || trimmed.hasPrefix("#elif ") {
                var expr = trimmed
                if let c = expr.range(of: "//") { expr = String(expr[..<c.lowerBound]) }
                if expr.contains(".") || expr.contains("\"") {
                    line = trimmed.hasPrefix("#elif") ? "#elif 0" : "#if 0"
                }
            } else if !trimmed.hasPrefix("//") {
                // Implicit conversions (vector truncation, scalar promotion, float `%`)
                // are NOT patched here: `ShaderRepair` fixes them from glslang's
                // line/column diagnostics, which is precise where a regex is not.
                line = reservedWordRegex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "we_$1")
                if !trimmed.hasPrefix("#") {
                    line = comboTernaryRegex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "(($1) != 0) ?")
                }
                line = textureIdentRegex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "we_texture")
            }
            lines[i] = line
        }
        return lines.joined(separator: "\n")
    }

    /// Builds the per-stage GLSL that is handed to glslang's preprocessor.
    public static func stage1(_ source: String, combos: [String: Int], stage: ShaderStage) -> String {
        var out = "#version 450\n"
        out += prelude
        for (k, v) in combos.sorted(by: { $0.key < $1.key }) {
            out += "#define \(k) \(v)\n"
        }
        // Strip #require lines; stub the lighting function WE would synthesize.
        var body = applySourceFixups(source)
        if body.contains("#require") {
            body = body.components(separatedBy: "\n").map { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("#require") ? "// \(line)" : line
            }.joined(separator: "\n")
            if stage == .fragment {
                out += "vec3 PerformLighting_V1(vec3 worldPos, vec3 albedo, vec3 normal, vec3 viewDir, vec3 specularTint, vec3 f0, float roughness, float metallic) { return vec3(0.0); }\n"
            }
        }
        out += "#line 1\n"
        out += body
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: Stage 2: finalize preprocessed GLSL for glslang/SPIRV-Cross

    public struct FinalizedProgram {
        public var vertex: String
        public var fragment: String
        public var attributeLocations: [String: Int]      // attribute name -> location
        public var attributeTypes: [String: String]
        public var varyingLocations: [String: Int]
        public var textureBindings: [String: Int]         // sampler name -> binding
    }

    private struct Decl {
        let type: String; let name: String; let line: Int; let array: String
        var arrayCount: Int {
            guard array.hasPrefix("["), let n = Int(array.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)) else { return array.isEmpty ? 1 : 4 }
            return min(4096, max(1, n))
        }
    }

    private static let attributeDeclRegex = try! NSRegularExpression(pattern: #"^\s*attribute\s+(?:(?:lowp|mediump|highp)\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*;"#)
    private static let varyingDeclRegex = try! NSRegularExpression(pattern: #"^\s*(?:flat\s+|smooth\s+|noperspective\s+)?varying\s+(?:(?:flat|smooth|noperspective)\s+)?(?:(?:lowp|mediump|highp)\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*;"#)
    private static let samplerDeclRegex = try! NSRegularExpression(pattern: #"^\s*uniform\s+(?:(?:lowp|mediump|highp)\s+)?(sampler2D|sampler2DShadow|samplerCube|sampler3D|sampler2DArray)\s+([A-Za-z_]\w*)\s*;"#)
    private static let mainRegex = try! NSRegularExpression(pattern: #"void\s+main\s*\(\s*(?:void)?\s*\)\s*\{"#)

    private static func decls(_ lines: [String], _ regex: NSRegularExpression) -> [Decl] {
        var out: [Decl] = []
        for (i, line) in lines.enumerated() {
            guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let t = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line) else { continue }
            let array = m.numberOfRanges > 3 ? (Range(m.range(at: 3), in: line).map { String(line[$0]) } ?? "") : ""
            out.append(Decl(type: String(line[t]), name: String(line[n]), line: i, array: array))
        }
        return out
    }

    private static func vectorSize(_ type: String) -> Int? {
        switch type {
        case "float", "int", "uint", "bool": return 1
        case "vec2", "ivec2", "uvec2", "bvec2": return 2
        case "vec3", "ivec3", "uvec3", "bvec3": return 3
        case "vec4", "ivec4", "uvec4", "bvec4": return 4
        default: return nil
        }
    }

    private static func conversion(from srcType: String, to dstType: String, expr: String) -> String {
        guard let s = vectorSize(srcType), let d = vectorSize(dstType) else { return "\(dstType)(\(expr))" }
        if s == d { return srcType == dstType ? expr : "\(dstType)(\(expr))" }
        if d > s {
            let extra = (s + 1...d).map { $0 == 4 ? "1.0" : "0.0" }.joined(separator: ", ")
            return "\(dstType)(\(expr), \(extra))"
        }
        let swz = String("xyzw".prefix(d))
        return d == 1 ? "\(expr).x" : "\(expr).\(swz)"
    }

    private static func stripVersionAndLine(_ source: String) -> [String] {
        source.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("#version") || t.hasPrefix("#extension") || t.hasPrefix("#line"))
        }
    }

    private static let globalInitRegex = try! NSRegularExpression(pattern: #"^\s*(?:const\s+)?(float|int|uint|bool|vec[234]|ivec[234]|mat[234])\s+([A-Za-z_]\w*)\s*=\s*(.+);\s*$"#)
    private static let uniformNameRegex = try! NSRegularExpression(pattern: #"^\s*(?:layout\s*\([^)]*\)\s*)?uniform\s+(?:(?:lowp|mediump|highp)\s+)?[A-Za-z_]\w*\s+([A-Za-z_]\w*)"#)

    /// Global variables initialised from uniforms are illegal in GLSL; turn them into
    /// plain globals assigned at the top of `main()`.
    static func hoistGlobalInitializers(_ lines: inout [String]) -> [String] {
        var uniformNames = Set<String>()
        for line in lines {
            if let m = uniformNameRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 1), in: line) {
                uniformNames.insert(String(line[r]))
            }
        }
        var assignments: [String] = []
        var depth = 0
        for i in lines.indices {
            let line = lines[i]
            if depth == 0, let m = globalInitRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let t = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line), let e = Range(m.range(at: 3), in: line) {
                let rhs = String(line[e])
                let identifiers = rhs.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                let dependsOnUniform = identifiers.contains { uniformNames.contains($0) || $0.hasPrefix("g_") || $0.hasPrefix("u_") } || rhs.contains("texture")
                if dependsOnUniform {
                    let name = String(line[n])
                    lines[i] = "\(line[t]) \(name);"
                    assignments.append("\(name) = \(rhs);")
                    // Hoisting is transitive: a later global initialised from this one now
                    // reads it before main() assigns it, so it has to be hoisted as well.
                    uniformNames.insert(name)
                }
            }
            for ch in line { if ch == "{" { depth += 1 } else if ch == "}" { depth = max(0, depth - 1) } }
        }
        return assignments
    }

    private static func insertPrologue(_ source: inout String, _ statements: [String]) {
        guard !statements.isEmpty,
              let m = mainRegex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let r = Range(m.range, in: source) else { return }
        source.replaceSubrange(r, with: String(source[r]) + "\n" + statements.joined(separator: "\n") + "\n")
    }

    public static func finalize(vertexPreprocessed: String, fragmentPreprocessed: String) -> FinalizedProgram {
        var vLines = stripVersionAndLine(vertexPreprocessed)
        var fLines = stripVersionAndLine(fragmentPreprocessed)
        let vHoisted = hoistGlobalInitializers(&vLines)
        let fHoisted = hoistGlobalInitializers(&fLines)

        // --- attributes ---
        var attributeLocations: [String: Int] = [:]
        var attributeTypes: [String: String] = [:]
        var nextAttr = 13
        for d in decls(vLines, attributeDeclRegex) {
            let loc: Int
            if let l = attributeLocations[d.name] { loc = l }
            else if let l = ShaderPreprocessor.attributeLocations[d.name] { loc = l }
            else { loc = nextAttr; nextAttr += 1 }
            attributeLocations[d.name] = loc
            attributeTypes[d.name] = d.type
            vLines[d.line] = "layout(location = \(loc)) in \(d.type) \(d.name)\(d.array);"
        }

        // --- varyings ---
        let vVaryings = decls(vLines, varyingDeclRegex)
        let fVaryings = decls(fLines, varyingDeclRegex)
        var varyingLocations: [String: Int] = [:]
        var next = 0
        for d in vVaryings + fVaryings where varyingLocations[d.name] == nil {
            varyingLocations[d.name] = next
            let perElement = vectorSize(d.type) == nil && d.type.hasPrefix("mat") ? 4 : 1
            next += perElement * d.arrayCount
        }
        var vTypes: [String: String] = [:]
        for d in vVaryings {
            guard let loc = varyingLocations[d.name] else { continue }
            vTypes[d.name] = d.type
            vLines[d.line] = "layout(location = \(loc)) out \(d.type) \(d.name)\(d.array);"
        }
        var fragmentPrologue: [String] = []
        var extraVertexOutputs: [String] = []
        for d in fVaryings {
            guard let loc = varyingLocations[d.name] else { continue }
            if let vt = vTypes[d.name] {
                if vt == d.type || !d.array.isEmpty {
                    fLines[d.line] = "layout(location = \(loc)) in \(vt) \(d.name)\(d.array);"
                } else {
                    // Interface mismatch: take the vertex type and convert into a global.
                    fLines[d.line] = "layout(location = \(loc)) in \(vt) \(d.name)_vin;\n\(d.type) \(d.name);"
                    fragmentPrologue.append("\(d.name) = \(conversion(from: vt, to: d.type, expr: "\(d.name)_vin"));")
                }
            } else {
                fLines[d.line] = "layout(location = \(loc)) in \(d.type) \(d.name)\(d.array);"
                extraVertexOutputs.append("layout(location = \(loc)) out \(d.type) \(d.name)\(d.array);")
            }
        }
        if !extraVertexOutputs.isEmpty {
            // Declare before main so the interface is complete; values are undefined but never read.
            vLines.insert(extraVertexOutputs.joined(separator: "\n"), at: 0)
        }

        // --- samplers ---
        var textureBindings: [String: Int] = [:]
        var nextSampler = 16
        func bindSamplers(_ lines: inout [String]) {
            for d in decls(lines, samplerDeclRegex) {
                let binding: Int
                if let b = textureBindings[d.name] { binding = b }
                else if d.name.hasPrefix("g_Texture"), let n = Int(d.name.dropFirst("g_Texture".count)) { binding = n }
                else { binding = nextSampler; nextSampler += 1 }
                textureBindings[d.name] = binding
                lines[d.line] = "layout(set = 0, binding = \(binding)) uniform \(d.type) \(d.name);"
            }
        }
        bindSamplers(&vLines)
        bindSamplers(&fLines)

        // --- fragment output + prologue ---
        var fragment = fLines.joined(separator: "\n")
        var fragmentHeader = "#version 450\n"
        if fragment.contains("gl_FragColor") {
            fragment = fragment.replacingOccurrences(of: "gl_FragColor", with: "out_FragColor")
            fragmentHeader += "layout(location = 0) out vec4 out_FragColor;\n"
        }
        if fragment.contains("gl_FragData") {
            fragment = fragment.replacingOccurrences(of: #"gl_FragData\s*\[\s*(\d)\s*\]"#, with: "out_FragData$1", options: .regularExpression)
            fragmentHeader += "layout(location = 0) out vec4 out_FragData0;\nlayout(location = 1) out vec4 out_FragData1;\n"
        }
        insertPrologue(&fragment, fragmentPrologue + fHoisted)
        fragment = fragmentHeader + fragment

        var vertex = vLines.joined(separator: "\n")
        insertPrologue(&vertex, vHoisted)
        vertex = "#version 450\n" + vertex
        return FinalizedProgram(vertex: vertex, fragment: fragment, attributeLocations: attributeLocations,
                                attributeTypes: attributeTypes, varyingLocations: varyingLocations, textureBindings: textureBindings)
    }
}

public enum ShaderStage { case vertex, fragment }
