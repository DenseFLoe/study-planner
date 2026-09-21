import Foundation
import Security
import CryptoKit
import StudyCore
import StudyPersistence

public struct Pairing: Codable, Sendable {
    public var host: String
    public var fingerprint: String
    public var token: String
    public var device: String
}
public struct PairingRequest: Equatable, Sendable {
    public let secret: String
    public let expiresAt: Date

    public var payload: String {
        var components = URLComponents()
        components.scheme = "studyplanner"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "expires", value: String(Int(expiresAt.timeIntervalSince1970)))
        ]
        return components.string ?? ""
    }

    public static func parse(_ value: String, now: Date = Date()) -> PairingRequest? {
        guard let components = URLComponents(string: value), components.scheme == "studyplanner", components.host == "pair",
              components.queryItems?.first(where: { $0.name == "v" })?.value == "2",
              let secret = components.queryItems?.first(where: { $0.name == "secret" })?.value,
              secret.count == 64, secret.allSatisfy(\.isHexDigit),
              let rawExpiry = components.queryItems?.first(where: { $0.name == "expires" })?.value,
              let expiry = TimeInterval(rawExpiry) else { return nil }
        let request = PairingRequest(secret: secret.lowercased(), expiresAt: Date(timeIntervalSince1970: expiry))
        guard request.expiresAt > now, request.expiresAt.timeIntervalSince(now) <= 600 else { return nil }
        return request
    }
}
public enum PairingVault {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.studyplanner.sync", kSecAttrAccount as String: "android"] }
    public static func load() throws -> Pairing? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ClientError.message("无法读取配对凭据：\(status)") }
        return try JSONDecoder().decode(Pairing.self, from: data)
    }
    static func save(_ pairing: Pairing) throws {
        let data = try JSONEncoder().encode(pairing)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw ClientError.message("无法保存配对凭据：\(added)") }
        } else if status != errSecSuccess { throw ClientError.message("无法更新配对凭据：\(status)") }
    }
}
public enum ClientError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
enum SyncDiagnostic {
    static func response(status: Int, body: Data, phase: String) -> ClientError {
        let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["code"] as? String
        let detail: String
        switch code {
        case "pairing_closed": detail = "手机当前没有有效配对窗口。请让 Android 重新扫描 Mac 上本次生成的二维码。"
        case "pairing_mismatch": detail = "二维码配对密钥不匹配或已失效。请在 Mac 重新生成二维码并让 Android 扫描。"
        case "unauthorized": detail = "配对凭据已失效，请重新配对两台设备。"
        case "session_invalid": detail = "同步会话已结束，请在手机重新开启接收窗口。"
        case "data_rejected": detail = "手机未能处理同步数据，请提供手机同步日志中的失败原因。"
        default: detail = phase == "首次配对" ? "手机拒绝配对。请重新生成二维码、让 Android 扫描，并在两分钟内重试。" : "手机拒绝请求，请查看手机同步日志。"
        }
        return .message("\(phase)失败（HTTP \(status)）：\(detail)")
    }
    static func transport(_ error: Error, phase: String, address: String) -> ClientError {
        let value = error as NSError
        let detail: String
        switch value.code {
        case NSURLErrorCannotConnectToHost: detail = "手机 \(address):8765 未接受连接。请在手机重新开启接收窗口并保持 App 在前台，然后重试。"
        case NSURLErrorNotConnectedToInternet: detail = "系统未允许此次局域网连接。请确认 Mac 已连接手机热点，并在系统设置的‘隐私与安全性 → 本地网络’中允许学习日程；同步本身不需要互联网。"
        case NSURLErrorTimedOut: detail = "连接手机超时。请确认两端仍在同一热点，手机接收窗口尚未结束。"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorCancelled: detail = "加密连接未通过，可能是已配对手机的证书发生变化或连接被取消。请重新生成二维码配对。"
        default: detail = error.localizedDescription
        }
        return .message("\(phase)失败（\(value.domain) \(value.code)）：\(detail)")
    }
}
private final class PinnedSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let fingerprint: String?
    private let lock = NSLock()
    private var completion: CheckedContinuation<Void, Never>?
    private var observed: String?
    init(_ fingerprint: String?) { self.fingerprint = fingerprint }
    var observedFingerprint: String? { lock.lock(); defer { lock.unlock() }; return observed }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let accepted = fingerprint ?? observed
        guard accepted == nil || hash == accepted else {
            lock.unlock(); completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        observed = hash
        lock.unlock()
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        lock.lock(); let c = completion; completion = nil; lock.unlock(); c?.resume()
    }
    func close(_ session: URLSession) async {
        await withCheckedContinuation { c in
            lock.lock(); completion = c; lock.unlock(); session.invalidateAndCancel()
        }
    }
}
private struct PairReply: Decodable { var token: String; var device: String }
private struct Exchange: Codable, Sendable {
    var `protocol` = 1
    var cursor: Int64
    var changes: [SyncRecord]
    var automatic: Bool
    var date: String
}
private struct ExchangeReply: Decodable, Sendable {
    var `protocol`: Int
    var device: String
    var cursor: Int64
    var changes: [SyncRecord]
    var session: String
}
public struct SyncOutcome: Sendable {
    public var state: PlannerState
    public var ledger: SyncLedger
    public var sent: Int
    public var received: Int
}
/// Each database closure owns its context; contexts never cross a suspension or thread boundary.
public enum SyncDatabase {
    public static func snapshot(url: URL? = nil) async throws -> (PlannerState, SyncLedger) {
        try await Task.detached {
            let db = try LocalRepository(url: url); let state = try db.load(); var ledger = try db.loadLedger()
            try ledger.capture(state); try db.save(state, ledger: ledger); return (state, ledger)
        }.value
    }
    static func update<T: Sendable>(url: URL? = nil, _ block: @escaping @Sendable (inout PlannerState, inout SyncLedger) throws -> T) async throws -> T {
        try await Task.detached {
            let db = try LocalRepository(url: url); var state = try db.load(); var ledger = try db.loadLedger()
            let result = try block(&state, &ledger); try db.save(state, ledger: ledger); return result
        }.value
    }
}
// Dependency injection keeps transport tests completely separate from user data and Keychain.
struct SyncEnvironment: Sendable {
    var databaseURL: URL?
    var loadPairing: @Sendable () throws -> Pairing?
    var savePairing: @Sendable (Pairing) throws -> Void
    var acceptsHost: @Sendable (String) -> Bool
    var gateway: @Sendable () async -> String?
    static var production: SyncEnvironment {
        .init(databaseURL: nil, loadPairing: { try PairingVault.load() }, savePairing: { try PairingVault.save($0) }, acceptsHost: { SyncClient.isPrivateIPv4($0) }, gateway: { await SyncClient.gateway() })
    }
}
public enum SyncClient {
    public static func makePairingRequest(validFor seconds: TimeInterval = 300) throws -> PairingRequest {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ClientError.message("无法生成安全的二维码配对密钥。") }
        return PairingRequest(secret: bytes.map { String(format: "%02x", $0) }.joined(), expiresAt: Date().addingTimeInterval(seconds))
    }
    public static func gateway() async -> String? {
        await Task.detached {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/sbin/route"); process.arguments = ["-n", "get", "default"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                return String(decoding: data, as: UTF8.self).split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("gateway:") }?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
            } catch { return nil }
        }.value
    }
    public static func isPrivateIPv4(_ host: String) -> Bool {
        guard host.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 }) else { return false }
        let a = parts.compactMap { Int($0) }
        guard a.count == 4, a.allSatisfy({ (0...255).contains($0) }) else { return false }
        return a[0] == 10 || (a[0] == 172 && (16...31).contains(a[1])) || (a[0] == 192 && a[1] == 168)
    }
    public static func run(automatic: Bool, host: String? = nil, pairingText: String? = nil, log: @escaping @Sendable (String) async -> Void) async throws -> SyncOutcome? {
        try await run(automatic: automatic, host: host, pairingText: pairingText, environment: .production, log: log)
    }
    static func run(automatic: Bool, host: String? = nil, pairingText: String? = nil, environment: SyncEnvironment, log: @escaping @Sendable (String) async -> Void) async throws -> SyncOutcome? {
        let (_, initial) = try await SyncDatabase.snapshot(url: environment.databaseURL)
        let now = Date(), date = SyncLedger.day(now)
        if automatic && !initial.permitsAutomatic(at: now) { return nil }
        var pairing = try environment.loadPairing()
        let supplied = pairingText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = supplied.flatMap { PairingRequest.parse($0) }
        let parts = request == nil ? supplied?.split(separator: ".").map(String.init) : nil
        var pairingCode = request?.secret
        let address = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? pairing?.host ?? ""
        guard environment.acceptsHost(address) else { throw ClientError.message("请输入手机热点的局域网 IPv4 地址。") }
        if automatic {
            guard (pairing != nil || parts != nil || request != nil), await environment.gateway() == address else { return nil }
        }
        if let parts {
            guard parts.count == 2, parts[0].count == 8, parts[0].allSatisfy(\.isNumber), parts[1].count == 64,
                  parts[1].allSatisfy({ $0.isHexDigit }) else { throw ClientError.message("二维码无效或已过期，请重新生成并扫描。") }
            pairingCode = parts[0]
            pairing = Pairing(host: address, fingerprint: parts[1].lowercased(), token: "", device: "")
        }
        if request != nil { pairing = Pairing(host: address, fingerprint: "", token: "", device: "") }
        guard var credentials = pairing else { throw ClientError.message("请先生成配对二维码并让 Android 扫描。") }
        if automatic { try await SyncDatabase.update(url: environment.databaseURL) { _, ledger in ledger.lastAttempt = now.timeIntervalSince1970 } }
        await log((automatic ? "自动" : "手动") + "同步开始；设备发现：\(address):8765")
        let delegate = PinnedSession(credentials.fingerprint.isEmpty ? nil : credentials.fingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 30
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.httpMaximumConnectionsPerHost = 1
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        func post(_ path: String, _ data: Data, token: String) async throws -> Data {
            guard data.count <= 16 * 1024 * 1024 else { throw ClientError.message("同步变化超过单次 16 MB 上限。") }
            var request = URLRequest(url: URL(string: "https://\(address):8765/sync/\(path)")!)
            request.httpMethod = "POST"; request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("close", forHTTPHeaderField: "Connection")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let phase = ["pair": "首次配对", "changes": "交换日程", "finish": "确认完成", "cancel": "关闭窗口"][path] ?? path
            if path != "cancel" { await log("开始" + phase) }
            let body: Data, response: URLResponse
            do { (body, response) = try await session.data(for: request) }
            catch { throw SyncDiagnostic.transport(error, phase: phase, address: address) }
            guard body.count <= 16 * 1024 * 1024 else { throw ClientError.message("手机响应超过 16 MB 上限。") }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw SyncDiagnostic.response(status: status, body: body, phase: phase) }
            return body
        }
        do {
            if let pairingCode {
                let reply = try JSONDecoder().decode(PairReply.self, from: await post("pair", JSONSerialization.data(withJSONObject: ["code": pairingCode]), token: ""))
                guard let fingerprint = delegate.observedFingerprint else { throw ClientError.message("未能读取手机证书指纹，配对未保存。") }
                credentials.fingerprint = fingerprint
                credentials.token = reply.token; credentials.device = reply.device
                try environment.savePairing(credentials)
                try await SyncDatabase.update(url: environment.databaseURL) { _, ledger in ledger.peerCursor = 0; ledger.sentCursor = 0 }
                await log("配对成功，凭据已存入钥匙串")
            }
            let (_, ledger) = try await SyncDatabase.snapshot(url: environment.databaseURL)
            let changes = ledger.changes(after: ledger.sentCursor), sentThrough = ledger.sequence
            let request = Exchange(cursor: ledger.peerCursor, changes: changes, automatic: automatic, date: date)
            let reply = try JSONDecoder().decode(ExchangeReply.self, from: await post("changes", JSONEncoder().encode(request), token: credentials.token))
            guard reply.protocol == 1, reply.device == credentials.device, reply.cursor >= ledger.peerCursor else { throw ClientError.message("对端身份或同步游标发生变化，请重新配对。") }
            await log("已建立加密连接并验证手机身份")
            let applied = try await SyncDatabase.update(url: environment.databaseURL) { state, current in
                var added = 0, modified = 0, removed = 0
                for row in reply.changes {
                    if let old = current.records[row.key], !row.wins(over: old) { continue }
                    if row.deleted { removed += 1 } else if current.records[row.key] == nil || current.records[row.key]!.deleted { added += 1 } else { modified += 1 }
                }
                try current.merge(reply.changes); state = try current.materialize()
                current.peerCursor = reply.cursor; current.sentCursor = sentThrough
                return "新增 \(added)，修改 \(modified)，删除 \(removed)"
            }
            await log(applied)
            await log("发送 \(changes.count) 条变化，接收 \(reply.changes.count) 条变化；本地事务已提交")
            _ = try await post("finish", JSONSerialization.data(withJSONObject: ["session": reply.session]), token: credentials.token)
            try await SyncDatabase.update(url: environment.databaseURL) { _, current in
                current.lastSuccess = Date().timeIntervalSince1970
                if automatic { current.lastAutoDate = SyncLedger.day(Date()) }
            }
            await delegate.close(session)
            await log("同步完成；网络模块关闭：会话 0、扫描 0、同步定时任务 0")
            let (state, current) = try await SyncDatabase.snapshot(url: environment.databaseURL)
            return SyncOutcome(state: state, ledger: current, sent: changes.count, received: reply.changes.count)
        } catch {
            // A reachable peer can release its window immediately. A disconnected peer has its own deadline.
            if !credentials.token.isEmpty { _ = try? await post("cancel", Data("{}".utf8), token: credentials.token) }
            await delegate.close(session)
            await log("同步失败：\(error.localizedDescription)；客户端网络模块关闭")
            throw error
        }
    }
}
