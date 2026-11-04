// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
// The portable model/engine suite can run without waiting for a macOS runner.
// SwiftData, AppKit and the desktop executable remain macOS-only targets below.
let package = Package(
    name: "StudyPlanner",
    products: [.library(name: "StudyCore", targets: ["StudyCore"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.9.1")],
    targets: [
        .systemLibrary(name: "zlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
        .target(name: "StudyCore", dependencies: ["zlib", .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"])
    ]
)
#else
let package = Package(
    name: "StudyPlanner",
    platforms: [.macOS(.v14)],
    products: [.library(name: "StudyCore", targets: ["StudyCore"]), .executable(name: "StudyPlanner", targets: ["StudyPlanner"])],
    targets: [
        .target(name: "StudyCore"),
        .target(name: "StudyPersistence", dependencies: ["StudyCore"]),
        .target(name: "StudySync", dependencies: ["StudyCore", "StudyPersistence"]),
        .executableTarget(name: "StudyPlanner", dependencies: ["StudyCore", "StudyPersistence", "StudySync"], resources: [.process("Resources")]),
        .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"]),
        .testTarget(name: "StudyPlannerTests", dependencies: ["StudyPlanner"]),
        .testTarget(name: "StudySyncTests", dependencies: ["StudySync", "StudyCore", "StudyPersistence"]),
        .testTarget(name: "StudyPersistenceTests", dependencies: ["StudyPersistence", "StudyCore"])
    ]
)
#endif
