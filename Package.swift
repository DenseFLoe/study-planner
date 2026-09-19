// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StudyPlanner",
    platforms: [.macOS(.v14)],
    products: [.library(name: "StudyCore", targets: ["StudyCore"]), .executable(name: "StudyPlanner", targets: ["StudyPlanner"])],
    targets: [
        .target(name: "StudyCore"),
        .target(name: "StudyPersistence", dependencies: ["StudyCore"]),
        .target(name: "StudySync", dependencies: ["StudyCore", "StudyPersistence"]),
        .executableTarget(name: "StudyPlanner", dependencies: ["StudyCore", "StudyPersistence", "StudySync"]),
        .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"]),
        .testTarget(name: "StudySyncTests", dependencies: ["StudySync", "StudyCore", "StudyPersistence"]),
        .testTarget(name: "StudyPersistenceTests", dependencies: ["StudyPersistence", "StudyCore"])
    ]
)
