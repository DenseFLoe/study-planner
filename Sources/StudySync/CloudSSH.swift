import Foundation
import CryptoKit
import Darwin

public enum CloudConnectionMethod: String, CaseIterable, Sendable {
    case https, ssh
    public var title: String { self == .https ? "HTTPS 直连" : "SSH 密钥" }
}

public struct CloudSSHConfiguration: Codable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var fingerprint: String
    public var privateKey: String
    public var passphrase: String
    public static let servicePort = 18090

    public init(host: String, port: Int = 22, username: String, fingerprint: String, privateKey: String, passphrase: String = "") throws {
        self.host = try Self.validatedHost(host)
        guard (1...65535).contains(port), username.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil else {
            throw ClientError.message("请检查 SSH 端口和登录用户名。")
        }
        let fingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fingerprint.hasPrefix("SHA256:"), let decoded = Data(base64Encoded: String(fingerprint.dropFirst(7)) + "="), decoded.count == 32 else {
            throw ClientError.message("请读取并向服务器主人核对 SHA256 服务器指纹。")
        }
        guard privateKey.utf8.count <= 65536, privateKey.contains("PRIVATE KEY-----"), privateKey.contains("-----END ") else {
            throw ClientError.message("请导入有效的 SSH 私钥文件（最大 64KB）。")
        }
        self.port = port; self.username = username; self.fingerprint = fingerprint
        self.privateKey = privateKey; self.passphrase = passphrase
    }
    public static func validatedHost(_ input: String) throws -> String {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.range(of: "^[A-Za-z0-9.:-]+$", options: .regularExpression) != nil,
              let url = URLComponents(string: "ssh://" + (host.contains(":") ? "[\(host)]" : host)), url.host != nil else {
            throw ClientError.message("SSH 地址只填写服务器 IP 或主机名，不带协议、端口和路径。")
        }
        return host
    }
    public var identity: String {
        "ssh://\(username)@\(host.contains(":") ? "[\(host)]" : host):\(port)/127.0.0.1:\(Self.servicePort)"
    }
}

/// OpenSSH owns the encrypted connection; the HTTP listener exists only on this device's loopback.
final class CloudSSHTunnel: @unchecked Sendable {
    let endpoint: String
    private let process: Process
    private let directory: URL
    private init(process: Process, directory: URL, port: Int) {
        self.process = process; self.directory = directory; endpoint = "http://127.0.0.1:\(port)"
    }
    deinit { close() }
    func close() {
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 { if !process.isRunning { break }; Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }
    static func fingerprint(forKeyLine line: String) -> String? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3, !line.hasPrefix("#"), let data = Data(base64Encoded: String(fields[2])), data.count <= 16384 else { return nil }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    private static func scan(host: String, port: Int) throws -> [String] {
        let host = try CloudSSHConfiguration.validatedHost(host)
        guard (1...65535).contains(port) else { throw ClientError.message("SSH 端口须为 1 至 65535。") }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        process.arguments = ["-T", "5", "-p", String(port), "-t", "ed25519,ecdsa,rsa", host]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 65536 else { throw ClientError.message("服务器指纹响应过大。") }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { fingerprint(forKeyLine: $0) != nil }
        guard !lines.isEmpty else { throw ClientError.message("无法读取 SSH 服务器指纹，请检查地址、端口及网络。") }
        return lines
    }
    static func readFingerprint(host: String, port: Int) async throws -> String {
        try await Task.detached { try scan(host: host, port: port).compactMap { fingerprint(forKeyLine: $0) }.first! }.value
    }
    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.message("无法创建本机 SSH 转发端口。") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw ClientError.message("无法分配本机 SSH 转发端口。") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw ClientError.message("无法读取本机 SSH 转发端口。") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    private static func listening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
    static func open(_ configuration: CloudSSHConfiguration) async throws -> CloudSSHTunnel {
        try await Task.detached {
            let lines = try scan(host: configuration.host, port: configuration.port)
            guard let line = lines.first(where: { fingerprint(forKeyLine: $0) == configuration.fingerprint }) else {
                throw ClientError.message("SSH 服务器指纹不匹配，已停止连接。请向服务器主人核对。")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("study-cloud-ssh-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let process = Process()
            do {
                func write(_ name: String, _ value: String, mode: Int = 0o600) throws -> URL {
                    let file = directory.appendingPathComponent(name)
                    guard FileManager.default.createFile(atPath: file.path, contents: Data(value.utf8), attributes: [.posixPermissions: mode]) else {
                        throw ClientError.message("无法创建 SSH 临时凭据。")
                    }
                    return file
                }
                let key = try write("identity", configuration.privateKey + "\n")
                let knownHosts = try write("known_hosts", line + "\n")
                let askpass = try write("askpass", "#!/bin/sh\nprintf '%s\\n' \"$STUDY_PLANNER_SSH_PASSPHRASE\"\n", mode: 0o700)
                let port = try availablePort()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                let fields = line.split(whereSeparator: \.isWhitespace)
                let algorithm = fields[1] == "ssh-rsa" ? "rsa-sha2-512,rsa-sha2-256" : String(fields[1])
                process.arguments = ["-F", "/dev/null", "-N", "-T", "-p", String(configuration.port), "-l", configuration.username,
                    "-i", key.path, "-L", "127.0.0.1:\(port):127.0.0.1:\(CloudSSHConfiguration.servicePort)",
                    "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null",
                    "-o", "HostKeyAlgorithms=\(algorithm)", "-o", "UpdateHostKeys=no", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                    "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
                    "-o", "BatchMode=\(configuration.passphrase.isEmpty ? "yes" : "no")", "-o", "NumberOfPasswordPrompts=1",
                    "-o", "ConnectTimeout=10", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "LogLevel=ERROR", configuration.host]
                var environment = ProcessInfo.processInfo.environment
                environment["SSH_ASKPASS"] = askpass.path; environment["SSH_ASKPASS_REQUIRE"] = "force"; environment["DISPLAY"] = "study-planner"
                environment["STUDY_PLANNER_SSH_PASSPHRASE"] = configuration.passphrase; process.environment = environment
                process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run()
                let tunnel = CloudSSHTunnel(process: process, directory: directory, port: port)
                let deadline = Date().addingTimeInterval(20)
                while process.isRunning && Date() < deadline {
                    if listening(port) { return tunnel }
                    try await Task.sleep(for: .milliseconds(50))
                }
                tunnel.close()
                throw ClientError.message("SSH 连接失败，请检查用户名、私钥、口令及服务器的端口转发权限。")
            } catch {
                if process.isRunning { process.terminate(); Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }
}

public enum CloudSSH {
    /// A candidate fingerprint only; the user must compare it with a trusted source before saving.
    public static func readFingerprint(host: String, port: Int) async throws -> String {
        try await CloudSSHTunnel.readFingerprint(host: host, port: port)
    }
}
