import Foundation

/// Chunk the wire envelope, not business records: references remain valid at commit time.
enum SyncTransfer {
    static let chunkSize = 4 * 1024 * 1024
    static let maximumSize = 128 * 1024 * 1024

    static func exchange(_ request: Data, post: (Data) async throws -> Data,
                         progress: (String) async -> Void) async throws -> Data {
        guard !request.isEmpty, request.count <= maximumSize else {
            throw ClientError.message("本次同步数据超过 128 MB，请先导出备份并检查课程数据。")
        }
        func call(_ object: [String: Any]) async throws -> [String: Any] {
            let data = try await post(JSONSerialization.data(withJSONObject: object))
            guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClientError.message("手机分块响应无效。")
            }
            return reply
        }
        let start = try await call(["operation": "begin", "length": request.count])
        guard start["transfer"] as? Int == 1 else {
            throw ClientError.message("手机尚不支持分块同步，请安装本次修复版 Android 安装包。")
        }
        var offset = 0
        while offset < request.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, request.count)
            let reply = try await call(["operation": "upload", "offset": offset,
                                        "data": request.subdata(in: offset..<end).base64EncodedString()])
            guard reply["offset"] as? Int == end else { throw ClientError.message("手机接收进度不一致，请重新同步。") }
            offset = end
            await progress("发送同步数据 \(offset / 1024) / \(request.count / 1024) KB")
        }
        let ready = try await call(["operation": "exchange"])
        guard let length = ready["length"] as? Int, length > 0, length <= maximumSize else {
            throw ClientError.message("手机同步数据大小无效或超过 128 MB。")
        }
        var response = Data()
        while response.count < length {
            try Task.checkCancellation()
            let reply = try await call(["operation": "download", "offset": response.count])
            guard let encoded = reply["data"] as? String, let chunk = Data(base64Encoded: encoded),
                  !chunk.isEmpty, chunk.count <= chunkSize, chunk.count <= length - response.count else {
                throw ClientError.message("手机同步数据分块无效，请重新同步。")
            }
            response.append(chunk)
            await progress("接收同步数据 \(response.count / 1024) / \(length / 1024) KB")
        }
        return response
    }
}
