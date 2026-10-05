import SwiftUI
import AppKit
import StudyCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    weak var store: PlannerStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.orderSaveBusy else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await store.waitForOrderSave()) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
struct StudyPlannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = PlannerStore()
    var body: some Scene {
        WindowGroup("学习日程") {
            MainView(store: store).frame(minWidth: 1060, minHeight: 700).tint(.blue)
                .onAppear { delegate.store = store }
        }.defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("学习计划") {
                Button("重新计算未来计划") { store.replan() }.keyboardShortcut("r")
                Button("确认学习完成情况") { store.showDailyReview = true }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

/// `--netdisk-probe <分享链接>` reads a share headlessly and prints the courses, the ordering and
/// the duplicate report. It is also the fastest way to check a real link without opening the app.
@main enum NetdiskProbeMain {
    static func main() async {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--netdisk-probe"), arguments.indices.contains(index + 1) {
            await probe(link: arguments[index + 1], passcode: nextArgument(after: index + 1, in: arguments))
            return
        }
        if let index = arguments.firstIndex(of: "--netdisk-fixture"), arguments.indices.contains(index + 1) {
            probeFixture(path: arguments[index + 1])
            return
        }
        // The app path is untouched by the probe: start the SwiftUI application normally.
        StudyPlannerApp.main()
    }

    private static func nextArgument(after index: Int, in arguments: [String]) -> String? {
        guard arguments.indices.contains(index + 1), arguments[index + 1] != "--netdisk-probe" else { return nil }
        let candidate = arguments[index + 1]
        return candidate.hasPrefix("--") ? nil : candidate
    }

    private static func probe(link: String, passcode: String?) async {
        print("夸克网盘探针")
        guard let parsed = NetdiskLink.parse(link) else {
            print("✗ 链接无法识别，请给 pan.quark.cn/s/<分享码> 形式的 HTTPS 链接。")
            exit(1)
        }
        let transport = PlainNetdiskTransport()
        let crawler = NetdiskCrawler(transport: transport, onProgress: { progress in
            guard progress.foldersRead > 0 else { return }
            FileHandle.standardError.write(("… \(progress.detail)（已读 \(progress.foldersRead) 个目录，\(progress.videosSeen) 个视频）\n")
                .data(using: .utf8)!)
        })
        do {
            let result = try await crawler.crawl(link: parsed, passcode: passcode, sourceURL: link,
                                                 existingCourses: [], now: Date())
            if let path = ProcessInfo.processInfo.environment["STUDY_NETDISK_DUMP"] {
                var safeEntries = result.entries
                for index in safeEntries.indices { safeEntries[index].shareToken = "" }
                let fixture = ProbeFixture(pwdID: result.scan.pwdID, title: result.scan.title,
                                           sourceURL: result.scan.sourceURL, entries: safeEntries)
                try JSONEncoder().encode(fixture).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            display(result)
        } catch {
            print("✗ 抓取失败：\(error.localizedDescription)")
            exit(2)
        }
    }

    private struct ProbeFixture: Codable {
        var pwdID: String
        var title: String
        var sourceURL: String
        var entries: [NetdiskEntry]
    }

    private static func probeFixture(path: String) {
        do {
            let fixture = try JSONDecoder().decode(ProbeFixture.self,
                                                   from: Data(contentsOf: URL(fileURLWithPath: path)))
            let outcome = NetdiskDigest.digest(entries: fixture.entries, rootTitle: fixture.title,
                                               pwdID: fixture.pwdID)
            let scan = NetdiskScan(pwdID: fixture.pwdID, passcodeProtected: false,
                                   title: fixture.title, sourceURL: fixture.sourceURL,
                                   fetchedAt: Date(), root: outcome.root, packages: outcome.packages,
                                   totalVideoCount: outcome.totalVideoCount, totalBytes: outcome.totalBytes,
                                   totalSeconds: outcome.totalSeconds, unreadFolders: outcome.unreadFolders,
                                   issues: outcome.issues)
            let duplicates = NetdiskDedup.scan(packages: outcome.packages)
            let courses = outcome.packages.compactMap {
                NetdiskSnapshotBuilder.build(package: NetdiskDedup.removingSafeCopies(from: $0, report: duplicates),
                                             scan: scan)
            }
            display(NetdiskCrawler.Result(scan: scan, duplicates: duplicates,
                                          courses: courses, entries: fixture.entries))
        } catch {
            print("✗ 读取离线清单失败：\(error.localizedDescription)")
            exit(2)
        }
    }

    private static func display(_ result: NetdiskCrawler.Result) {
            print("分享：《\(result.scan.displayName)》")
            print("来源：\(result.scan.sourceURL)")
            print("统计：\(result.scan.packages.count) 门课程候选 · \(result.scan.totalVideoCount) 个视频 · "
                + "共 \(Self.bytes(result.scan.totalBytes)) · 约 \(Self.clock(result.scan.totalSeconds))")
            if result.scan.unreadFolders > 0 {
                print("⚠ 有 \(result.scan.unreadFolders) 个目录未读完。")
            }
            for issue in result.scan.issues { print("⚠ \(issue)") }
            print("")
            for course in result.courses {
                let duration = Self.clock(course.snapshot.totalSeconds)
                let notes = course.notes.isEmpty ? "" : "　← " + course.notes.joined(separator: "；")
                if let refusal = course.refusal {
                    print("✗ \(course.name)：\(refusal)")
                    continue
                }
                print("✓ \(course.name)")
                print("　　\(course.videoCount) 节 · \(duration) · \(Self.bytes(course.totalBytes))"
                    + (course.estimatedLessons > 0 ? " · 其中 \(course.estimatedLessons) 节时长按中位数估算" : "")
                    + notes)
                let preview = course.snapshot.lessons.prefix(3).map(\.name).joined(separator: "、")
                if course.videoCount > 3 {
                    print("　　顺序：\(preview) … 共 \(course.videoCount) 节（按目录与集数自然排序）")
                } else if !preview.isEmpty {
                    print("　　顺序：\(preview)")
                }
            }
            if result.courses.isEmpty { print("（没有识别出可导入的课程）") }
            if !result.unassignedVideos.isEmpty {
                print("未归入课程的视频：\(result.unassignedVideos.count) 个")
                for video in result.unassignedVideos.prefix(5) { print("　\(video.relativePath)") }
            }
            let report = result.duplicates
            if !report.isEmpty {
                print("")
                print("查重：检查 \(report.checkedCourses) 门课程、\(report.checkedVideos) 个视频")
                for group in report.withinCourses { print("　课内重复：\(group.summary)") }
                for duplicate in report.droppedPackages {
                    print("　课程重复：\(duplicate.summary)"
                        + (duplicate.requiresReview ? "" : "（已自动去重）"))
                }
                for match in report.existingCourseMatches { print("　已有课程：\(match.reason)") }
            }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 3600 { return "\(total / 60) 分钟" }
        return "\(total / 3600) 小时 \((total % 3600) / 60) 分钟"
    }
}
