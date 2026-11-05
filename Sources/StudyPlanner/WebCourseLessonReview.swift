import Foundation
import StudyCore

/// Stable display identities let incomplete or duplicate provider rows remain reviewable.
struct WebCourseLessonReview: Identifiable, Sendable {
    let id: Int
    let title: String
    let location: String
    let details: String
    let problem: String?

    static func rows(_ lessons: [WebCourseLesson]) -> [Self] {
        let counts = lessons.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 }
        return lessons.enumerated().map { index, lesson in
            var problems: [String] = []
            if lesson.id.isEmpty { problems.append("课节标识缺失，请重新抓取") }
            else if counts[lesson.id, default: 0] > 1 { problems.append("课节标识重复，请重新抓取") }
            let timed = lesson.published && lesson.requiresDuration
            let duration: String
            if let seconds = lesson.durationSeconds {
                if seconds.isFinite && seconds > 0 && seconds <= 36_000_000 { duration = WebLessonTiming.clock(seconds) }
                else { duration = "时长无效"; problems.append("时长无效") }
            } else {
                duration = "时长待定"
                if timed { problems.append("缺少时长") }
            }
            let progress: String
            if let percent = lesson.watchedPercent {
                if percent.isFinite && percent >= 0 && percent <= 100 { progress = String(format: "%.1f%%", percent) }
                else { progress = "无效"; problems.append("观看进度无效") }
            } else {
                progress = "未知"
                if timed { problems.append("缺少观看进度") }
            }
            var details = [lesson.published ? "已发布" : "尚未发布", duration, "观看进度 \(progress)"]
            if !lesson.requiresDuration { details.append("不计入视频学习量") }
            if lesson.markedFinished { details.append("网站标记已完成") }
            return Self(id: index, title: "\(index + 1). \(lesson.name)",
                        location: [lesson.subject, lesson.stage, lesson.chapter].filter { !$0.isEmpty }.joined(separator: " / "),
                        details: details.joined(separator: " · "), problem: problems.isEmpty ? nil : problems.joined(separator: "；"))
        }
    }
}
