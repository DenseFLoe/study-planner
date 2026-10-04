import Foundation
import StudyCore

/// Shared builders for the netdisk tests. Names and shapes mirror what quark's share listing
/// actually returned for a real share, so the fixtures stay honest.
enum NetdiskFixtures {
    /// A directory entry as the provider reports it: folder, no size, no duration.
    static func folder(_ name: String, in parent: String = "", fid: String? = nil, token: String = "t") -> NetdiskEntry {
        NetdiskEntry(fid: fid ?? "dir-" + name, shareToken: token, name: name, isDirectory: true,
                     fileType: 0, category: 0, formatType: "", size: 0, durationSeconds: nil,
                     width: nil, height: nil, updatedAt: nil, childCount: nil, riskType: 0,
                     banned: false, badContent: false, status: 1, parentPath: parent)
    }

    /// A video file. `duration` nil means the provider withheld it, which is what the estimator handles.
    static func video(_ name: String, in parent: String = "", size: Int64 = 280_064_842,
                      duration: Double? = 6693, width: Int? = 1280, height: Int? = 720,
                      fid: String? = nil, token: String = "tok") -> NetdiskEntry {
        NetdiskEntry(fid: fid ?? "vid-" + parent + "-" + name, shareToken: token, name: name, isDirectory: false,
                     fileType: 1, category: 1, formatType: "video/mp4", size: size,
                     durationSeconds: duration, width: width, height: height, updatedAt: nil,
                     childCount: nil, riskType: 0, banned: false, badContent: false, status: 1,
                     parentPath: parent)
    }
    static func pdf(_ name: String, in parent: String = "", size: Int64 = 3_000_000) -> NetdiskEntry {
        NetdiskEntry(fid: "pdf-" + parent + "-" + name, shareToken: "tok", name: name, isDirectory: false,
                     fileType: 1, category: 4, formatType: "application/pdf", size: size,
                     durationSeconds: nil, width: nil, height: nil, updatedAt: nil, childCount: nil,
                     riskType: 0, banned: false, badContent: false, status: 1, parentPath: parent)
    }

    static func scan(packages: [NetdiskPackage], pwdID: String = "48d8818e6cc0",
                     title: String = "01.【2027考研数学】武忠祥有道领学班！",
                     root: NetdiskDirectory? = nil) -> NetdiskScan {        NetdiskScan(pwdID: pwdID, passcodeProtected: false, title: title,
                    sourceURL: "https://pan.quark.cn/s/" + pwdID, fetchedAt: Date(timeIntervalSince1970: 1_790_497_416),
                    root: root ?? NetdiskDirectory(fid: "root", shareToken: "st", name: title, path: "",
                                                   depth: 0, fileCount: 0, folderCount: packages.count,
                                                   videoCount: packages.reduce(0) { $0 + $1.videoCount },
                                                   documentCount: 0, otherCount: 0,
                                                   totalBytes: packages.reduce(0) { $0 + $1.totalBytes },
                                                   totalSeconds: packages.reduce(0) { $0 + $1.totalSeconds },
                                                   children: []),
                    packages: packages, totalVideoCount: packages.reduce(0) { $0 + $1.videoCount },
                    totalBytes: packages.reduce(0) { $0 + $1.totalBytes },
                    totalSeconds: packages.reduce(0) { $0 + $1.totalSeconds },
                    unreadFolders: 0, issues: [])
    }

    /// Digests a listing exactly the way the crawler does, so tests exercise the real pipeline.
    static func digest(_ entries: [NetdiskEntry], title: String = "01.【2027考研数学】武忠祥有道领学班！",
                       limits: NetdiskDigest.Limits = .standard) -> NetdiskDigest.Outcome {
        NetdiskDigest.digest(entries: entries, rootTitle: title, pwdID: "48d8818e6cc0", limits: limits)
    }

    /// The single package of a listing, or the one whose path matches.
    static func package(_ entries: [NetdiskEntry], path: String? = nil) -> NetdiskPackage? {
        let packages = digest(entries).packages
        guard let path else { return packages.count == 1 ? packages[0] : packages.first }
        return packages.first { $0.path == path }
    }
}
