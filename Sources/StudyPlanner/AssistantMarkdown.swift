import SwiftUI

/// Small, deterministic Markdown renderer. It never loads images, HTML or remote content.
enum AssistantMarkdown {
    /// Hide internal reference tokens in new answers and previously saved conversations.
    static func answerText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[E[0-9]+(?:\s*[,，、]\s*E?[0-9]+)*\]"#, with: "", options: .regularExpression)
    }
    enum Block: Equatable {
        case paragraph(String), heading(String, Int), item(String, String, Int), quote(String), code(String), table([[String]]), chart(AssistantChart), unavailableChart
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
                while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces) != "```" {
                    code.append(lines[index]); index += 1
                }
                let closed = index < lines.count
                if closed { index += 1 }
                let body = code.joined(separator: "\n")
                if trimmed == "```study-chart" {
                    if closed, let chart = AssistantChart.decode(body) { result.append(.chart(chart)) }
                    else { result.append(.unavailableChart) }
                } else { result.append(.code(body)) }
                continue
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
    static func copyText(_ text: String) -> String {
        blocks(answerText(text)).map { block in
            switch block {
            case .paragraph(let text), .heading(let text, _), .quote(let text), .code(let text): text
            case .item(let marker, let text, _): marker + " " + text
            case .table(let rows): rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            case .chart(let chart): chart.title + "\n" + chart.tableText + "\n生成时的数据快照 · " + chart.capturedAt
            case .unavailableChart: AssistantCharts.unavailable
            }
        }.joined(separator: "\n\n")
    }
}

struct AssistantMarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(AssistantMarkdown.blocks(AssistantMarkdown.answerText(text)).enumerated()), id: \.offset) { _, block in
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
                case .chart(let chart): AssistantChartView(chart: chart)
                case .unavailableChart:
                    Label(AssistantCharts.unavailable, systemImage: "chart.bar.xaxis")
                        .font(.callout).foregroundStyle(.secondary)
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
