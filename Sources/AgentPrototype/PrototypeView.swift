import SwiftUI
import AppKit
import Observation

@MainActor @Observable
private final class PrototypeSession {
    var provider = "openai"
    var status = "准备就绪：只使用合成课表与本机模拟接口。"
    var approval: PrototypeApproval?
    var evidence: [PrototypeEvidence] = []
    var answer: String?
    var running = false
    private var runner: PrototypeRunner?
    private var decision: CheckedContinuation<Bool, Never>?
    private var task: Task<Void, Never>?
    private var approvalTimeout: Task<Void, Never>?

    func start() {
        guard !running, let directory = PrototypeRunner.bundledDirectory else { return }
        running = true; evidence = []; answer = nil
        status = "正在启动本机辅助程序并检查访问限制…"
        let runner = PrototypeRunner(); self.runner = runner
        task = Task { [weak self] in
            guard let self else { return }
            defer { running = false; approval = nil; self.runner = nil; task = nil }
            do {
                let result = try await runner.run(provider: provider, directory: directory, approve: { [weak self] approval in
                    guard let self else { return false }
                    self.approval = approval
                    self.status = "等待本机确认；尚未把这份请求交给模拟接口。"
                    return await withCheckedContinuation {
                        self.decision = $0
                        self.approvalTimeout = Task { @MainActor [weak self] in
                            do { try await Task.sleep(for: .seconds(120)) } catch { return }
                            self?.decide(false)
                        }
                    }
                }, onEvidence: { [weak self] item in self?.evidence.append(item) })
                answer = result.answer
                status = "验证通过：\(result.modelSteps) 次模拟请求、\(result.executedTools) 次本机查询；外部请求 0 次。"
            } catch is CancellationError { status = "验证已取消；不会继续查询或发送。" }
            catch { status = error.localizedDescription }
        }
    }
    func decide(_ allowed: Bool) {
        approvalTimeout?.cancel(); approvalTimeout = nil
        let continuation = decision; decision = nil; approval = nil
        status = allowed ? "已允许这一次模拟请求…" : "已拒绝，本轮停止。"
        continuation?.resume(returning: allowed)
    }
    func cancel() {
        runner?.cancel(); decide(false); task?.cancel()
    }
}

public struct AgentPrototypeApp: App {
    public init() {}
    public var body: some Scene {
        WindowGroup("智能客服 · 合成数据验证") {
            PrototypeView().frame(minWidth: 760, minHeight: 660)
        }.defaultSize(width: 900, height: 820)
    }
}

private struct PrototypeView: View {
    @State private var session = PrototypeSession()
    @State private var expanded = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("智能客服 · 合成数据验证").font(.largeTitle.bold())
                Text("两节各 60 分钟的合成课程，只有 120 分钟空档。验证客服能否查询本机证据并解释课间休息。")
                Text("正式课表、账号与密钥不会被读取；本窗口没有真实 API 接入。")
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("模拟协议", selection: $session.provider) {
                        Text("OpenAI 兼容格式").tag("openai")
                        Text("Anthropic 格式").tag("anthropic")
                    }.frame(width: 330).disabled(session.running)
                    Button("开始合成验证") { expanded = false; session.start() }.disabled(session.running)
                    if session.running { Button("取消本轮") { session.cancel() } }
                }
                Text(session.status).font(.headline).accessibilityIdentifier("prototype-status")
                if let approval = session.approval {
                    GroupBox("发送前核对 · 仅这一次") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(approval.summary).fixedSize(horizontal: false, vertical: true)
                            DisclosureGroup("查看实际发送内容", isExpanded: $expanded) {
                                Text("以下正文与适配器交给本机模拟接口的字节一致。空认证字段是测试占位，没有密钥。")
                                    .font(.caption).foregroundStyle(.secondary)
                                ScrollView([.vertical, .horizontal]) {
                                    Text(approval.request.details).font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled).padding(8)
                                }.frame(height: 260).background(.background)
                            }
                            HStack {
                                Button("允许本次模拟发送") { expanded = false; session.decide(true) }.buttonStyle(.borderedProminent)
                                Button("拒绝并停止") { session.decide(false) }
                                Text("两分钟后过期").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(session.evidence, id: \.evidenceID) { item in
                    GroupBox("本机证据 \(item.evidenceID) · 合成课表") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("学习 \(item.requiredStudyMinutes) 分钟 · 窗口 \(item.availableMinutes) 分钟 · 最少休息 \(item.minimumRestMinutes) 分钟")
                            Text("当前未排入 \(item.unscheduledMinutes) 分钟；这不是已证明的缺口分钟数。")
                            Text("来源：\(item.source) · \(item.capturedAt)").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                if let answer = session.answer {
                    GroupBox("模拟回答 · 已与本机合成证据核对") { Text(answer).textSelection(.enabled).padding(10) }
                }
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        .onDisappear { session.cancel() }
    }
}
