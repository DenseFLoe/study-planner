import Foundation
import CoreFoundation
import SwiftUI

/// A local, lossless field view of the exact serialized request. Unknown fields
/// remain visible; the original bytes remain available in a secondary disclosure.
struct AssistantDetailNode: Identifiable {
    let id: String
    let title: String
    var value: String? = nil
    var children: [AssistantDetailNode] = []
    var plainText: String { ([title + (value.map { "：" + $0 } ?? "")] + children.map(\.plainText)).joined(separator: "\n") }

    static func parse(_ text: String) -> [AssistantDetailNode] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            return [.init(id: "text", title: "完整内容", value: text)]
        }
        return [node(object, key: "root", path: "root")]
    }
    private static func node(_ object: Any, key: String, path: String) -> Self {
        let title = labels[key] ?? key
        if let object = object as? [String: Any] {
            let order = ["model", "system", "messages", "role", "content", "text", "data", "rows", "tools"]
            let keys = object.keys.sorted {
                let a = order.firstIndex(of: $0) ?? 100, b = order.firstIndex(of: $1) ?? 100
                return a == b ? $0 < $1 : a < b
            }
            return .init(id: path, title: title, children: keys.map { node(object[$0]!, key: $0, path: path + "." + $0) })
        }
        if let values = object as? [Any] {
            return .init(id: path, title: title + "（\(values.count)项）", children: values.enumerated().map {
                var item = node($0.element, key: "第\($0.offset + 1)项", path: path + ".\($0.offset)")
                if let dict = $0.element as? [String: Any], let role = dict["role"] as? String {
                    item = .init(id: item.id, title: "第\($0.offset + 1)条 · " + (valuesLabels[role] ?? role), value: item.value, children: item.children)
                }
                return item
            })
        }
        if let text = object as? String {
            // SDK tool results and call arguments are JSON encoded inside strings.
            // Decode their fields for reading, without rewriting the approved body.
            if ["content", "text", "arguments"].contains(key),
               let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8)), nested is [String: Any] || nested is [Any] {
                return node(nested, key: key, path: path)
            }
            let enumKeys = ["role", "type", "kind", "status", "lesson_match", "result", "joint_floating_status", "assessment_kind", "operation"]
            let label = enumKeys.contains(key) ? valuesLabels[text] : nil
            return .init(id: path, title: title, value: label.map { $0 + "（" + text + "）" } ?? text)
        }
        if object is NSNull { return .init(id: path, title: title, value: "未提供（null）") }
        if let number = object as? NSNumber {
            let value = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "是" : "否") : number.stringValue
            return .init(id: path, title: title, value: value)
        }
        return .init(id: path, title: title, value: String(describing: object))
    }
    private static let valuesLabels = [
        "user": "你的消息或查询结果", "assistant": "助手", "system": "助手规则", "tool": "本机查询结果",
        "study": "学习任务", "event": "事项", "text": "文字", "function": "只读查询工具", "tool_use": "查询调用", "tool_result": "查询结果",
        "planned": "待完成", "future": "后续计划", "completed": "已完成", "partial": "部分完成", "missed": "已错过", "rescheduled": "已重排",
        "matched": "已核实课节关联", "not_found": "当前课节中未找到", "not_recorded": "未保存课节编号",
        "fixed_overlap": "固定时段确实重叠", "floating_window": "浮动窗口核对", "floating_total_deficit": "浮动事项总容量不足",
        "proven_continuous_deficit": "已证明连续空档不足", "individually_fits": "单项可容纳，联合情况未核实",
        "outside_day_not_checked": "跨日窗口尚未完整核实", "not_verified": "尚未核实", "not_applicable": "不适用", "proven_deficit": "已证明容量不足",
        "capacity_and_rules": "容量与排程约束", "constraint": "排程约束", "unbooked": "未排入量"
    ]
    private static let labels = [
        "root": "实际发送内容", "model": "接收模型", "messages": "本次发送的消息", "system": "助手规则", "role": "消息类型",
        "content": "内容", "text": "文字内容", "tools": "提供给模型的只读查询工具", "function": "查询工具", "name": "名称",
        "description": "用途说明", "parameters": "允许的查询参数", "properties": "参数字段", "required": "必填字段", "additionalProperties": "允许额外字段",
        "type": "类型", "strict": "严格校验", "maxLength": "最大长度", "tool_calls": "模型请求的本机查询", "tool_call_id": "查询调用编号",
        "tool_use_id": "查询调用编号", "arguments": "实际查询参数", "input": "实际查询参数", "data": "本机查询事实", "rows": "明细",
        "id": "编号", "course": "课程编号", "course_id": "课程编号", "task_id": "任务编号", "lesson_id": "课节引用", "position": "当前课节序号",
        "untrusted_name": "名称（资料内容）", "untrusted_lesson_name": "排课时保存的课节名称", "untrusted_course_names": "涉及的课程名称",
        "lessons": "课节列表", "lesson_count": "课节总数", "courses": "课程列表", "kind": "记录类型", "status": "任务状态", "lesson_match": "课节关联状态",
        "date": "日期", "start_date": "开始日期", "end_date": "结束日期", "deadline": "截止日期", "start": "开始时间", "end": "结束时间",
        "captured_at": "本机核对时间", "time_zone": "时区", "snapshot_id": "资料版本指纹", "evidence_id": "本机证据编号", "category": "本次资料类别",
        "start_minute": "当天起始分钟（0为零点）", "end_minute": "当天结束分钟", "duration_minutes": "计划时长（分钟）",
        "total_minutes": "总学习量（分钟）", "completed_minutes": "完成量（分钟）", "remaining_minutes": "剩余量（分钟）", "occupied_minutes": "占用时长（分钟）",
        "floating": "是否为浮动窗口", "is_unconfirmed": "是否仍待确认", "confirmed_at": "确认时间", "auto_schedule": "自动排课",
        "minimum_block_minutes": "最小学习块（分钟）", "priority": "优先级", "daily_weight": "每日权重", "priority_order": "排课优先顺序",
        "availability": "可学习时段", "weekday": "星期编号（日=1）", "actual_study_start": "实际学习起始时间", "break_minutes": "休息间隔（分钟）",
        "rules": "排程规则", "note": "范围及限制说明", "source": "本机计算来源", "assessment_kind": "评估范围", "next_offset": "下一页位置", "offset": "分页位置", "total": "明细总数",
        "required_minutes": "需要时长（分钟）", "available_minutes": "可用时长（分钟）", "unscheduled_minutes": "未排入量（分钟）", "proven_capacity_deficit": "已证明的容量缺口（分钟）",
        "minimum_continuous_minutes": "最小连续时长（分钟）", "rest": "休息约束", "study_minutes": "学习时长（分钟）", "minimum_rest_minutes": "最低休息时长（分钟）",
        "days": "每日学习量", "actual_minutes": "实际学习量（分钟）", "planned_minutes": "计划学习量（分钟）", "unknown_date_minutes": "日期不明学习量（分钟）",
        "time_check": "本机时间核对", "fixed_interval_count": "参与核对的固定时段数", "fixed_overlap_count": "已核实的重叠对数",
        "floating_window_count": "浮动窗口数", "proven_floating_deficit_count": "已证明的浮动容量不足项数", "excluded_confirmed_task_count": "排除的已确认或历史任务数",
        "invalid_entry_count": "无法核实的无效记录数", "fixed_check_complete": "固定时段是否已全部核对", "joint_floating_status": "多项浮动窗口联合核对状态",
        "first": "第一项", "second": "第二项", "item": "对应任务或事项", "items": "涉及的任务或事项", "overlap_start": "重叠开始", "overlap_end": "重叠结束",
        "overlap_minutes": "实际重叠时长（分钟）", "longest_free_minutes": "最长连续空档（分钟）", "deficit_minutes": "已证明缺少时长（分钟）",
        "result": "本机核对结果", "left": "左侧数值", "right": "右侧数值", "operation": "运算", "left_reference": "左侧证据来源", "right_reference": "右侧证据来源",
        "max_tokens": "最大输出量", "max_completion_tokens": "最大输出量", "stream": "是否流式发送", "temperature": "模型采样设置", "error": "缺失信息说明"
    ]
}

