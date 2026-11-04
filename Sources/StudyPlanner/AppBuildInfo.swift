import Foundation
import AppKit

/// Read only the running bundle. Never infer an installed app's identity from
/// the current checkout, which may have advanced since that app was built.
struct AppBuildInfo {
    let version: String
    let build: String
    let sourceIdentifier: String
    let sourceRevision: String
    let sourceFingerprint: String
    let sourceModified: Bool
    let builtAt: String
    let configuration: String

    init(info: [String: Any]) {
        func text(_ key: String) -> String {
            guard let value = info[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "未记录" }
            return value
        }
        version = text("CFBundleShortVersionString")
        build = text("CFBundleVersion")
        sourceIdentifier = text("StudyPlannerSourceIdentifier")
        sourceRevision = text("StudyPlannerSourceRevision")
        sourceFingerprint = text("StudyPlannerSourceFingerprint")
        sourceModified = info["StudyPlannerSourceModified"] as? Bool ?? false
        builtAt = text("StudyPlannerBuildDate")
        configuration = text("StudyPlannerBuildConfiguration")
    }

    static var current: AppBuildInfo { AppBuildInfo(info: Bundle.main.infoDictionary ?? [:]) }

    var versionDescription: String { "\(version)（构建 \(build)）" }
    var sourceDescription: String {
        "源码 \(sourceIdentifier)" + (sourceModified ? "（含未提交修改）" : "")
    }
    var buildDescription: String { "构建时间 \(builtAt)\n配置 \(configuration)" }
    var diagnosticDescription: String {
        "学习日程 \(versionDescription)\n\(sourceDescription)\n提交 \(sourceRevision)\n"
        + "源码指纹 \(sourceFingerprint)\n\(buildDescription)"
    }

    @MainActor func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "学习日程",
            .applicationVersion: versionDescription,
            .version: "",
            .credits: NSAttributedString(string: "\(sourceDescription)\n\(buildDescription)")
        ])
    }
}
