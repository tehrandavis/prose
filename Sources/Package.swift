// swift-tools-version: 6.2
import PackageDescription

/// Xcode evaluates manifests on the Mac host, including for iPad destinations.
/// A separate fixed graph avoids resolving desktop dependencies for iPad builds.
/// Keep the package name so the shared resource bundle retains its identity.
let package = Package(
    name: "Prose",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    // A dynamic product gives Xcode a distinct coverage image for the shared Core.
    products: [.library(name: "ProseCore", type: .dynamic, targets: ["ProseCore"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        // Declarations only: the parser is part of the app's engine library, and the
        // app hands its function table to ProseCore (SyntaxTree.install).
        .target(name: "ProseSyntaxFFI", path: "ProseSyntaxFFI"),
        .target(
            name: "ProseCore",
            dependencies: ["ZIPFoundation", "ProseSyntaxFFI"],
            path: "ProseCore",
            resources: [.process("Resources"), .copy("AuthoringGuides")],
        ),
    ],
)
