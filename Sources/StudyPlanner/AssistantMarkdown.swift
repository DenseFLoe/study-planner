import SwiftUI

/// Small, deterministic Markdown renderer. It never loads images, HTML or remote content.
enum AssistantMarkdown {
    enum Block: Equatable {
        case paragraph(String), heading(String, Int), item(String, String, Int), quote(String), code(String), table([[String]])
    }
    static func blocks(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Block] = [], paragraph: [String] = [], index = 0
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        func cells(_ line: String) -> [String] {
            var parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
            if parts.first?.isEmpty == true { parts.removeFirst() }
            if parts.last?.isEmpty == true { parts.removeLast() }
            return parts.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("```") {
                flush(); var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                result.append(.code(code.joined(separator: "\n"))); continue
            }
            if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " ") {
                let prefix = trimmed[..<space]
                if prefix.count <= 6 && prefix.allSatisfy({ $0 == "#" }) {
                    flush(); result.append(.heading(String(trimmed[trimmed.index(after: space)...]), prefix.count)); continue
                }
            }
            if line.contains("|"), index < lines.count {
                let separator = cells(lines[index])
                if separator.count >= 2 && separator.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                    flush(); var rows = [cells(line)]; index += 1
                    while index < lines.count && lines[index].contains("|") {
                        rows.append(cells(lines[index])); index += 1
                    }
                    result.append(.table(rows)); continue
                }
            }
            if trimmed.hasPrefix("> ") { flush(); result.append(.quote(String(trimmed.dropFirst(2)))); continue }
            if let range = trimmed.range(of: #"^(?:[-*+] |[0-9]+[.)] )"#, options: .regularExpression) {
                flush()
                let marker = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                result.append(.item(["-", "*", "+"].contains(marker) ? "•" : marker,
                                    String(trimmed[range.upperBound...]), min(3, (line.count - trimmed.count) / 2)))
                continue
            }
            paragraph.append(line)
        }
        flush(); return result
    }
    static func inline(_ text: String) -> AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Links remain readable text. Model output cannot open an unrelated recipient or local file.
        for run in value.runs where run.link != nil { value[run.range].link = nil }
        return value
    }
}

struct AssistantMarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(AssistantMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): inline(text)
                case .heading(let text, let level): inline(text).font(level == 1 ? .title3.bold() : .headline).padding(.top, 4)
                case .item(let marker, let text, let depth):
                    HStack(alignment: .top, spacing: 8) { Text(marker).foregroundStyle(.secondary); inline(text) }.padding(.leading, CGFloat(depth * 12))
                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3); inline(text).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                case .code(let text):
                    ScrollView(.horizontal) { Text(text).font(.system(.callout, design: .monospaced)).padding(10) }
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { row, cells in
                                GridRow {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        Text(AssistantMarkdown.inline(cell)).fontWeight(row == 0 ? .semibold : .regular).frame(maxWidth: 240, alignment: .leading)
                                    }
                                }
                                if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(12)
                    }.background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inline(_ text: String) -> some View {
        Text(AssistantMarkdown.inline(text)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}
