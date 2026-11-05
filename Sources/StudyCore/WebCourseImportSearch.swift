import Foundation

/// Searches displayed course information without indexing private URL parameters or opaque IDs.
public enum WebCourseImportSearch {
    public static func websiteLabel(for snapshot: WebCourseSnapshot) -> String? {
        guard let url = URLComponents(string: WebCourseIdentity.safeURL(snapshot.sourceURL)),
              let host = url.host else { return nil }
        return host + (url.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? "")
    }

    public static func matchingIDs(query: String, snapshots: [WebCourseSnapshot]) -> Set<String> {
        let terms = query.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Set(snapshots.map(\.identityKey)) }
        return Set(snapshots.filter { snapshot in
            let host = websiteLabel(for: snapshot) ?? ""
            let fields = [snapshot.name, host] + snapshot.lessons.flatMap {
                [$0.name, $0.subject, $0.stage, $0.chapter]
            }
            let text = fields.joined(separator: " ").precomposedStringWithCompatibilityMapping
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.map(\.identityKey))
    }
}

public enum WebCourseImportSelection {
    /// Keep deliberate deselection on refresh; only newly offered courses get selected automatically.
    public static func refreshed(selected: Set<String>, previouslyOffered: Set<String>, offered: Set<String>,
                                 automaticallySelected: Set<String>? = nil) -> Set<String> {
        let defaults = (automaticallySelected ?? offered).intersection(offered)
        return selected.intersection(offered).union(defaults.subtracting(previouslyOffered))
    }
}
