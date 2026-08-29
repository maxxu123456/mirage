// swift-tools-version: 5.9
import PackageDescription

// Homebrew provides glslang (dylibs) and spirv-cross (static libs). The build
// script copies the dylibs into the .app bundle so the final app is relocatable.
let brewInclude = "/opt/homebrew/include"
let brewLib = "/opt/homebrew/lib"

let brewSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(brewInclude)"])]
let brewLinkerSettings: [LinkerSetting] = [.unsafeFlags(["-L\(brewLib)"]), .linkedLibrary("c++")]

let package = Package(
    name: "Mirage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Mirage", targets: ["Mirage"]),
        .executable(name: "wetool", targets: ["wetool"]),
        .library(name: "WEKit", targets: ["WEKit"]),
        .library(name: "MirageRender", targets: ["MirageRender"]),
    ],
    targets: [
        // C bindings for glslang + SPIRV-Cross (GLSL -> SPIR-V -> MSL).
        .systemLibrary(name: "CShaderTools", path: "Sources/CShaderTools"),

        // Pure-Swift Wallpaper Engine format support: .pkg containers, .tex
        // textures, project/scene/material/effect/particle JSON, user
        // properties and the WE-GLSL shader preprocessor.
        .target(name: "WEKit", path: "Sources/WEKit"),

        // Metal renderer for scene wallpapers.
        .target(
            name: "MirageRender",
            dependencies: ["WEKit", "CShaderTools"],
            path: "Sources/MirageRender",
            swiftSettings: brewSwiftSettings,
            linkerSettings: brewLinkerSettings
        ),

        // The macOS app.
        .executableTarget(
            name: "Mirage",
            dependencies: ["WEKit", "MirageRender"],
            path: "Sources/Mirage",
            swiftSettings: brewSwiftSettings + [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: brewLinkerSettings
        ),

        // Developer CLI: inspect packages, decode textures, compile shaders,
        // render a scene to PNG.
        .executableTarget(
            name: "wetool",
            dependencies: ["WEKit", "MirageRender"],
            path: "Sources/wetool",
            swiftSettings: brewSwiftSettings,
            linkerSettings: brewLinkerSettings
        ),

        .testTarget(name: "WEKitTests", dependencies: ["WEKit"], path: "Tests/WEKitTests"),

        .testTarget(
            name: "MirageRenderTests",
            dependencies: ["WEKit", "MirageRender"],
            path: "Tests/MirageRenderTests",
            swiftSettings: brewSwiftSettings,
            linkerSettings: brewLinkerSettings
        ),
    ]
)
