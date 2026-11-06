import Foundation
import StudyCore

enum AssistantProposal {
    static func make(_ call: AssistantToolCall, context: AssistantContext) throws -> AssistantScheduleChange {
        guard call.arguments.utf8.count <= 6000,
              let args = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: String],
              Set(args.keys) == ["action", "course", "value"], args.values.allSatisfy({ $0.count <= 300 }),
              let action = args["action"], let reference = args["course"], let value = args["value"] else { throw AssistantScheduleChangeError.invalid }
        var courseID: UUID?
        if !reference.isEmpty {
            guard reference.hasPrefix("课程"), let index = Int(reference.dropFirst(2)),
                  reference == "课程\(index)", index > 0, index <= context.courses.count else { throw AssistantScheduleChangeError.invalid }
            courseID = context.courses[index - 1].id
        }
        return try .init(state: context.state, action: action, courseID: courseID, value: value, now: context.now, calendar: context.calendar)
    }
    static func output(_ draft: AssistantScheduleChange, call: AssistantToolCall, id: String) throws -> AssistantToolResult {
        let data: [String: Any] = ["untrusted_change": draft.title, "saved": false,
                                  "before_task_count": draft.baseline.tasks.count, "preview_task_count": draft.preview.tasks.count,
                                  "risk_count": draft.result.risks.count, "conflict_count": draft.result.conflicts.count,
                                  "instruction": "本机已展示完整前后安排，等待用户单独点击确认执行。不能声称已保存。"]
        return .init(id: id, callID: call.id, title: "日程修改预览", content: "[\(id)] " + (try AssistantTools.encodedPayload(["data": data])),
                     privateData: true, category: AssistantPrivacy.category(call.name), scope: AssistantPrivacy.scope(call))
    }
}
