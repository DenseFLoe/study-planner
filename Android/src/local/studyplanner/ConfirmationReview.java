package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.*;

/** Raw input survives paging; only an explicit save parses all filled rows. */
final class ConfirmationReview {
    static final int PAGE_SIZE = 20;
    final ConfirmationDraft draft;
    private final List<Row> rows;
    static final class Row {
        final int index, maximum;
        final String id, course, lesson;
        final double start, planningStart, planningEnd;
        final boolean floating;
        String minutes = "", studyDate;
        Row(int index, JSONObject task, String course, double now) {
            this.index = index; this.course = course; id = task.optString("id"); lesson = task.optString("lessonName");
            maximum = task.optInt("durationMinutes"); start = task.optDouble("start");
            planningStart = Planner.planningStart(task); planningEnd = Planner.planningEnd(task); floating = Planner.floatingTask(task);
            studyDate = Planner.date(Math.min(start, now));
        }
        String label() {
            return (index + 1) + ". " + Planner.date(start) + " " + Planner.clock(planningStart) +
                (floating ? "–" + Planner.clock(planningEnd) + " 内浮动" : "") + " · " + course +
                (lesson.isEmpty() ? "" : " / " + lesson) + "（最多 " + maximum + " 分钟）";
        }
    }
    static final class InputError extends IllegalArgumentException {
        final int index;
        InputError(Row row, String message) { super("第 " + (row.index + 1) + " 项：" + message); index = row.index; }
    }
    static final class Submission {
        final Map<String, Integer> minutes;
        final Map<String, LocalDate> dates;
        Submission(Map<String, Integer> minutes, Map<String, LocalDate> dates) {
            this.minutes = Collections.unmodifiableMap(minutes); this.dates = Collections.unmodifiableMap(dates);
        }
    }
    ConfirmationReview(JSONObject state, List<JSONObject> displayed, double now) throws Exception {
        draft = new ConfirmationDraft(displayed); List<Row> values = new ArrayList<>(); Map<String, String> courses = new HashMap<>();
        for (JSONObject course : Planner.list(state.optJSONArray("courses"))) courses.put(course.optString("id"), course.optString("name"));
        for (JSONObject task : displayed) values.add(new Row(values.size(), task, courses.getOrDefault(task.optString("courseID"), "已删除课程"), now));
        rows = Collections.unmodifiableList(values);
    }
    int count() { return rows.size(); }
    int pageCount() { return rows.isEmpty() ? 0 : (rows.size() - 1) / PAGE_SIZE + 1; }
    List<Row> page(int index) {
        if (index < 0 || index >= pageCount()) return Collections.emptyList();
        int first = index * PAGE_SIZE; return rows.subList(first, Math.min(rows.size(), first + PAGE_SIZE));
    }
    Submission submission(double now) {
        Map<String, Integer> minutes = new LinkedHashMap<>(); Map<String, LocalDate> dates = new LinkedHashMap<>();
        for (Row row : rows) {
            if (row.minutes.trim().isEmpty()) continue;
            int value;
            try { value = Integer.parseInt(row.minutes.trim()); }
            catch (NumberFormatException error) { throw new InputError(row, "请填写整数分钟，留空暂不确认。"); }
            if (value < 0 || value > row.maximum) throw new InputError(row, "实际时长须在 0–" + row.maximum + " 分钟之间。");
            LocalDate date;
            try { date = LocalDate.parse(row.studyDate.trim()); }
            catch (DateTimeParseException error) { throw new InputError(row, "请填写有效学习日期（YYYY-MM-DD）。"); }
            if (date.isAfter(Planner.day(now))) throw new InputError(row, "实际学习日期不能晚于今天。");
            minutes.put(row.id, value); dates.put(row.id, date);
        }
        if (minutes.isEmpty()) throw new IllegalArgumentException("请至少填写一项。");
        return new Submission(minutes, dates);
    }
}
