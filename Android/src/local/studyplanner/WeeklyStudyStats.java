package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.*;

/** Planned time and credited learning are separate; historical dates are never guessed. */
final class WeeklyStudyStats {
    static final class Course {
        final String id, name, color;
        private final long[] planned = new long[7], studied = new long[7];
        Course(String id, String name, String color) { this.id = id; this.name = name; this.color = color; }
        long planned(int day) { return planned[day]; }
        long studied(int day) { return studied[day]; }
        boolean visible() { for (int i = 0; i < 7; i++) if (planned[i] > 0 || studied[i] > 0) return true; return false; }
    }
    final LocalDate monday;
    final List<Course> courses;
    final long plannedMinutes, studiedMinutes, undatedMinutes;
    private final long[] planned = new long[7], studied = new long[7];
    private WeeklyStudyStats(LocalDate monday, Collection<Course> values, long undated) {
        this.monday = monday; undatedMinutes = undated;
        List<Course> visible = new ArrayList<>(); long plan = 0, actual = 0;
        for (Course course : values) if (course.visible()) {
            visible.add(course);
            for (int day = 0; day < 7; day++) { planned[day] += course.planned(day); studied[day] += course.studied(day); }
        }
        for (int day = 0; day < 7; day++) { plan += planned[day]; actual += studied[day]; }
        plannedMinutes = plan; studiedMinutes = actual; courses = Collections.unmodifiableList(visible);
    }
    long planned(int day) { return planned[day]; }
    long studied(int day) { return studied[day]; }
    private static int index(LocalDate monday, LocalDate day) {
        if (day == null) return -1;
        long index = ChronoUnit.DAYS.between(monday, day); return index >= 0 && index < 7 ? (int) index : -1;
    }
    private static Course course(Map<String, Course> courses, String id) {
        return courses.computeIfAbsent(id, key -> new Course(key, "已删除课程", "blue"));
    }
    static WeeklyStudyStats calculate(JSONObject state, LocalDate selected) {
        LocalDate monday = selected.minusDays(selected.getDayOfWeek().getValue() - 1);
        Map<String, Course> courses = new LinkedHashMap<>(); Map<String, JSONObject> tasks = new HashMap<>();
        for (JSONObject value : Planner.list(state.optJSONArray("courses"))) {
            String id = value.optString("id");
            courses.put(id, new Course(id, value.optString("name"), value.optString("color")));
        }
        for (JSONObject task : Planner.list(state.optJSONArray("tasks"))) {
            tasks.put(task.optString("id"), task);
            int day = index(monday, Planner.day(task.optDouble("start")));
            if (day >= 0) course(courses, task.optString("courseID")).planned[day] += task.optInt("durationMinutes");
        }
        long undated = 0;
        for (JSONObject record : Planner.list(state.optJSONArray("completions"))) {
            LocalDate date = DailyConsequences.effectiveDayWithTask(record, tasks.get(record.optString("taskID")));
            int minutes = record.optInt("minutes");
            if (date == null) { undated += minutes; continue; }
            int day = index(monday, date);
            if (day >= 0) course(courses, record.optString("courseID")).studied[day] += minutes;
        }
        return new WeeklyStudyStats(monday, courses.values(), undated);
    }
}
