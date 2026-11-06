import AppKit
import SwiftUI

@MainActor final class AssistantWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var session: AssistantSession?
    private var selectedDay: Date?
    private var selectedCourseID: UUID?

    func show(store: PlannerStore, day: Date, courseID: UUID? = nil) {
        if let window, let session {
            if !session.applyingProposal, selectedDay != day || selectedCourseID != courseID {
                session.contextChanged()
                selectedDay = day; selectedCourseID = courseID
                window.contentViewController = NSHostingController(rootView: AssistantView(store: store, day: day, courseID: courseID, session: session) { [weak self] in self?.window?.performClose(nil) })
            }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let session = AssistantSession(defaults: store.demo ? nil : .standard,
                                       historyStore: store.demo ? nil : .local)
        self.session = session
        selectedDay = day; selectedCourseID = courseID
        let view = AssistantView(store: store, day: day, courseID: courseID, session: session) { [weak self] in self?.window?.performClose(nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "智能助手 · 学习日程"
        window.contentViewController = NSHostingController(rootView: view)
        window.minSize = NSSize(width: 800, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("StudyAssistantWindow")
        window.center(); self.window = window
        window.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { session?.applyingProposal != true }
    func windowWillClose(_ notification: Notification) {
        session?.close(); session = nil; window = nil
    }
}
