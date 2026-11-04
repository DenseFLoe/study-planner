package local.studyplanner;

import org.json.*;
import java.util.*;

/** An immutable, paged projection of the future plan; never writes to its source state. */
public final class SchedulePreview {
    public static final int PAGE_SIZE = 100;
    public final String courseName;
    public final long plannedMinutes, remainingMinutes;
    private final List<String> rows;
    private SchedulePreview(String name, long planned, long remaining, List<String> rows) {
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
        Map<String, JSONObject> courses = Collections.singletonMap(courseID, course);
        return render(state, courses, tasks, course.getString("name"));
    }
    /** Summarize an already calculated import plan without recalculating or persisting it. */
    static SchedulePreview fromPlan(JSONObject state, Set<String> courseIDs, String name, double now) throws Exception {
        Map<String, JSONObject> courses = new LinkedHashMap<>();
        for (JSONObject course : Planner.list(state.getJSONArray("courses")))
            if (courseIDs.contains(course.getString("id")) && !course.optBoolean("isArchived")) courses.put(course.getString("id"), course);
        if (courses.isEmpty() || courses.size() != courseIDs.size()) throw new IllegalArgumentException("部分预览课程已不存在，请重新核对所选课程。");
        List<JSONObject> tasks = new ArrayList<>();
        for (JSONObject task : Planner.list(state.getJSONArray("tasks")))
            if (courses.containsKey(task.optString("courseID")) && Planner.pending(task) && Planner.planningEnd(task) > now) tasks.add(task);
        return render(state, courses, tasks, name);
    }
    private static SchedulePreview render(JSONObject state, Map<String, JSONObject> courses, List<JSONObject> tasks, String name) throws Exception {
        tasks.sort(Comparator.comparingDouble((JSONObject t) -> t.optDouble("start")).thenComparing(t -> t.optString("id")));
        List<String> rows = new ArrayList<>(); long total = 0, remaining = 0;
        for (JSONObject course : courses.values()) remaining = Math.addExact(remaining, Planner.remaining(state, course));
        for (JSONObject task : tasks) {
            JSONObject course = courses.get(task.getString("courseID"));
            int minutes = task.getInt("durationMinutes"); total = Math.addExact(total, minutes);
            String lesson = task.optString("lessonName"); if (lesson.isEmpty()) lesson = course.getString("name");
            else if (courses.size() > 1) lesson = course.getString("name") + " / " + lesson;
            rows.add(Planner.date(task.getDouble("start")) + " " + Planner.clock(Planner.planningStart(task)) + "–" + Planner.clock(Planner.planningEnd(task)) +
                (Planner.floatingTask(task) ? " 内浮动" : "") + "\n" + lesson + " · " + minutes + " 分钟");
        }
        return new SchedulePreview(name, total, remaining, rows);
    }
}
