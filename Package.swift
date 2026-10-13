// swift-tools-version: 6.4

import PackageDescription

let sherpaLib = Context.packageDirectory + "/vendor/sherpa-onnx/lib"

let package = Package(
    name: "Keyless",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeylessCore", targets: ["KeylessCore"]),
        .executable(name: "Keyless", targets: ["Keyless"]),
    ],
    targets: [
        // Pure logic with no AppKit, audio or network dependencies, so it can be replay-tested.
        .target(name: "KeylessCore"),
        // sherpa-onnx's C API, for on-device speaker verification. Fetched by scripts/fetch-sherpa.sh.
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        .executableTarget(
            name: "Keyless",
            dependencies: ["KeylessCore", "CSherpaOnnx"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", sherpaLib,
                    // Bundled app: dylibs live in Contents/Frameworks. Development runs: the vendor folder.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", sherpaLib,
                ]),
            ]
        ),
        .testTarget(name: "KeylessCoreTests", dependencies: ["KeylessCore"]),
    ]
)