struct AssistantDetailTree: View {
    let node: AssistantDetailNode
    let depth: Int
    @State private var expanded: Bool
    init(node: AssistantDetailNode, depth: Int = 0) {
        self.node = node; self.depth = depth; _expanded = State(initialValue: depth < 2)
    }
    var body: some View {
        if let value = node.value {
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title).font(.caption).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
        } else {
            DisclosureGroup(node.title, isExpanded: $expanded) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if node.children.isEmpty { Text("无内容").foregroundStyle(.secondary) }
                    ForEach(node.children) { AssistantDetailTree(node: $0, depth: depth + 1) }
                }.padding(.leading, 8).padding(.vertical, 6)
            }
        }
    }
}

struct AssistantRequestDetailsView: View {
    let request: AssistantRequest
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("本次将发送的内容").font(.title2.bold())
            Text("接收地址：" + request.url).textSelection(.enabled)
            Text("以下直接整理自待发送请求；展开各项可核对完整内容。密钥只用于认证，不显示在此处。").font(.callout).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(AssistantDetailNode.parse(request.body)) { AssistantDetailTree(node: $0) }
                    DisclosureGroup("原始请求编码（技术核对，可选）") {
                        Text(request.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            HStack { Spacer(); Button("返回确认") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(minWidth: 580, idealWidth: 700, maxWidth: 900, minHeight: 420, idealHeight: 560, maxHeight: 720)
    }
}
