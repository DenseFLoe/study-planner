import Foundation
import Security
import StudyCore

public struct CloudCredentials: Codable, Sendable {
    public var endpoint: String
    public var token: String
    public var ssh: CloudSSHConfiguration?
    public var method: CloudConnectionMethod { ssh == nil ? .https : .ssh }
    public init(endpoint: String, token: String) throws {
        let text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: text), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", token.count >= 32, token.count <= 512,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ClientError.message("请输入 HTTPS 服务器根地址和至少 32 位的服务访问码。访问码不是 SSH 密钥。")
        }
        self.endpoint = text.hasSuffix("/") ? String(text.dropLast()) : text
        self.token = token
    }
    public init(ssh: CloudSSHConfiguration, token: String) throws {
        guard token.count >= 32, token.count <= 512, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ClientError.message("服务访问码须为 32 至 512 位且不含空白；它与 SSH 私钥不同。")
        }
        self.ssh = ssh; self.endpoint = ssh.identity; self.token = token
    }
    func validated() throws -> CloudCredentials {
        if let ssh {
            return try CloudCredentials(ssh: CloudSSHConfiguration(host: ssh.host, port: ssh.port, username: ssh.username,
                fingerprint: ssh.fingerprint, privateKey: ssh.privateKey, passphrase: ssh.passphrase), token: token)
        }
        return try CloudCredentials(endpoint: endpoint, token: token)
    }
}

public enum CloudVault {
    public static var selectedMethod: CloudConnectionMethod {
        get { CloudConnectionMethod(rawValue: UserDefaults.standard.string(forKey: "studyPlannerCloudMethod") ?? "") ?? .https }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "studyPlannerCloudMethod") }
    }
    private static func query(_ method: CloudConnectionMethod) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.studyplanner.cloud", kSecAttrAccount as String: method == .https ? "server" : "ssh-server"] }
    public static func load(method: CloudConnectionMethod = .https) throws -> CloudCredentials? {
        var q = query(method); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ClientError.message("无法读取云同步钥匙串。") }
        return try JSONDecoder().decode(CloudCredentials.self, from: data)
    }
    public static func save(_ credentials: CloudCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let q = query(credentials.method)
        var item = q; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess || (status == errSecItemNotFound && SecItemAdd(item as CFDictionary, nil) == errSecSuccess) else {
            throw ClientError.message("无法保存云同步访问码。")
        }
    }
}

struct CloudServerStatus: Codable, Sendable {
    var format: Int
    var serverID: String
    var revision: Int64
    func validate() throws {
        guard format == 1, UUID(uuidString: serverID) != nil, revision >= 0 else { throw SyncFailure.invalidData }
    }
}
protocol CloudSyncTransport: Sendable {
    func status() async throws -> CloudServerStatus
    func upload(_ file: URL) async throws -> CloudServerStatus
    func latest() async throws -> Data
}

private final class CloudHTTP: NSObject, CloudSyncTransport, URLSessionTaskDelegate, @unchecked Sendable {
    let credentials: CloudCredentials
    private var session: URLSession!
    let endpoint: String
    init(_ credentials: CloudCredentials, tunnel: CloudSSHTunnel? = nil) {
        self.credentials = credentials; endpoint = tunnel?.endpoint ?? credentials.endpoint; super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        if tunnel != nil { configuration.connectionProxyDictionary = [:] }
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func close() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint + "/cloud/" + path)!)
        request.httpMethod = method; request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }
    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ClientError.message(code == 401 ? "云同步访问码无效。" : "云同步请求失败（HTTP \(code)），本地修改已保留。")
        }
    }
    func status() async throws -> CloudServerStatus {
        let (file, response) = try await session.download(for: request("status")); defer { try? FileManager.default.removeItem(at: file) }
        try check(response)
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65536 else { throw SyncFailure.invalidData }
        return try JSONDecoder().decode(CloudServerStatus.self, from: Data(contentsOf: file))
    }
    func upload(_ file: URL) async throws -> CloudServerStatus {
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= CloudCompression.maximumCompressedSize else { throw SyncFailure.invalidData }
        var req = request("snapshot", method: "POST"); req.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, fromFile: file); try check(response)
        guard data.count <= 65536 else { throw SyncFailure.invalidData }
        return try JSONDecoder().decode(CloudServerStatus.self, from: data)
    }
    func latest() async throws -> Data {
        let (file, response) = try await session.download(for: request("latest")); defer { try? FileManager.default.removeItem(at: file) }
        try check(response)
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= CloudCompression.maximumCompressedSize else { throw SyncFailure.invalidData }
        return try Data(contentsOf: file)
    }
}

