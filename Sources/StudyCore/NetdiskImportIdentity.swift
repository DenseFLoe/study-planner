import Foundation

/// Older subdirectory scans used the share-root ID. Repair only identities backed by
/// both the saved folder locator and a complete correspondence to the reviewed lessons.
enum NetdiskImportIdentity {
    static func reconcile(_ courses: [Course], candidates: [NetdiskSnapshotBuilder.Course],
                          scan: NetdiskScan) throws -> [Course] {
        var result = courses
        let prefix = "quark:" + scan.pwdID + ":"
        for candidate in candidates {
            let incoming = Set(candidate.sourcePackageIDs.isEmpty ? [candidate.packageID] : candidate.sourcePackageIDs)
            let legacy = result.indices.filter { index in
                guard let metadata = result[index].netdisk, metadata.pwdID == scan.pwdID,
                      let previous = result[index].webCourse,
                      let link = NetdiskLink.parse(metadata.sourceURL), link.pwdID == scan.pwdID,
                      let folder = link.fragmentFID else { return false }
                let sources = metadata.sourcePackageIDs ?? [previous.packageID]
                let corrected = sources.map { id in
                    if id == prefix + "root" { return prefix + folder }
                    if id.hasPrefix(prefix + ":series:") { return prefix + folder + id.dropFirst(prefix.count) }
                    return id
                }
                return corrected != sources && Set(corrected) == incoming
            }
            guard !legacy.isEmpty else { continue }
            guard legacy.count == 1, !result.contains(where: { $0.webCourse?.packageID == candidate.packageID }) else {
                throw WebCourseImportError.invalid("多个已有课程对应同一网盘子目录，请先核对重复课程；原课程和学习记录已保留。")
            }
            let index = legacy[0]
            let oldLessons = Set(result[index].webCourse?.lessons.map(\.id) ?? [])
            guard !oldLessons.isEmpty, oldLessons.isSubset(of: Set(candidate.snapshot.lessons.map(\.id))) else {
                throw WebCourseImportError.invalid("旧子目录课程的课节无法完整对应，请重新核对目录；原课程和学习记录已保留。")
            }
            result[index].webCourse?.packageID = candidate.packageID
        }
        if candidates.contains(where: { $0.packageID == prefix + "root" }),
           result.contains(where: { course in
               course.webCourse?.packageID == prefix + "root"
                   && NetdiskLink.parse(course.netdisk?.sourceURL ?? "")?.fragmentFID != nil
           }) {
            throw WebCourseImportError.invalid("已有旧版子目录课程使用根目录编号，请先重新读取该子目录并核对；原课程和学习记录已保留。")
        }
        for candidate in candidates where candidate.packageID == prefix + "root" {
            let incomingLessons = Set(candidate.snapshot.lessons.map(\.id))
            for course in result where course.webCourse?.packageID == candidate.packageID {
                // Older phone imports did not retain the folder fragment. A different
                // catalog must not silently replace that ambiguous root binding.
                guard Set(course.webCourse?.lessons.map(\.id) ?? []).isSubset(of: incomingLessons) else {
                    throw WebCourseImportError.invalid("已有根目录课程的课节无法完整对应，请核对来源和目录；原课程和学习记录已保留。")
                }
            }
        }
        return result
    }
}
