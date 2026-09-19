import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct StudyPlannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = PlannerStore()
    var body: some Scene {
        WindowGroup("学习日程") {
            MainView(store: store).frame(minWidth: 1060, minHeight: 700).tint(.blue)
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