public enum CloudSyncClient {
    public static func resetProgress() async throws {
        try await SyncDatabase.update(enqueueCloud: false) { _, ledger in ledger.cloudProgress = nil }
    }
    public static func run(credentials: CloudCredentials) async throws -> SyncOutcome {
        let validated = try credentials.validated()
        let tunnel: CloudSSHTunnel?
        if let ssh = validated.ssh { tunnel = try await CloudSSHTunnel.open(ssh) } else { tunnel = nil }
        defer { tunnel?.close() }
        let transport = CloudHTTP(validated, tunnel: tunnel); defer { transport.close() }
        return try await run(endpoint: validated.endpoint, outbox: CloudOutbox.directory(), transport: transport)
    }
    static func run(endpoint: String, databaseURL: URL? = nil, outbox: URL, transport: any CloudSyncTransport) async throws -> SyncOutcome {
        let (_, initial) = try await SyncDatabase.snapshot(url: databaseURL)
        let progress = initial.cloudProgress.flatMap { $0.endpoint == endpoint ? $0 : nil }
        var remote = try await transport.status(); try remote.validate()
        if let progress, progress.serverID != remote.serverID || remote.revision < progress.revision {
            throw ClientError.message("服务器身份或版本发生回退。请核对服务器后重新保存云同步配置，现有日程未被覆盖。")
        }
        if progress == nil || progress!.uploadedSequence != initial.sequence {
            try CloudOutbox.enqueue(initial, directory: outbox)
        }
        let pending = try CloudOutbox.files(in: outbox)
        for file in pending {
            let reply = try await transport.upload(file); try reply.validate()
            guard reply.serverID == remote.serverID, reply.revision >= remote.revision else { throw SyncFailure.invalidData }
            remote = reply
        }
        guard remote.revision > 0 else { throw ClientError.message("云端尚无课表，请先上传本机数据。") }
        var archive: CloudArchive?
        if !pending.isEmpty || progress == nil || remote.revision != progress!.revision {
            let downloaded = try await transport.latest()
            archive = try JSONDecoder().decode(CloudArchive.self, from: CloudCompression.gunzip(downloaded)).validated()
            guard archive?.serverID == remote.serverID, let revision = archive?.revision, revision >= remote.revision else { throw SyncFailure.invalidData }
            remote.revision = revision
        }
        let records = archive?.records ?? [], revision = remote.revision, identity = remote.serverID
        let initialSequence = initial.sequence
        let outcome = try await SyncDatabase.update(url: databaseURL, enqueueCloud: false) { state, ledger in
            let locallyChangedDuringUpload = ledger.sequence != initialSequence
            try ledger.merge(records); state = try ledger.materialize(); try ledger.capture(state)
            ledger.cloudProgress = CloudProgress(endpoint: endpoint, serverID: identity, revision: revision,
                uploadedSequence: locallyChangedDuringUpload ? -1 : ledger.sequence, lastSuccess: Date().timeIntervalSince1970)
            return SyncOutcome(state: state, ledger: ledger, sent: pending.count, received: records.count)
        }
        for file in pending { try? FileManager.default.removeItem(at: file) }
        return outcome
    }
}
