import Foundation
import CShaderTools
import CryptoKit
import WEKit

/// A parse failure in one stage, carrying the raw glslang log so the repair
/// pass can act on it.
struct StageCompileError: Error {
    let stage: ShaderStage
    let log: String
    let source: String
}

public enum ShaderCompileError: Error, CustomStringConvertible {
    case preprocess(String)
    case parse(String)
    case link(String)
    case spirv(String)
    case spirvCross(String)

    public var description: String {
        switch self {
        case .preprocess(let s): return "preprocess: \(s)"
        case .parse(let s): return "parse: \(s)"
        case .link(let s): return "link: \(s)"
        case .spirv(let s): return "spirv: \(s)"
        case .spirvCross(let s): return "spirv-cross: \(s)"
        }
    }
}

/// Compiles Wallpaper Engine GLSL to Metal Shading Language via glslang and
/// SPIRV-Cross, returning the MSL plus reflection data needed to bind
/// uniforms, textures and vertex attributes.
public final class ShaderCompiler {
    public static let shared = ShaderCompiler()

    public struct UniformMember: Codable, Hashable {
        public let name: String
        public let offset: Int
        public let baseType: String       // "float", "int", "uint", "bool"
        public let vecSize: Int
        public let columns: Int
        public let arrayLength: Int       // 0 when not an array
        public let arrayStride: Int
        public let matrixStride: Int
    }

    public struct UniformBlock: Codable, Hashable {
        public let bufferIndex: Int
        public let size: Int
        public let members: [UniformMember]
    }

    public struct TextureBinding: Codable, Hashable {
        public let name: String
        public let index: Int
        public let isDepth: Bool
    }

    public struct VertexInput: Codable, Hashable {
        public let name: String
        public let location: Int
        public let vecSize: Int
        public let baseType: String
    }

    public struct Stage: Codable, Hashable {
        public let msl: String
        public let entryPoint: String
        public let uniforms: UniformBlock?
        public let textures: [TextureBinding]
        public let inputs: [VertexInput]
    }

    public struct Program: Codable, Hashable {
        public let vertex: Stage
        public let fragment: Stage
        public let attributeLocations: [String: Int]
        public let attributeTypes: [String: String]
        public let glslVertex: String
        public let glslFragment: String
        /// HLSL-compatibility edits the repair pass had to make, for diagnostics.
        public var repairs: [String] = []

        public func member(_ name: String, in stage: Stage) -> UniformMember? {
            stage.uniforms?.members.first { $0.name == name }
        }
    }

