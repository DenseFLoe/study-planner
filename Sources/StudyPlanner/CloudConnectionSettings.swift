import SwiftUI
import UniformTypeIdentifiers
import StudySync

struct CloudConnectionSettings: View {
    @Bindable var store: PlannerStore
    @State private var method = CloudConnectionMethod.https
    @State private var enabled = false
    @State private var endpoint = ""
    @State private var httpsToken = ""
    @State private var sshToken = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var fingerprint = ""
    @State private var trusted = false
    @State private var importedKey = ""
    @State private var hasSavedKey = false
    @State private var passphrase = ""
    @State private var importing = false
    @State private var reading = false
    @State private var savedHost = ""
    @State private var savedPort = ""
    @State private var savedFingerprint = ""

    var body: some View {
        Toggle("启用云同步", isOn: $enabled)
        HStack(spacing: 12) {
            connectionCard(.https, icon: "lock.shield", detail: "已有 HTTPS 地址")
            connectionCard(.ssh, icon: "key", detail: "使用服务器登录密钥")
        }
        if method == .https {
            TextField("HTTPS 服务器地址（支持公网 IP）", text: $endpoint)
            SecureField("服务访问码（留空沿用此方式已保存的值）", text: $httpsToken)
        } else {
            TextField("服务器 IP 或主机名", text: $host)
                .onChange(of: host) { _, _ in restoreKnownTrust() }
            HStack {
                TextField("SSH 端口", text: $port).frame(maxWidth: 160)
                    .onChange(of: port) { _, _ in restoreKnownTrust() }
                TextField("登录用户名", text: $username)
            }
            HStack {
                Button("导入私钥文件") { importing = true }
                Text(importedKey.isEmpty ? (hasSavedKey ? "已安全保存私钥" : "尚未导入私钥") : "已选择新私钥，保存后生效")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SecureField("私钥口令（未设口令则留空）", text: $passphrase)
            TextField("服务器指纹（SHA256:…）", text: $fingerprint)
                .onChange(of: fingerprint) { _, _ in restoreKnownTrust() }
            Button(reading ? "正在读取指纹…" : "读取服务器指纹") { readFingerprint() }
                .disabled(reading || host.isEmpty)
            Toggle("已向服务器主人核对上述指纹", isOn: $trusted)
            SecureField("服务访问码（留空沿用 SSH 方式已保存的值）", text: $sshToken)
            Text("密钥用于 SSH 登录；服务访问码用于日程同步，两者不同。连接后访问服务器内部的 18090 端口，无需安装组网软件。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text(store.cloudStatus).textSelection(.enabled)
        Text("两种方式分别保存配置，点击保存后生效。完整课表按记录修改时间合并，保留最近十版；修改、打开及恢复联网时同步，运行期间每小时检查。")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("保存云同步配置") { save() }
            Button("立即云同步") { store.requestCloudSync(manual: true) }
                .disabled(!store.cloudEnabled || !enabled || method != CloudVault.selectedMethod)
        }.disabled(store.syncBusy || store.orderSaveBusy || reading)
        .onAppear { load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text]) { result in
            do {
                let file = try result.get(), scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65536 else {
                    throw ClientError.message("私钥文件不能超过 64KB。")
                }
                let key = try String(contentsOf: file, encoding: .utf8)
                guard key.contains("PRIVATE KEY-----"), key.contains("-----END ") else { throw ClientError.message("请选择 SSH 私钥文件，而非公钥。") }
                importedKey = key; passphrase = ""
            } catch { store.errorMessage = "私钥未导入，请选择有效的私钥文件（最大 64KB）。" }
        }
    }
    private func connectionCard(_ option: CloudConnectionMethod, icon: String, detail: String) -> some View {
        Button { method = option } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(option.title, systemImage: icon).font(.headline)
                    Spacer()
                    Image(systemName: method == option ? "checkmark.circle.fill" : "circle")
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(method == option ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(method == option ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: method == option ? 2 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(option.title + (method == option ? "，已选中" : "，点击切换"))
    }
    private func load() {
        guard !store.demo else { return }
        enabled = store.cloudEnabled; method = CloudVault.selectedMethod
        do {
            endpoint = try CloudVault.load()?.endpoint ?? ""
            if let ssh = try CloudVault.load(method: .ssh)?.ssh {
                savedHost = ssh.host; savedPort = String(ssh.port); savedFingerprint = ssh.fingerprint
                host = ssh.host; port = String(ssh.port); username = ssh.username; fingerprint = ssh.fingerprint
                hasSavedKey = !ssh.privateKey.isEmpty; trusted = true
            }
        } catch { store.errorMessage = "无法读取已保存的云同步凭据。" }
    }
    private func restoreKnownTrust() {
        trusted = !savedFingerprint.isEmpty && host == savedHost && port == savedPort && fingerprint == savedFingerprint
    }
    private func readFingerprint() {
        guard let number = Int(port) else { store.errorMessage = "请检查 SSH 端口。"; return }
        let requestedHost = host, requestedPort = port
        reading = true
        Task {
            defer { reading = false }
            do {
                let candidate = try await CloudSSH.readFingerprint(host: requestedHost, port: number)
                if host == requestedHost, port == requestedPort { fingerprint = candidate; trusted = false }
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func save() {
        do {
            var credentials: CloudCredentials?
            if enabled {
                let previous = try CloudVault.load(method: method)
                if method == .https {
                    credentials = try CloudCredentials(endpoint: endpoint, token: httpsToken.isEmpty ? (previous?.token ?? "") : httpsToken)
                } else {
                    guard trusted else { throw ClientError.message("请先向服务器主人核对指纹，再勾选确认。") }
                    guard let number = Int(port) else { throw ClientError.message("请检查 SSH 端口。") }
                    let key = importedKey.isEmpty ? (previous?.ssh?.privateKey ?? "") : importedKey
                    let password = importedKey.isEmpty && passphrase.isEmpty ? (previous?.ssh?.passphrase ?? "") : passphrase
                    let ssh = try CloudSSHConfiguration(host: host, port: number, username: username, fingerprint: fingerprint, privateKey: key, passphrase: password)
                    credentials = try CloudCredentials(ssh: ssh, token: sshToken.isEmpty ? (previous?.token ?? "") : sshToken)
                }
            }
            if store.configureCloud(credentials: credentials, method: method, enabled: enabled) {
                httpsToken = ""; sshToken = ""; passphrase = ""
                if enabled, method == .ssh {
                    importedKey = ""; hasSavedKey = true
                    savedHost = host; savedPort = port; savedFingerprint = fingerprint
                }
            }
        } catch { store.errorMessage = error.localizedDescription }
    }
}
