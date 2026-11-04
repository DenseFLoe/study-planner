import Foundation

/// The shared directory keeps each CI run isolated and works across a Docker bind mount.
enum CrossLanguageFixture {
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["STUDY_CLOUD_FIXTURE_DIR"] ?? "/tmp")
            .appendingPathComponent(name)
    }
}
