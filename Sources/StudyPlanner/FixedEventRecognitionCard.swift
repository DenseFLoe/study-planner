import Foundation
import SwiftUI
import StudyCore

/// A local-only helper for turning pasted schedule text into fixed events.
/// Parsing runs in a detached task so a long pasted outline never blocks typing,
/// and every draft still passes through the regular editor before it is saved.
struct FixedEventRecognitionCard: View {
    var onAdd: (FixedEvent) -> Void

    @State private var text = ""
    @State private var recognized: FixedEventRecognitionPayload?
    @State private var isRecognizing = false
    @State private var recognitionID = UUID()

    private static let example = "明天下午 3 点到 5 点开会"
    private static let limit = 20

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var todayText: String {
        let calendar = Calendar.current
        let weekday = weekdayNames[calendar.component(.weekday, from: Date())] ?? ""
        let day = Date().formatted(.dateTime.year().month().day())
        return weekday.isEmpty ? day : "\(day) \(weekday)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("粘贴文字，识别日程", systemImage: "text.viewfinder")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("在本机识别，不上传文字；相对日期按今天（\(todayText)）换算。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            editor

            HStack(spacing: 10) {
                Text("支持一次粘贴多条；识别结果需核对后再添加。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                recognizeButton
            }

            if let recognized {
                results(recognized)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .plannerSurface(radius: 18, material: .thinMaterial, shadow: false)
        .onChange(of: text) { _, _ in
            // Editing invalidates both the visible drafts and any in-flight parse,
            // so a late result can never be mistaken for the new text.
            guard isRecognizing || recognized != nil else { return }
            recognitionID = UUID()
            recognized = nil
            isRecognizing = false
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
            if text.isEmpty {
                Text(Self.example)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 96)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PlannerTheme.surface.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PlannerTheme.hairline, lineWidth: 1)
        }
        .accessibilityLabel("待识别的日程文字")
    }

    private var recognizeButton: some View {
        Button {
            recognize()
        } label: {
            HStack(spacing: 6) {
                if isRecognizing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(isRecognizing ? "正在识别…" : "识别日程")
            }
        }
        .buttonStyle(SoftButtonStyle(prominent: true))
        .disabled(isRecognizing || trimmedText.isEmpty)
        .opacity(isRecognizing || trimmedText.isEmpty ? 0.55 : 1)
        .help("在本机解析文字中的日期、时间与重复规则")
    }

    @ViewBuilder
    private func results(_ payload: FixedEventRecognitionPayload) -> some View {
        Divider()

        if !payload.messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(payload.messages.enumerated()), id: \.offset) { _, message in
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if payload.drafts.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.circle")
                Text("没有识别到可添加的日程。请确认文字里包含日期或时间，例如“\(Self.example)”。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        } else {
            Text(payload.total > Self.limit
                 ? "识别到 \(payload.total) 条，仅显示前 \(Self.limit) 条"
                 : "识别到 \(payload.total) 条")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(payload.drafts) { draft in
                    DraftRow(draft: draft) { onAdd(draft.event) }
                }
            }
        }
    }

    private func recognize() {
        let source = text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let token = UUID()
        recognitionID = token
        recognized = nil
        isRecognizing = true

        let now = Date()
        let calendar = Calendar.current
        let limit = Self.limit

        Task { @MainActor in
            let payload = await Task.detached(priority: .userInitiated) {
                let result = FixedEventTextParser.parse(source, now: now, calendar: calendar)
                return FixedEventRecognitionPayload(
                    messages: result.messages,
                    drafts: Array(result.drafts.prefix(limit)),
                    total: result.drafts.count
                )
            }.value

            guard recognitionID == token, text == source else { return }
            recognized = payload
            isRecognizing = false
        }
    }
}

/// Carries only Sendable values across the detached parse boundary, so the card does
/// not depend on the result wrapper itself being sendable.
private struct FixedEventRecognitionPayload: Sendable {
    var messages: [String]
    var drafts: [FixedEventTextDraft]
    var total: Int
}

private struct DraftRow: View {
    var draft: FixedEventTextDraft
    var add: () -> Void

    private var event: FixedEvent { draft.event }

    private var title: String {
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名事项" : trimmed
    }

    private var dateText: String {
        let calendar = Calendar.current
        let day = event.startDate.formatted(.dateTime.year().month().day())
        let weekday = weekdayNames[calendar.component(.weekday, from: event.startDate)] ?? ""
        return weekday.isEmpty ? day : "\(day) \(weekday)"
    }

    private var recurrenceText: String {
        let deadline = event.endDate.formatted(.dateTime.year().month().day())
        guard !event.weekdays.isEmpty else { return "单次事项" }
        return "每周重复：" + repeatLabel(event.weekdays) + " · 截止 \(deadline)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("核对并添加", action: add)
                    .buttonStyle(SoftButtonStyle())
                    .help("在固定事项编辑器中核对后保存")
            }

            HStack(spacing: 6) {
                Label(dateText, systemImage: "calendar")
                Text("·").foregroundStyle(.tertiary)
                Text(clockTime(event.startMinute) + "–" + clockTime(event.endMinute))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(recurrenceText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if event.isFloating {
                Text("时段内浮动 · 固定占用 \(event.occupiedMinutes) 分钟")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !draft.source.isEmpty {
                Text("原文：\(draft.source)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
    }
}
