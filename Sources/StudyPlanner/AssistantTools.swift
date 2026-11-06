import Foundation
import CoreFoundation
import StudyCore

/// Only safe, explicitly selected status values cross the assistant boundary.
/// Raw errors, sync logs, URLs, account IDs, cookies and credentials never enter this type.
struct AssistantRuntime: Equatable, Sendable {
    var ready = false
    var saving = false
    var syncing = false
    var cloudEnabled = false
    var hasError = false
    var supervisionBound = false
    var supervisedTasks = 0
    var websiteAutoUpdate = false
    var websiteUpdating = false
    var compressionCalculating = false
    var backupCount = 0
    var cloudOutcome = "尚未配置"
    var deviceOutcome = "尚未同步"
    var supervisionPaused = false

    // Match only application-owned prefixes; never forward an error suffix containing a URL or secret.
    static func syncOutcome(_ text: String) -> String {
        if text.hasPrefix("已同步") { return "界面报告已同步成功（仅本机最近状态）" }
        if text.hasPrefix("云同步未完成") || text.hasPrefix("同步未完成") { return "上次同步未完成，具体原因未提供" }
        if text.hasPrefix("正在") { return "正在处理" }
        if text.hasPrefix("等待下次") { return "等待手机同步窗口与热点连接" }
        if text.hasPrefix("已排队") { return "已排队等待" }
        if text.hasPrefix("云同步已暂停") { return "已暂停" }
        if text.hasPrefix("配置已保存") { return "已配置，尚需同步核验" }
        return "尚无可确认的同步结果"
    }
}

struct AssistantContext: Sendable {
    var state: PlannerState
    var result: ScheduleResult?
    var runtime = AssistantRuntime()
    var selectedDay = Date()
    var selectedCourseID: UUID?
    var dailyWarningMinutes = 480
    var now = Date()
    var calendar = Calendar.current

    var courses: [Course] { state.courses.filter { !$0.isArchived }.sorted { $0.id.uuidString < $1.id.uuidString } }
    func matches(_ other: Self) -> Bool {
        state == other.state && result == other.result && runtime == other.runtime && selectedDay == other.selectedDay
            && selectedCourseID == other.selectedCourseID && dailyWarningMinutes == other.dailyWarningMinutes
            && calendar == other.calendar && calendar.isDate(now, inSameDayAs: other.now)
    }
    func stamp(_ date: Date, time: Bool = false) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian); format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = time ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        return format.string(from: date)
    }
    var questionContext: String {
        let selection = selectedCourseID.flatMap { id in courses.firstIndex { $0.id == id } }.map { "课程\($0 + 1)" } ?? "未指定"
        return "本地今天：\(stamp(now))；时区：\(calendar.timeZone.identifier)；界面查看日期：\(stamp(selectedDay))；界面所选课程：\(selection)。"
    }
}

struct AssistantToolResult: Identifiable, Equatable, Sendable {
    var id: String
    var callID: String
    var title: String
    var content: String
    var privateData: Bool
    var denied = false
}

