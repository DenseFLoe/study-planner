package local.studyplanner;

import org.json.*;
import java.util.*;

/** An immutable, paged projection of the future plan; never writes to its source state. */
public final class SchedulePreview {
    public static final int PAGE_SIZE = 100;
    public final String courseName;
    public final int plannedMinutes, remainingMinutes;
    private final List<String> rows;
    private SchedulePreview(String name, int planned, int remaining, List<String> rows) {
        courseName = name; plannedMinutes = planned; remainingMinutes = remaining;
        this.rows = Collections.unmodifiableList(rows);
    }
    public int count() { return rows.size(); }
    public int pageCount() { return rows.isEmpty() ? 0 : (rows.size() - 1) / PAGE_SIZE + 1; }
    public List<String> page(int index) {
        if (index < 0 || index >= pageCount()) return Collections.emptyList();
        int first = index * PAGE_SIZE; return rows.subList(first, Math.min(first + PAGE_SIZE, rows.size()));
    }
    public static SchedulePreview calculate(JSONObject state, String courseID, double now) throws Exception {
        JSONObject course = Planner.course(state, courseID);
        if (course == null || course.optBoolean("isArchived")) throw new IllegalArgumentException("这门课程已不存在，请刷新课程列表后重试。");
        List<JSONObject> tasks = CourseTools.preview(state, course, now);
        tasks.sort(Comparator.comparingDouble((JSONObject t) -> t.optDouble("start")).thenComparing(t -> t.optString("id")));
        List<String> rows = new ArrayList<>(); int total = 0;
        for (JSONObject task : tasks) {
            int minutes = task.getInt("durationMinutes"); total = Math.addExact(total, minutes);
            String lesson = task.optString("lessonName"); if (lesson.isEmpty()) lesson = course.getString("name");
            rows.add(Planner.date(task.getDouble("start")) + " " + Planner.clock(Planner.planningStart(task)) + "–" + Planner.clock(Planner.planningEnd(task)) +
                (Planner.floatingTask(task) ? " 内浮动" : "") + "\n" + lesson + " · " + minutes + " 分钟");
        }
        return new SchedulePreview(course.getString("name"), total, Planner.remaining(state, course), rows);
    }
}
