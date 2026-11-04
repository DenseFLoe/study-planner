package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class SchedulePreviewTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 480);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject fixture() throws Exception {
        JSONObject state = PlannerTests.empty(), course = PlannerTests.course("分页预览", 205, DAY, DAY.plusDays(7), 1);
        JSONArray lessons = new JSONArray();
        for (int i = 1; i <= 205; i++) lessons.put(new JSONObject().put("id", "lesson-" + i).put("name", "第" + i + "节").put("durationMinutes", 1));
        course.put("type", "不定时录播课程").put("manualLessons", lessons); state.getJSONArray("courses").put(course);
        state.getJSONObject("settings").put("minimumScheduleUnit", 1);
        for (int weekday = 1; weekday <= 7; weekday++) state.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(weekday, 480, 1380));
        return state;
    }
    static String id(JSONObject state) throws Exception { return state.getJSONArray("courses").getJSONObject(0).getString("id"); }
    static void futureOnlyAndPages() throws Exception {
        JSONObject state = fixture();
        state.getJSONArray("tasks").put(Planner.task(id(state), Planner.at(DAY.minusDays(1), 480), 1).put("lessonID", "lesson-1").put("lessonName", "旧待确认任务"));
        String before = SyncLedger.canonical(state);
        SchedulePreview result = SchedulePreview.calculate(state, id(state), NOW);
        check(result.plannedMinutes == 205 && result.remainingMinutes == 205, "Preview counted overdue history as new capacity");
        check(result.count() == 205 && result.pageCount() == 3, "Preview truncated planned lessons");
        check(result.page(0).size() == 100 && result.page(1).size() == 100 && result.page(2).size() == 5, "Preview pagination incorrect");
        check(result.page(-1).isEmpty() && result.page(3).isEmpty(), "Out-of-range preview page accepted");
        for (int page = 0; page < result.pageCount(); page++) check(result.page(page).stream().noneMatch(row -> row.contains("旧待确认任务")), "Overdue task leaked into future preview");
        check(before.equals(SyncLedger.canonical(state)), "Preview persisted projected plans or changed progress");
    }
    static void capacityAndConfirmations() throws Exception {
        JSONObject state = fixture(); state.getJSONObject("settings").put("availability", new JSONArray());
        SchedulePreview none = SchedulePreview.calculate(state, id(state), NOW);
        check(none.count() == 0 && none.plannedMinutes == 0 && none.remainingMinutes == 205, "No-capacity preview hid missing work");
        state = fixture(); JSONObject task = Planner.task(id(state), NOW, 1).put("lessonID", "lesson-1");
        state.getJSONArray("tasks").put(task); Planner.confirm(state, task.getString("id"), 1, NOW);
        String before = SyncLedger.canonical(state);
        SchedulePreview result = SchedulePreview.calculate(state, id(state), NOW);
        check(result.remainingMinutes == 204 && result.plannedMinutes == 204 && result.count() == 204, "Preview replanned confirmed progress");
        check(before.equals(SyncLedger.canonical(state)), "Confirmed preview changed real state");
    }
    static void rejectedCourses() throws Exception {
        JSONObject state = fixture(); String id = id(state);
        for (boolean archived : new boolean[]{true, false}) {
            if (archived) state.getJSONArray("courses").getJSONObject(0).put("isArchived", true); else state.put("courses", new JSONArray());
            String before = SyncLedger.canonical(state);
            try { SchedulePreview.calculate(state, id, NOW); throw new AssertionError("Removed course preview accepted"); }
            catch (IllegalArgumentException expected) { check(before.equals(SyncLedger.canonical(state)), "Failed preview changed state"); }
        }
    }
    public static void main(String[] args) throws Exception {
        futureOnlyAndPages(); capacityAndConfirmations(); rejectedCourses();
        System.out.println("SchedulePreviewTests: " + checks + " checks passed");
    }
}
