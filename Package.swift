// swift-tools-version: 6.2
import PackageDescription

// Warnings fail every build, so none slips into the code: the gate can't see one in a file it doesn't recompile.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

// OOPS_PREVIEW=1 is the only way the speech engine reaches the app: without it the oops binary neither links nor
// names CTranscribe, and the bundlers refuse a bundle that carries it. Preview builds use their own scratch path
// (.build/preview, .build/packaging/<arch>-preview) so switching doesn't rebuild the normal one.
let preview = Context.environment["OOPS_PREVIEW"] == "1"

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
        // Sparkle.framework is embedded in Contents/Frameworks by the bundlers (build_and_run.sh, release_bundle.py),
        // and CTranscribe.framework beside it in a preview build.
        .executableTarget(
            name: "Oops",
            dependencies: ["OopsCore", .product(name: "Sparkle", package: "Sparkle")] + (preview ? ["OopsEngine"] : []),
            swiftSettings: strict + [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"), .enableUpcomingFeature("InferIsolatedConformances")
            ] + (preview ? [.define("OOPS_PREVIEW")] : []),
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "OopsEval", dependencies: ["OopsCore"], swiftSettings: strict),
        // transcribe.cpp at the revision Hex pins, built by our fork's workflow: upstream's own build keeps the CPU
        // waking for the life of the process. A universal dynamic framework; the bundlers thin it to arm64.
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/0xmrwn/transcribe.cpp/releases/download/oops-0.4.1-1/TranscribeCpp.xcframework.zip",
            checksum: "01921b83e68c4b6e6921a21121efc39aea5f60a3c8593958960b5d1c90d3affc"
        ),
        // Always built and tested, whatever the option: only the app's dependency on it is conditional.
        .target(name: "OopsEngine", dependencies: ["OopsCore", "CTranscribe"], swiftSettings: strict),
        .testTarget(name: "OopsTests", dependencies: ["Oops"], swiftSettings: strict),
        .testTarget(name: "OopsCoreTests", dependencies: ["OopsCore"], swiftSettings: strict),
        .testTarget(name: "OopsEvalTests", dependencies: ["OopsEval"], swiftSettings: strict),
        .testTarget(name: "OopsEngineTests", dependencies: ["OopsEngine"], exclude: ["Fixtures"], swiftSettings: strict)
    ],
    swiftLanguageModes: [.v6]
)
