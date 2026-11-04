package local.studyplanner;

import org.json.*;
import java.time.LocalDate;

public final class WeeklyStudyStatsTests {
    static int checks;
    static final LocalDate MONDAY = LocalDate.of(2026, 11, 2);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject task(JSONObject state, String course, LocalDate date, int duration) throws Exception {
        JSONObject task = Planner.task(course, Planner.at(date, 480), duration); state.getJSONArray("tasks").put(task); return task;
    }
    static void record(JSONObject state, String course, JSONObject task, int minutes, LocalDate studied, LocalDate recorded) throws Exception {
        JSONObject record = new JSONObject().put("id", Planner.id()).put("courseID", course).put("taskID", task.getString("id"))
            .put("minutes", minutes).put("recordedAt", Planner.at(recorded, 600));
        if (studied != null) record.put("studyDate", Planner.at(studied, 0)); state.getJSONArray("completions").put(record);
        task.put("completedMinutes", minutes).put("status", minutes == 0 ? "missed" : "completed");
    }
    static void datesAndProgress() throws Exception {
        JSONObject state = PlannerTests.empty(), course = PlannerTests.course("化工原理", 600, MONDAY, MONDAY.plusDays(20), 60);
        state.getJSONArray("courses").put(course); String id = course.getString("id");
        task(state, id, MONDAY, 90); // Pending time must never become studied time.
        JSONObject early = task(state, id, MONDAY.plusDays(1), 60);
        record(state, id, early, 45, MONDAY.minusDays(1), MONDAY); // Outside the selected week.
        JSONObject late = task(state, id, MONDAY.minusDays(1), 120);
        record(state, id, late, 80, MONDAY.plusDays(2), MONDAY.plusDays(4));
        JSONObject missed = task(state, id, MONDAY.plusDays(3), 60);
        record(state, id, missed, 0, MONDAY.plusDays(3), MONDAY.plusDays(3));
        JSONObject partial = task(state, id, MONDAY.plusDays(4), 90);
        record(state, id, partial, 30, MONDAY.plusDays(4), MONDAY.plusDays(5));
        JSONObject next = task(state, id, MONDAY.plusDays(7), 30);
        record(state, id, next, 30, MONDAY.plusDays(7), MONDAY.plusDays(7));
        String before = SyncLedger.canonical(state);
        WeeklyStudyStats stats = WeeklyStudyStats.calculate(state, MONDAY.plusDays(6));
        check(stats.monday.equals(MONDAY), "Sunday selected the next week");
        check(stats.plannedMinutes == 300 && stats.studiedMinutes == 110, "Planned and studied time were mixed");
        check(stats.planned(1) == 60 && stats.studied(1) == 0, "Early completion was assigned to its scheduled date");
        check(stats.studied(2) == 80 && stats.planned(2) == 0, "Backfill was assigned to confirmation or original task date");
        check(stats.studied(3) == 0 && stats.planned(3) == 60, "Missed task disappeared from plan or became studied time");
        check(stats.studied(4) == 30 && stats.planned(4) == 90, "Partial completion changed planned minutes");
        check(WeeklyStudyStats.calculate(state, MONDAY.plusDays(7)).studiedMinutes == 30, "Next-week boundary incorrect");
        check(WeeklyStudyStats.calculate(state, MONDAY.minusDays(1)).studiedMinutes == 45, "Previous-week boundary incorrect");
        check(before.equals(SyncLedger.canonical(state)), "Statistics changed source records");
        course.put("isArchived", true);
        check(WeeklyStudyStats.calculate(state, MONDAY).studiedMinutes == 110, "Archiving hid historical learning");
        try { stats.courses.clear(); throw new AssertionError("Mutable result collection"); }
        catch (UnsupportedOperationException expected) { checks++; }
        course.put("name", "新名字"); check(stats.courses.get(0).name.equals("化工原理"), "Statistics retained mutable source object");
    }
    static void legacyAndLargeTotals() throws Exception {
        JSONObject state = PlannerTests.empty(); String id = Planner.id();
        JSONObject sameDay = task(state, id, MONDAY, 60);
        record(state, id, sameDay, 40, null, MONDAY);
        JSONObject ambiguous = task(state, id, MONDAY, 60);
        record(state, id, ambiguous, 50, null, MONDAY.plusDays(1));
        JSONObject removed = new JSONObject().put("id", Planner.id());
        record(state, id, removed, 20, MONDAY.plusDays(2), MONDAY.plusDays(3));
        record(state, id, removed, 10, null, MONDAY.plusDays(2));
        WeeklyStudyStats stats = WeeklyStudyStats.calculate(state, MONDAY);
        check(stats.studiedMinutes == 60 && stats.studied(0) == 40 && stats.studied(2) == 20, "Unambiguous legacy or orphan explicit date lost");
        check(stats.undatedMinutes == 60, "Ambiguous legacy dates were guessed or hidden");
        check(stats.courses.get(0).name.equals("已删除课程"), "Missing course hid preserved records");
        state = PlannerTests.empty();
        for (int i = 0; i < 3; i++) { JSONObject t = task(state, id, MONDAY, 1000000000); record(state, id, t, 1000000000, MONDAY, MONDAY); }
        stats = WeeklyStudyStats.calculate(state, MONDAY);
        check(stats.studiedMinutes == 3000000000L && stats.plannedMinutes == 3000000000L, "Minute totals overflowed int");
        stats = WeeklyStudyStats.calculate(PlannerTests.empty(), MONDAY);
        check(stats.courses.isEmpty() && stats.plannedMinutes == 0 && stats.studiedMinutes == 0, "Empty week contains work");
    }
    public static void main(String[] args) throws Exception {
        datesAndProgress(); legacyAndLargeTotals();
        System.out.println("WeeklyStudyStatsTests: " + checks + " checks passed");
    }
}
