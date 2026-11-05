// swift-tools-version: 6.2
import PackageDescription

// Warnings fail every build, so none slips into the code: the gate can't see one in a file it doesn't recompile.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "Oops",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "oops", targets: ["Oops"]),
        .executable(name: "oops-eval", targets: ["OopsEval"])
    ],
    dependencies: [
        // Updates (D2). Pinned exactly: a new Sparkle is a reviewed change, with the update test rerun.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "OopsCore", swiftSettings: strict),
        // Async functions run where they are called unless marked @concurrent: the Accessibility actor
        // and the main actor are the only places work runs.
        // Sparkle.framework is embedded in Contents/Frameworks by the bundlers (build_and_run.sh, release_bundle.py).
        .executableTarget(
            name: "Oops",
            dependencies: ["OopsCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: strict + [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"), .enableUpcomingFeature("InferIsolatedConformances")
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "OopsEval", dependencies: ["OopsCore"], swiftSettings: strict),
        .testTarget(name: "OopsTests", dependencies: ["Oops"], swiftSettings: strict),
        .testTarget(name: "OopsCoreTests", dependencies: ["OopsCore"], swiftSettings: strict),
        .testTarget(name: "OopsEvalTests", dependencies: ["OopsEval"], swiftSettings: strict)
    ],
    swiftLanguageModes: [.v6]
)
