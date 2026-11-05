import Foundation

extension WebCourseIdentity {
    /// Preserve all fields (including future fields) while cleaning a legacy record.
    static func sanitizingCoursePayload(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        guard let course = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else { return data }
        var changed = false
        func cleanNetdisk(_ metadata: [String: Any]) -> [String: Any] {
            var result = metadata
            if let source = metadata["sourceURL"] as? String {
                let safe = NetdiskLink.publicURL(source)
                if safe != source { result["sourceURL"] = safe; changed = true }
            }
            return result
        }
        func clean(_ course: [String: Any]) -> [String: Any] {
            var result = course
            if var web = course["webCourse"] as? [String: Any] {
                if let source = web["sourceURL"] as? String {
                    let safe = safeURL(source)
                    if safe != source { web["sourceURL"] = safe; changed = true }
                }
                if let netdisk = web["netdisk"] as? [String: Any] { web["netdisk"] = cleanNetdisk(netdisk) }
                result["webCourse"] = web
            }
            if let netdisk = course["netdisk"] as? [String: Any] { result["netdisk"] = cleanNetdisk(netdisk) }
            if let sources = course["mergedSources"] as? [[String: Any]] { result["mergedSources"] = sources.map(clean) }
            return result
        }
        let result = clean(course)
        return changed ? try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) : data
    }
}

extension SyncRecord {
    private enum SourcePrivacyCodingKeys: String, CodingKey {
        case kind, id, payload, deleted, version, device, sequence, modifiedAt
    }
    /// Old ledger rows, including deletion markers, can bypass Course decoding.
    /// Clean only their source URLs when serializing to disk or a sync transport.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SourcePrivacyCodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(kind == "courses" ? WebCourseIdentity.sanitizingCoursePayload(payload) : payload, forKey: .payload)
        try container.encode(deleted, forKey: .deleted)
        try container.encode(version, forKey: .version)
        try container.encode(device, forKey: .device)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
    }
}

extension CloudOutbox {
    /// Pending files created by older versions must also be safe before transport sees them.
    /// Keep the archive/record identities and versions so offline retry semantics do not change.
    public static func sanitizeSourceURLsBeforeUpload(_ file: URL) throws {
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= CloudCompression.maximumCompressedSize else {
            throw SyncFailure.invalidData
        }
        var archive = try JSONDecoder().decode(CloudArchive.self, from: CloudCompression.gunzip(Data(contentsOf: file)))
        var changed = false
        for index in archive.records.indices where archive.records[index].kind == "courses" {
            let before = archive.records[index].payload
            let after = try WebCourseIdentity.sanitizingCoursePayload(before)
            if before != after { archive.records[index].payload = after; changed = true }
        }
        guard changed else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try CloudCompression.gzip(encoder.encode(archive)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
