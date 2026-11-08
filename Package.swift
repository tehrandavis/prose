// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The iPad Xcode project uses Sources/Package.swift to resolve only the shared core.
// App Store and direct builds never resolve or link an external updater.
let preview = ProcessInfo.processInfo.environment["PROSE_DISTRIBUTION"] == "preview"
let distributionSettings: [SwiftSetting] = preview ? [.define("PROSE_PREVIEW")] : []
let updaterPackages: [Package.Dependency] = preview ? [.package(
    url: "https://github.com/sparkle-project/Sparkle.git",
    exact: "2.10.0",
)] : []
let updaterProducts: [Target.Dependency] = preview ? [.product(name: "Sparkle", package: "Sparkle")] : []

let package = Package(
    name: "Prose",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ProseCore", targets: ["ProseCore"]),
               .executable(name: "Prose", targets: ["ProseLauncher"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")] +
        updaterPackages,
    targets: [
        // The one Rust library in the app (Engine/RenderBridge): the per-block Typst
        // renderer, which also carries the typst-syntax bridge (Engine/SyntaxBridge),
        // so it exports both prose_render_api and lb_syntax_api. scripts/build-render.sh,
        // which scripts/bootstrap.sh runs, builds it before the first `swift build`.
        .binaryTarget(name: "ProseEngineLibrary", path: "Engine/RenderBridge/target/ProseEngine.xcframework"),
        // Header-only C modules for the two function tables.
        .target(name: "ProseSyntaxFFI", dependencies: ["ProseEngineLibrary"]),
        .target(name: "ProseRenderFFI", dependencies: ["ProseEngineLibrary"]),
        .target(
            name: "ProseCore",
            dependencies: ["ZIPFoundation", "ProseSyntaxFFI", "ProseRenderFFI"],
            resources: [.process("Resources"), .copy("AuthoringGuides")],
            swiftSettings: distributionSettings,
        ),
        .target(
            name: "ProseApp",
            dependencies: ["ProseCore"] + updaterProducts,
            path: "Sources/Prose",
            swiftSettings: distributionSettings,
        ),
        .executableTarget(
            name: "ProseLauncher",
            dependencies: ["ProseApp"],
            linkerSettings: preview ? [.unsafeFlags([
                "-Xlinker",
                "-rpath",
                "-Xlinker",
                "@executable_path/../Frameworks",
            ])] : [],
        ),
        .target(name: "ProseTestSupport", path: "Tests/Support"),
        .testTarget(name: "ProseCoreTests", dependencies: ["ProseCore", "ProseRenderFFI", "ProseTestSupport"]),
        .testTarget(
            name: "ProseAppTests",
            dependencies: ["ProseApp", "ProseCore", "ProseTestSupport"] +
                updaterProducts,
            swiftSettings: distributionSettings,
        ),
    ],
)