    public var cacheDirectory: URL? = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("Mirage/shaders")
    }()

    /// How many HLSL-compatibility repairs to attempt before giving up on a shader.
    public static let maxRepairAttempts = 24
    private static let cacheVersion = "mirage-shader-cache-v2"

    private let lock = NSLock()
    private var memoryCache: [String: Program] = [:]
    private let initialized: Bool

    private init() {
        initialized = glslang_initialize_process() != 0
        if let dir = cacheDirectory { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    // MARK: Public API

    /// Full pipeline: WE GLSL (with includes expanded) + combos → MSL program.
    public func compile(source: ShaderProgramSource, combos: [String: Int]) throws -> Program {
        lock.lock(); defer { lock.unlock() }
        guard initialized else { throw ShaderCompileError.preprocess("glslang initialization failed") }

        let v1 = ShaderPreprocessor.stage1(source.vertex, combos: combos, stage: .vertex)
        let f1 = ShaderPreprocessor.stage1(source.fragment, combos: combos, stage: .fragment)
        let key = ShaderCompiler.hash(ShaderCompiler.cacheVersion + "\u{0}" + v1 + "\u{1}" + f1)
        if let p = memoryCache[key] { return p }
        if let p = loadCached(key) { memoryCache[key] = p; return p }

        let vp = try preprocess(v1, stage: GLSLANG_STAGE_VERTEX, label: source.name + ".vert")
        let fp = try preprocess(f1, stage: GLSLANG_STAGE_FRAGMENT, label: source.name + ".frag")
        let fin = ShaderPreprocessor.finalize(vertexPreprocessed: vp, fragmentPreprocessed: fp)

        // Compile, and where the shader relies on HLSL's implicit conversions,
        // let glslang's line/column diagnostics drive a targeted repair and retry.
        var vertexSource = fin.vertex
        var fragmentSource = fin.fragment
        var repairs: [String] = []
        var spirv: ([UInt32], [UInt32])? = nil
        for _ in 0..<ShaderCompiler.maxRepairAttempts {
            do {
                spirv = try compileSPIRV(vertex: vertexSource, fragment: fragmentSource, label: source.name)
                break
            } catch let stageError as StageCompileError {
                let diagnostics = ShaderRepair.parse(log: stageError.log)
                guard let (repaired, note) = ShaderRepair.apply(diagnostics: diagnostics, to: stageError.source),
                      repaired != stageError.source else {
                    throw ShaderCompileError.parse("\(source.name).\(stageError.stage == .vertex ? "vert" : "frag"): \(stageError.log)\n\(ShaderCompiler.numbered(stageError.source))")
                }
                repairs.append("\(stageError.stage == .vertex ? "vert" : "frag") \(note)")
                if stageError.stage == .vertex { vertexSource = repaired } else { fragmentSource = repaired }
            }
        }
        guard let (vspv, fspv) = spirv else {
            throw ShaderCompileError.parse("\(source.name): still failing after \(ShaderCompiler.maxRepairAttempts) repair attempts: \(repairs)")
        }
        let vstage = try crossCompile(vspv, stage: .vertex)
        let fstage = try crossCompile(fspv, stage: .fragment)
        var program = Program(vertex: vstage, fragment: fstage, attributeLocations: fin.attributeLocations,
                              attributeTypes: fin.attributeTypes, glslVertex: vertexSource, glslFragment: fragmentSource)
        program.repairs = repairs
        memoryCache[key] = program
        storeCached(key, program)
        return program
    }

    /// Debug helper: returns the finalized GLSL 450 for a shader.
    public func finalizedGLSL(source: ShaderProgramSource, combos: [String: Int]) throws -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        guard initialized else { throw ShaderCompileError.preprocess("glslang initialization failed") }
        let v1 = ShaderPreprocessor.stage1(source.vertex, combos: combos, stage: .vertex)
        let f1 = ShaderPreprocessor.stage1(source.fragment, combos: combos, stage: .fragment)
        let vp = try preprocess(v1, stage: GLSLANG_STAGE_VERTEX, label: source.name + ".vert")
        let fp = try preprocess(f1, stage: GLSLANG_STAGE_FRAGMENT, label: source.name + ".frag")
        let fin = ShaderPreprocessor.finalize(vertexPreprocessed: vp, fragmentPreprocessed: fp)
        return (fin.vertex, fin.fragment)
    }

    // MARK: Cache

    static func hash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadCached(_ key: String) -> Program? {
        guard let dir = cacheDirectory else { return nil }
        let url = dir.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Program.self, from: data)
    }

    private func storeCached(_ key: String, _ program: Program) {
        guard let dir = cacheDirectory, let data = try? JSONEncoder().encode(program) else { return }
        try? data.write(to: dir.appendingPathComponent(key + ".json"), options: .atomic)
    }

    // MARK: glslang

    private static func cString(_ pointer: UnsafePointer<CChar>?, fallback: String) -> String {
        guard let pointer else { return fallback }
        return String(cString: pointer)
    }

    /// Wallpaper Engine shaders are written against HLSL-ish rules, so relax
    /// glslang's GLSL semantics and drop the deprecation warnings.
    static let messageMask: UInt32 =
        GLSLANG_MSG_SPV_RULES_BIT.rawValue | GLSLANG_MSG_VULKAN_RULES_BIT.rawValue
        | GLSLANG_MSG_RELAXED_ERRORS_BIT.rawValue | GLSLANG_MSG_SUPPRESS_WARNINGS_BIT.rawValue
        | GLSLANG_MSG_ENHANCED.rawValue | GLSLANG_MSG_DISPLAY_ERROR_COLUMN.rawValue

    private func makeInput(_ code: UnsafePointer<CChar>, stage: glslang_stage_t) throws -> glslang_input_t {
        guard let resource = glslang_default_resource() else {
            throw ShaderCompileError.preprocess("glslang default resources unavailable")
        }
        var input = glslang_input_t()
        input.language = GLSLANG_SOURCE_GLSL
        input.stage = stage
        input.client = GLSLANG_CLIENT_VULKAN
        input.client_version = GLSLANG_TARGET_VULKAN_1_1
        input.target_language = GLSLANG_TARGET_SPV
        input.target_language_version = GLSLANG_TARGET_SPV_1_3
        input.code = code
        input.default_version = 450
        input.default_profile = GLSLANG_CORE_PROFILE
        input.force_default_version_and_profile = 0
        input.forward_compatible = 0
        input.messages = glslang_messages_t(rawValue: ShaderCompiler.messageMask)
        input.resource = resource
        return input
    }

    private func preprocess(_ source: String, stage: glslang_stage_t, label: String) throws -> String {
        try source.withCString { code in
            var input = try makeInput(code, stage: stage)
            guard let shader = glslang_shader_create(&input) else { throw ShaderCompileError.preprocess("glslang_shader_create failed") }
            defer { glslang_shader_delete(shader) }
            glslang_shader_set_options(shader, Int32(GLSLANG_SHADER_VULKAN_RULES_RELAXED.rawValue | GLSLANG_SHADER_AUTO_MAP_BINDINGS.rawValue | GLSLANG_SHADER_AUTO_MAP_LOCATIONS.rawValue))
            guard glslang_shader_preprocess(shader, &input) != 0 else {
                let log = ShaderCompiler.cString(glslang_shader_get_info_log(shader), fallback: "no diagnostic")
                throw ShaderCompileError.preprocess("\(label): \(log)\n\(ShaderCompiler.numbered(source))")
            }
            guard let code = glslang_shader_get_preprocessed_code(shader) else {
                throw ShaderCompileError.preprocess("\(label): glslang returned no preprocessed source")
            }
            return String(cString: code)
        }
    }

    private func compileSPIRV(vertex: String, fragment: String, label: String) throws -> ([UInt32], [UInt32]) {
        try vertex.withCString { vcode in
            try fragment.withCString { fcode in
                var vinput = try makeInput(vcode, stage: GLSLANG_STAGE_VERTEX)
                var finput = try makeInput(fcode, stage: GLSLANG_STAGE_FRAGMENT)
                guard let vs = glslang_shader_create(&vinput) else { throw ShaderCompileError.parse("vertex shader creation failed") }
                defer { glslang_shader_delete(vs) }
                guard let fs = glslang_shader_create(&finput) else { throw ShaderCompileError.parse("fragment shader creation failed") }
                defer { glslang_shader_delete(fs) }
                let opts = Int32(GLSLANG_SHADER_VULKAN_RULES_RELAXED.rawValue | GLSLANG_SHADER_AUTO_MAP_BINDINGS.rawValue | GLSLANG_SHADER_AUTO_MAP_LOCATIONS.rawValue)
                for s in [vs, fs] {
                    glslang_shader_set_options(s, opts)
                    glslang_shader_set_default_uniform_block_set_and_binding(s, 0, 0)
                    glslang_shader_set_default_uniform_block_name(s, "WEUniforms")
                }
                guard glslang_shader_preprocess(vs, &vinput) != 0, glslang_shader_parse(vs, &vinput) != 0 else {
                    throw StageCompileError(stage: .vertex,
                                            log: ShaderCompiler.cString(glslang_shader_get_info_log(vs), fallback: "no diagnostic"),
                                            source: vertex)
                }
                guard glslang_shader_preprocess(fs, &finput) != 0, glslang_shader_parse(fs, &finput) != 0 else {
                    throw StageCompileError(stage: .fragment,
                                            log: ShaderCompiler.cString(glslang_shader_get_info_log(fs), fallback: "no diagnostic"),
                                            source: fragment)
                }
                guard let program = glslang_program_create() else { throw ShaderCompileError.link("glslang_program_create failed") }
                defer { glslang_program_delete(program) }
                glslang_program_add_shader(program, vs)
                glslang_program_add_shader(program, fs)
                let messages = Int32(bitPattern: ShaderCompiler.messageMask)
                guard glslang_program_link(program, messages) != 0 else {
                    let log = ShaderCompiler.cString(glslang_program_get_info_log(program), fallback: "no diagnostic")
                    throw ShaderCompileError.link("\(label): \(log)")
                }
                guard glslang_program_map_io(program) != 0 else {
                    let log = ShaderCompiler.cString(glslang_program_get_info_log(program), fallback: "no diagnostic")
                    throw ShaderCompileError.link("\(label): map_io failed: \(log)")
                }
                func spirv(_ stage: glslang_stage_t) throws -> [UInt32] {
                    glslang_program_SPIRV_generate(program, stage)
                    let size = glslang_program_SPIRV_get_size(program)
                    guard size > 0, size <= 16 * 1024 * 1024 else {
                        throw ShaderCompileError.spirv("invalid SPIR-V size \(size) for \(label)")
                    }
                    var words = [UInt32](repeating: 0, count: size)
                    words.withUnsafeMutableBufferPointer { buffer in
                        glslang_program_SPIRV_get(program, buffer.baseAddress)
                    }
                    if let msg = glslang_program_SPIRV_get_messages(program) {
                        let s = String(cString: msg)
                        if !s.isEmpty && s.lowercased().contains("error") { throw ShaderCompileError.spirv(s) }
                    }
                    return words
                }
                return (try spirv(GLSLANG_STAGE_VERTEX), try spirv(GLSLANG_STAGE_FRAGMENT))
            }
        }
    }

    // MARK: SPIRV-Cross

    private func crossCompile(_ spirv: [UInt32], stage: ShaderStage) throws -> Stage {
        guard !spirv.isEmpty else { throw ShaderCompileError.spirvCross("empty SPIR-V") }
        var context: spvc_context? = nil
        guard spvc_context_create(&context) == SPVC_SUCCESS, let ctx = context else { throw ShaderCompileError.spirvCross("context") }
        defer { spvc_context_destroy(ctx) }

        var ir: spvc_parsed_ir? = nil
        guard spirv.withUnsafeBufferPointer({ spvc_context_parse_spirv(ctx, $0.baseAddress, spirv.count, &ir) }) == SPVC_SUCCESS,
              let parsedIR = ir else {
            let error = ShaderCompiler.cString(spvc_context_get_last_error_string(ctx), fallback: "no diagnostic")
            throw ShaderCompileError.spirvCross("parse: \(error)")
        }
        var compiler: spvc_compiler? = nil
        guard spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, parsedIR, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler) == SPVC_SUCCESS,
              let comp = compiler else {
            let error = ShaderCompiler.cString(spvc_context_get_last_error_string(ctx), fallback: "no diagnostic")
            throw ShaderCompileError.spirvCross("compiler: \(error)")
        }

        func requireSuccess(_ result: spvc_result, _ operation: String) throws {
            guard result == SPVC_SUCCESS else {
                let error = ShaderCompiler.cString(spvc_context_get_last_error_string(ctx), fallback: "no diagnostic")
                throw ShaderCompileError.spirvCross("\(operation): \(error)")
            }
        }

        var options: spvc_compiler_options? = nil
        try requireSuccess(spvc_compiler_create_compiler_options(comp, &options), "create options")
        guard let options else { throw ShaderCompileError.spirvCross("create options returned nil") }
        try requireSuccess(spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_VERSION, 2 * 10000 + 3 * 100), "set MSL version")
        try requireSuccess(spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_PLATFORM, UInt32(SPVC_MSL_PLATFORM_MACOS.rawValue)), "set MSL platform")
        try requireSuccess(spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_FLIP_VERTEX_Y, SPVC_TRUE), "set vertex orientation")
        try requireSuccess(spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, SPVC_TRUE), "set binding decorations")
        try requireSuccess(spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_MSL_PAD_FRAGMENT_OUTPUT_COMPONENTS, SPVC_TRUE), "set fragment padding")
        try requireSuccess(spvc_compiler_install_compiler_options(comp, options), "install options")

        var mslPtr: UnsafePointer<CChar>? = nil
        guard spvc_compiler_compile(comp, &mslPtr) == SPVC_SUCCESS, let mslC = mslPtr else {
            let error = ShaderCompiler.cString(spvc_context_get_last_error_string(ctx), fallback: "no diagnostic")
            throw ShaderCompileError.spirvCross("compile: \(error)")
        }
        let msl = String(cString: mslC)

        var resources: spvc_resources? = nil
        guard spvc_compiler_create_shader_resources(comp, &resources) == SPVC_SUCCESS, let resources else {
            let error = ShaderCompiler.cString(spvc_context_get_last_error_string(ctx), fallback: "no diagnostic")
            throw ShaderCompileError.spirvCross("resources: \(error)")
        }

        // Uniform buffer (default uniform block).
        var uniforms: UniformBlock? = nil
        var list: UnsafePointer<spvc_reflected_resource>? = nil
        var count = 0
        try requireSuccess(spvc_resources_get_resource_list_for_type(resources, SPVC_RESOURCE_TYPE_UNIFORM_BUFFER, &list, &count), "uniform resources")
        guard count >= 0, count <= 4096, count == 0 || list != nil else {
            throw ShaderCompileError.spirvCross("invalid uniform resource list")
        }
        if let list, count > 0 {
            let res = list[0]
            let bufferIndex = Int(spvc_compiler_get_decoration(comp, res.id, SpvDecorationBinding))
            guard (0..<BufferIndex.zeroFill).contains(bufferIndex) else {
                throw ShaderCompileError.spirvCross("invalid uniform buffer index \(bufferIndex)")
            }
            guard let type = spvc_compiler_get_type_handle(comp, res.base_type_id) else {
                throw ShaderCompileError.spirvCross("uniform block type")
            }
            var size = 0
            try requireSuccess(spvc_compiler_get_declared_struct_size(comp, type, &size), "uniform block size")
            guard size >= 0, size <= UniformWriter.maximumByteCount else {
                throw ShaderCompileError.spirvCross("invalid uniform block size \(size)")
            }
            let n = spvc_type_get_num_member_types(type)
            guard n <= 4096 else { throw ShaderCompileError.spirvCross("too many uniform members") }
            var members: [UniformMember] = []
            for i in 0..<n {
                let memberTypeId = spvc_type_get_member_type(type, i)
                guard let mtype = spvc_compiler_get_type_handle(comp, memberTypeId) else {
                    throw ShaderCompileError.spirvCross("uniform member type")
                }
                let name = ShaderCompiler.cString(spvc_compiler_get_member_name(comp, res.base_type_id, i), fallback: "member_\(i)")
                var offset: UInt32 = 0
                try requireSuccess(spvc_compiler_type_struct_member_offset(comp, type, i, &offset), "uniform member offset")
                var arrayStride: UInt32 = 0
                var matrixStride: UInt32 = 0
                let dims = spvc_type_get_num_array_dimensions(mtype)
                guard dims <= 1 else { throw ShaderCompileError.spirvCross("multidimensional uniform array") }
                var arrayLength = 0
                if dims > 0 {
                    arrayLength = Int(spvc_type_get_array_dimension(mtype, 0))
                    try requireSuccess(spvc_compiler_type_struct_member_array_stride(comp, type, i, &arrayStride), "uniform array stride")
                }
                let columns = Int(spvc_type_get_columns(mtype))
                let vectorSize = Int(spvc_type_get_vector_size(mtype))
                guard (1...4).contains(columns), (1...4).contains(vectorSize),
                      arrayLength <= size / 4 + 1 else {
                    throw ShaderCompileError.spirvCross("invalid uniform member shape")
                }
                if columns > 1 {
                    try requireSuccess(spvc_compiler_type_struct_member_matrix_stride(comp, type, i, &matrixStride), "uniform matrix stride")
                }
                let base: String
                switch spvc_type_get_basetype(mtype) {
                case SPVC_BASETYPE_FP32: base = "float"
                case SPVC_BASETYPE_INT32: base = "int"
                case SPVC_BASETYPE_UINT32: base = "uint"
                case SPVC_BASETYPE_BOOLEAN: base = "bool"
                default: base = "float"
                }
                members.append(UniformMember(name: name, offset: Int(offset), baseType: base,
                                             vecSize: vectorSize, columns: columns,
                                             arrayLength: arrayLength, arrayStride: Int(arrayStride), matrixStride: Int(matrixStride)))
            }
            uniforms = UniformBlock(bufferIndex: bufferIndex, size: size, members: members)
        }

        // Textures.
        var textures: [TextureBinding] = []
        var imgList: UnsafePointer<spvc_reflected_resource>? = nil
        var imgCount = 0
        try requireSuccess(spvc_resources_get_resource_list_for_type(resources, SPVC_RESOURCE_TYPE_SAMPLED_IMAGE, &imgList, &imgCount), "image resources")
        guard imgCount >= 0, imgCount <= 4096, imgCount == 0 || imgList != nil else {
            throw ShaderCompileError.spirvCross("invalid image resource list")
        }
        if let imgList {
            for i in 0..<imgCount {
                let r = imgList[i]
                let index = Int(spvc_compiler_get_decoration(comp, r.id, SpvDecorationBinding))
                guard (0..<128).contains(index) else {
                    throw ShaderCompileError.spirvCross("invalid texture binding \(index)")
                }
                guard let type = spvc_compiler_get_type_handle(comp, r.type_id) else {
                    throw ShaderCompileError.spirvCross("image resource type")
                }
                let isDepth = spvc_type_get_image_is_depth(type) == SPVC_TRUE
                let name = ShaderCompiler.cString(r.name, fallback: "texture_\(i)")
                textures.append(TextureBinding(name: name, index: index, isDepth: isDepth))
            }
        }

        // Stage inputs (vertex attributes).
        var inputs: [VertexInput] = []
        if stage == .vertex {
            var inList: UnsafePointer<spvc_reflected_resource>? = nil
            var inCount = 0
            try requireSuccess(spvc_resources_get_resource_list_for_type(resources, SPVC_RESOURCE_TYPE_STAGE_INPUT, &inList, &inCount), "stage inputs")
            guard inCount >= 0, inCount <= 4096, inCount == 0 || inList != nil else {
                throw ShaderCompileError.spirvCross("invalid stage input list")
            }
            if let inList {
                for i in 0..<inCount {
                    let r = inList[i]
                    let location = Int(spvc_compiler_get_decoration(comp, r.id, SpvDecorationLocation))
                    guard (0..<31).contains(location) else {
                        throw ShaderCompileError.spirvCross("invalid vertex location \(location)")
                    }
                    guard let type = spvc_compiler_get_type_handle(comp, r.type_id) else {
                        throw ShaderCompileError.spirvCross("stage input type")
                    }
                    let base: String
                    switch spvc_type_get_basetype(type) {
                    case SPVC_BASETYPE_INT32: base = "int"
                    case SPVC_BASETYPE_UINT32: base = "uint"
                    default: base = "float"
                    }
                    let name = ShaderCompiler.cString(r.name, fallback: "input_\(i)")
                    inputs.append(VertexInput(name: name, location: location,
                                              vecSize: Int(spvc_type_get_vector_size(type)), baseType: base))
                }
            }
        }
        return Stage(msl: msl, entryPoint: "main0", uniforms: uniforms, textures: textures, inputs: inputs)
    }

    static func numbered(_ s: String) -> String {
        s.components(separatedBy: "\n").enumerated().map { String(format: "%4d  %@", $0.offset + 1, $0.element) }.joined(separator: "\n")
    }
}