enum AssistantTools {
    /// Escape reference delimiters and invisible characters only inside JSON strings.
    /// Structural array brackets must remain JSON syntax, and existing escapes must
    /// keep their meaning (including a literal backslash followed by a quote).
    static func encodedPayload(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var insideString = false, escaped = false, output = ""
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            if insideString {
                if escaped { output.unicodeScalars.append(scalar); escaped = false; continue }
                if scalar == "\\" { output.unicodeScalars.append(scalar); escaped = true; continue }
                if scalar == "\"" { insideString = false }
                else if scalar == "[" || scalar == "]" || CharacterSet.newlines.contains(scalar)
                    || scalar.properties.generalCategory == .format {
                    output += scalar.utf16.map { String(format: "\\u%04X", $0) }.joined()
                    continue
                }
            } else if scalar == "\"" { insideString = true }
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    struct Definition {
        var name: String
        var title: String
        var description: String
        var fields: [String: String] = [:]
    }
    static let definitions: [Definition] = [
        .init(name: "search_help", title: "查阅软件功能说明", description: "查询应用内功能说明和操作入口。query 填功能词或问题；空字符串返回全部功能目录。无个人数据。", fields: ["query": "功能关键词；可为空"]),
        .init(name: "list_courses", title: "查找课程", description: "分页列出未归档课程的编号、名称、类型及来源状态，定位用户自然语言提到的课程。同名需澄清，不可猜测。每页20门。", fields: ["offset": "从0开始的偏移量"]),
        .init(name: "inspect_course", title: "查看课程与课节", description: "查看单门课程总量、有效进度、截止及课节顺序、名称、剩余量，每页20节。用于查下一节课、目录和进度；不含来源网址或备注。", fields: ["course": "list_courses返回的课程N，不能为空", "offset": "从0开始的偏移量"]),
        .init(name: "inspect_schedule", title: "核对课表与排程依据", description: "查看某日保存的课表、事项占用、可用时段、课程进度、截止和当前排程评估。可反复调用切换日期或课程。不重排。课程为空时概览最多12门；查询其他课程请填编号。", fields: ["date": "yyyy-MM-dd；空字符串表示当前界面日期", "course": "list_courses 返回的课程N；空字符串表示概览"]),
        .init(name: "inspect_progress", title: "核对实际学习量", description: "查询至多31天的每日计划与实际学习量及日期不明记录，沿用日报实际学习日期规则。课程为空时汇总全部课程（含历史课程）。", fields: ["start_date": "yyyy-MM-dd", "end_date": "yyyy-MM-dd，含当天", "course": "课程N或空字符串"]),
        .init(name: "inspect_settings", title: "查看排课设置", description: "读取可学习时段、最小学习块、排课偏好顺序与学习负担提醒线。不含账号或凭证。"),
        .init(name: "inspect_runtime", title: "检查应用运行状态", description: "读取是否就绪、保存/同步忙碌、云同步开关、监督绑定与当前监督任务数、网站更新状态、备份数量、压缩计算状态；不含原始错误/日志/地址/账号。"),
        .init(name: "inspect_compression", title: "查看极限压缩结果", description: "只读已保存的Mac压缩预览总览及新鲜度，不运行算法，不写入课表。")
    ]

    static func schemas(provider: AssistantProvider) -> [[String: Any]] {
        definitions.map { definition in
            let properties = definition.fields.mapValues { description -> [String: Any] in
                ["type": description == "从0开始的偏移量" ? "integer" : "string", "description": description]
            }
            let function: [String: Any] = ["name": definition.name, "description": definition.description,
                "parameters": ["type": "object", "properties": properties,
                               "required": definition.fields.keys.sorted(), "additionalProperties": false]]
            if provider == .openAI { return function.merging(["type": "function", "strict": true]) { _, new in new } }
            return ["type": "function", "function": function]
        }
    }

    // Curated from actual UI and domain rules. No paths or user-authored content.
    static let help: [(title: String, keywords: String, text: String)] = [
        ("课程与导入", "课程 导入 添加 网站 网盘 分节 更新 合并", "在课程区添加课程，设置总量、开始和截止日、优先级、每日倍率；可导入支持的网站或网盘课程，管理课节及顺序。网站课程的自动更新需配置来源；助手只读已保存数据，不登录网站。"),
        ("自动排课", "排课 日程 安排 超标 加量 倍率 偏好 截止 空档", "在设置中维护可学习时段和排课偏好；课程可暂停自动排程。整节课顺序、截止、可用时段及课间15分钟休息优先满足；均摊和倍率是偏好，不是每日硬上限。学习计划菜单可重新计算未来计划。未排入不等于已经证明无解，缺口需查看当前约束证据。"),
        ("立即学习与继续上课", "立即 继续 上课 本周", "在本周学习中选择立即学习或继续上课；界面会核对当前课程、课节和实际开始时间，保存成功后更新后续课表。助手不会替你启动或修改。"),
        ("完成记录与统计", "完成 确认 记录 进度 学了 日报 周报 统计 补记", "在日程任务或每日确认中登记实际学习与完成情况，可查看周统计。实际学习量按明确学习日期归属；旧记录只有任务和登记同日才归入该日，日期不明的记录单列。重复学习可能增加实际用时而不增加有效课程进度。"),
        ("固定与浮动事项", "事项 固定 浮动 冲突 休息", "事项区可配置日期、重复星期、固定时段或窗口内浮动占用。冲突需在原界面核对后保存。助手只读取占用时间，不发送事项名称和备注。"),
        ("设备与云同步", "同步 云 手机 Android 网络", "同步设置中配置设备或云同步。同步状态需查看当前应用状态；开关开启并不证明已同步成功。助手不能查看凭证、服务器日志、远端设备，也不会触发同步。"),
        ("学习监督", "监督 播放 通知 提示音 声音 后台 绑定 权限", "学习监督仅macOS支持；在监督设置中绑定观看软件、授予检测与通知权限及设置提示音。绑定监督或开启网站自动更新后，关闭窗口仍可能后台运行；学习监督菜单中可退出应用。Android不提供这些能力。助手只能读取安全的状态摘要，不能判断未提供的权限或播放原因。"),
        ("极限压缩", "极限 压缩 最快 结束", "Mac计算极限压缩方案用于参考，不等于正式课表。Android仅展示Mac同步的结果，不运行算法、不提供算法参数、不写入正式日程；输入变化后旧结果需标为待更新。助手只读现有结果，不发起计算。"),
        ("备份与恢复", "备份 恢复 删除 数据", "在备份界面查看恢复点并核对内容；恢复、删除等高风险操作需由用户在原界面确认。助手不读取备份内容，不执行恢复或删除。"),
        ("助手与隐私", "助手 API 密钥 OpenAI Grok xAI DeepSeek 隐私", "助手通过用户配置的OpenAI、xAI/Grok或DeepSeek API回答，模型需支持工具调用。问题原文和本窗口已同意的上下文会发送到配置的地址；每批新增个人数据发送前会展示确认。只读工具不能写数据或运行命令。密钥可选存本机钥匙串，关闭窗口清除内存对话；API配置不参与云同步和备份。")
    ]

    static func execute(_ call: AssistantToolCall, context: AssistantContext, id: String) -> AssistantToolResult {
        let definition = definitions.first { $0.name == call.name }
        func result(_ payload: Any, privateData: Bool, denied: Bool = false) -> AssistantToolResult {
            let object: [String: Any] = ["source": definition?.title ?? "受限工具", "captured_at": context.stamp(context.now, time: true),
                                       "time_zone": context.calendar.timeZone.identifier, "data": payload]
            guard let text = try? encodedPayload(object) else {
                return .init(id: id, callID: call.id, title: "查询结果编码失败",
                             content: "[\(id)] {\"error\":\"无法安全编码查询结果，未提供数据。\"}", privateData: false, denied: true)
            }
            return .init(id: id, callID: call.id, title: definition?.title ?? "拒绝不支持的操作",
                         content: "[\(id)] " + text, privateData: privateData, denied: denied)
        }
        func failure(_ text: String) -> AssistantToolResult { result(["error": text], privateData: false, denied: true) }
        guard let definition else { return failure("不支持此工具。只允许提供的只读查询，不允许修改、删除、文件、网络或命令操作。") }
        guard call.arguments.utf8.count <= 6000,
              let args = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any],
              Set(args.keys) == Set(definition.fields.keys) else { return failure("参数不符合工具定义，请使用所有且仅使用定义的字段。") }
        for field in definition.fields.keys where field != "offset" {
            guard let value = args[field] as? String, value.count <= 300 else { return failure("参数必须为不超过300字符的字符串。") }
        }
        func date(_ field: String) -> Date? {
            guard let value = args[field] as? String else { return nil }
            if value.isEmpty && field == "date" { return context.selectedDay }
            let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian)
            format.timeZone = context.calendar.timeZone; format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
            guard let date = format.date(from: value), format.string(from: date) == value else { return nil }
            return date
        }
        let courses = context.courses
        var course: Course?
        if let reference = args["course"] as? String, !reference.isEmpty {
            guard reference.hasPrefix("课程"), let index = Int(reference.dropFirst(2)),
                  index > 0, index <= courses.count, reference == "课程\(index)" else {
                return failure("课程编号无效。请先调用list_courses，不要按名称猜测编号。")
            }
            course = courses[index - 1]
        }
        switch call.name {
        case "search_help":
            let query = (args["query"] as! String).lowercased()
            let matched = help.filter { item in
                query.isEmpty || item.keywords.lowercased().split(separator: " ").contains { query.contains($0) }
            }
            let selected = matched.isEmpty ? help : matched
            return result(selected.map { ["topic": $0.title, "description": $0.text] }, privateData: false)
        case "list_courses":
            guard let offset = args["offset"] as? NSNumber, CFGetTypeID(offset) != CFBooleanGetTypeID(),
                  offset.doubleValue.isFinite, offset.doubleValue.rounded() == offset.doubleValue,
                  offset.doubleValue >= 0, offset.doubleValue <= Double(courses.count) else { return failure("offset必须是0至课程总数之间的整数。") }
            let start = offset.intValue, end = min(start + 20, courses.count)
            let rows: [[String: Any]] = courses[start..<end].enumerated().map { index, value in
                ["reference": "课程\(start + index + 1)", "untrusted_name": String(value.name.prefix(120)),
                 "type": value.type.displayName, "auto_schedule": value.autoScheduleEnabled,
                 "website_source": value.webCourse != nil, "netdisk_source": value.netdisk != nil,
                 "merged": value.mergedSources != nil]
            }
            return result(["courses": rows, "total": courses.count, "next_offset": end < courses.count ? end as Any : NSNull()], privateData: true)
        case "inspect_schedule":
            guard let day = date("date") else { return failure("日期无效，请使用真实的yyyy-MM-dd日期。") }
            let evidence = AssistantEvidence.build(state: context.state, day: day, courseID: course?.id, includeNames: false,
                now: context.now, calendar: context.calendar, result: context.result, dailyWarningMinutes: context.dailyWarningMinutes)
            return result(["date": context.stamp(day), "facts": evidence.facts.map(\.statement),
                           "scope_note": "更多日期或课程可继续调用本工具；课程名称请用list_courses对应。"], privateData: true)
        case "inspect_course":
            guard let course else { return failure("请先用list_courses找到准确的课程编号。") }
            let lessons = context.state.lessonWorkItems(for: course)
            guard let offset = args["offset"] as? NSNumber, CFGetTypeID(offset) != CFBooleanGetTypeID(),
                  offset.doubleValue.isFinite, offset.doubleValue.rounded() == offset.doubleValue,
                  offset.doubleValue >= 0, offset.doubleValue <= Double(lessons.count) else { return failure("offset必须是0至课节总数之间的整数。") }
            let start = offset.intValue, end = min(start + 20, lessons.count)
            let rows: [[String: Any]] = lessons[start..<end].enumerated().map { index, lesson in
                ["position": start + index + 1, "untrusted_name": String(lesson.name.prefix(120)),
                 "duration_minutes": lesson.durationMinutes, "remaining_minutes": lesson.remainingMinutes]
            }
            return result(["reference": args["course"]!, "untrusted_name": String(course.name.prefix(120)),
                           "total_minutes": course.totalMinutes, "completed_minutes": context.state.completedMinutes(for: course),
                           "remaining_minutes": context.state.remainingMinutes(for: course),
                           "start": context.stamp(course.startDate), "deadline": context.stamp(course.deadline),
                           "lessons": rows, "lesson_count": lessons.count,
                           "next_offset": end < lessons.count ? end as Any : NSNull()], privateData: true)
        case "inspect_progress":
            guard let start = date("start_date"), let end = date("end_date"), start <= end,
                  let span = context.calendar.dateComponents([.day], from: start, to: end).day, span < 31 else {
                return failure("日期范围必须有效、起日不晚于止日且不超过31天。可分段查询。")
            }
            let tasks = Dictionary(context.state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let analyzer = DailyConsequenceAnalyzer(calendar: context.calendar)
            let records = context.state.completions.filter { course == nil || $0.courseID == course?.id }.map {
                (record: $0, day: analyzer.effectiveDay($0, task: tasks[$0.taskID])?.date)
            }
            func sum(_ values: [Int]) throws -> Int {
                try values.reduce(0) { accumulated, next in
                    let value = accumulated.addingReportingOverflow(next)
                    guard !value.overflow, next >= 0 else { throw AssistantError.invalidResponse }; return value.partialValue
                }
            }
            do {
                let days: [[String: Any]] = try (0...span).map { offset in
                    let day = context.calendar.date(byAdding: .day, value: offset, to: start)!
                    let actual = records.filter { $0.day.map { context.calendar.isDate($0, inSameDayAs: day) } == true }
                    let planned = context.state.tasks.filter { (course == nil || $0.courseID == course?.id) && context.calendar.isDate($0.start, inSameDayAs: day) }
                    return ["date": context.stamp(day), "actual_minutes": try sum(actual.map { $0.record.minutes }),
                            "planned_minutes": try sum(planned.map(\.durationMinutes)), "confirmation_count": actual.count]
                }
                return result(["days": days, "all_history_undated_minutes": try sum(records.filter { $0.day == nil }.map { $0.record.minutes }),
                               "rule": "按实际学习日统计；计划包含历史任务，不等于实际学习；重复学习未必增加有效进度；日期不明的旧记录不归入任何一天。"], privateData: true)
            } catch { return failure("记录无法安全合计，请在原界面核对时长。") }
        case "inspect_settings":
            return result(["minimum_block_minutes": context.state.settings.minimumScheduleUnit,
                "daily_load_warning_minutes": max(30, context.dailyWarningMinutes),
                "priority_order": context.state.settings.schedulePriorities.orderedRules.map(\.title),
                "availability": context.state.settings.availability.prefix(100).map { ["weekday": $0.weekday, "start_minute": $0.startMinute, "end_minute": $0.endMinute] },
                "availability_total": context.state.settings.availability.count], privateData: true)
        case "inspect_runtime":
            let value = context.runtime
            return result(["ready": value.ready, "saving": value.saving, "syncing": value.syncing,
                "cloud_enabled": value.cloudEnabled, "has_error": value.hasError, "supervision_bound": value.supervisionBound,
                "supervised_tasks": value.supervisedTasks, "website_auto_update": value.websiteAutoUpdate,
                "website_updating": value.websiteUpdating, "compression_calculating": value.compressionCalculating,
                "backup_count": value.backupCount,
                "cloud_outcome": value.cloudOutcome, "device_outcome": value.deviceOutcome, "supervision_paused": value.supervisionPaused,
                "limitations": "同步结果只表示本机当前状态文案，不保证远端一致。摘要不包含错误原文、完整历史、权限明细、实际播放检测、服务器或手机状态，无法据此断言具体失败原因。"], privateData: true)
        case "inspect_compression":
            guard let preview = context.state.settings.compressedSchedulePreview else {
                return result(["available": false, "calculating": context.runtime.compressionCalculating], privateData: true)
            }
            let current = (try? CompressedSchedulePreview.signature(context.state)) == preview.sourceSignature
                && preview.inputDay == SyncLedger.day(context.now) && !context.runtime.compressionCalculating
            return result(["available": true, "current": current, "captured_at": context.stamp(preview.capturedAt, time: true),
                "finish": preview.finish.map { context.stamp($0, time: true) } ?? "未提供",
                "course_count": preview.courses.count, "total_rows": preview.totalRows,
                "rule": "current=false表示旧结果待更新，不能当成当前保证；仅为预览，不是正式课表。"], privateData: true)
        default: return failure("工具不可用。")
        }
    }
}
