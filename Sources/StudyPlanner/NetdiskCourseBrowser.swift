import Foundation
import StudyCore

/// Organizes the import candidates by the folders that contain them. A folder's selection
/// includes every course in its subtree, while search only changes what is visible.
struct NetdiskCourseBrowser {
    struct Group: Identifiable {
        let path: String
        let title: String
        let courses: [NetdiskSnapshotBuilder.Course]
        let children: [Group]

        var id: String { path }
        var count: Int { courses.count + children.reduce(0) { $0 + $1.count } }
        var selectableIDs: Set<String> {
            Set(courses.filter { $0.refusal == nil }.map(\.packageID))
                .union(children.reduce(into: Set<String>()) { $0.formUnion($1.selectableIDs) })
        }

        /// Uses the displayed tree, including compacted folder chains, so navigation opens
        /// exactly the disclosure groups that contain this course in the full directory.
        func ancestorPaths(containing packageID: String) -> [String]? {
            let ownPath = path.isEmpty ? [] : [path]
            if courses.contains(where: { $0.packageID == packageID }) { return ownPath }
            for child in children {
                if let descendants = child.ancestorPaths(containing: packageID) {
                    return ownPath + descendants
                }
            }
            return nil
        }
    }

    let courses: [NetdiskSnapshotBuilder.Course]
    let paths: [String: String]

    init(courses: [NetdiskSnapshotBuilder.Course], packages: [NetdiskPackage]) {
        self.init(courses: courses, paths: Dictionary(packages.map { ($0.packageID, $0.path) },
                                                   uniquingKeysWith: { first, _ in first }))
    }

    init(courses: [NetdiskSnapshotBuilder.Course], paths: [String: String]) {
        self.courses = courses
        self.paths = paths
    }

    var selectableIDs: Set<String> { Set(courses.filter { $0.refusal == nil }.map(\.packageID)) }

    func matching(_ query: String) -> [NetdiskSnapshotBuilder.Course] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return courses }
        return courses.filter { course in
            let path = paths[course.packageID] ?? ""
            let names = [course.name, path] + course.snapshot.lessons.map(\.name)
            return terms.allSatisfy { term in names.contains { $0.localizedStandardContains(term) } }
        }
    }

    func grouped(_ visible: [NetdiskSnapshotBuilder.Course]) -> Group {
        var direct: [String: [NetdiskSnapshotBuilder.Course]] = [:]
        var childPaths: [String: Set<String>] = [:]
        for course in visible {
            let components = (paths[course.packageID] ?? "").split(separator: "/").map(String.init)
            var parent = ""
            for component in components.dropLast() {
                let child = parent.isEmpty ? component : parent + "/" + component
                childPaths[parent, default: []].insert(child)
                parent = child
            }
            direct[parent, default: []].append(course)
        }
        func make(_ path: String) -> Group {
            let children = (childPaths[path] ?? []).sorted {
                NetdiskTitles.naturalCompare($0, $1) == .orderedAscending
            }.map(make)
            let title = path.split(separator: "/").last.map(String.init) ?? "分享根目录"
            return Group(path: path, title: title, courses: direct[path] ?? [], children: children)
        }
        // A single-child chain is just packaging around the real categories. Hide those
        // wrappers so the first useful branches are visible immediately.
        func compact(_ group: Group) -> Group {
            if group.courses.isEmpty && group.children.count == 1 {
                return compact(group.children[0])
            }
            return Group(path: group.path, title: group.title, courses: group.courses,
                         children: group.children.map(compact))
        }
        var top = make("")
        while top.courses.isEmpty && top.children.count == 1 && top.children[0].courses.isEmpty {
            top = top.children[0]
        }
        return Group(path: "", title: "分享根目录", courses: top.courses,
                     children: top.children.map(compact))
    }
}
