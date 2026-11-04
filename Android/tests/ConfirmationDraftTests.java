package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class ConfirmationDraftTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 480);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    interface Action { void run() throws Exception; }
    static void rejected(JSONObject state, Action action) throws Exception {
        String before = SyncLedger.canonical(state);
        try { action.run(); throw new AssertionError("Stale/invalid confirmation accepted"); }
        catch (IllegalArgumentException expected) { check(before.equals(SyncLedger.canonical(state)), "Rejected batch changed state"); }
    }
    static JSONObject fixture() throws Exception {
        JSONObject state = PlannerTests.empty();
        JSONObject course = PlannerTests.course("课程", 240, DAY, DAY.plusDays(3), 60);
        state.getJSONArray("courses").put(course);
        state.getJSONArray("tasks").put(Planner.task(course.getString("id"), NOW, 60).put("id", "a"))
            .put(Planner.task(course.getString("id"), NOW + 7200, 60).put("id", "b"));
        return state;
    }
    static ConfirmationDraft draft(JSONObject state) throws Exception { return new ConfirmationDraft(Planner.list(state.getJSONArray("tasks"))); }
    static JSONObject task(JSONObject state, int index) throws Exception { return state.getJSONArray("tasks").getJSONObject(index); }
    static Map<String, Integer> amounts(int a, int b) {
        Map<String, Integer> result = new LinkedHashMap<>(); result.put("a", a); result.put("b", b); return result;
    }
    static Map<String, LocalDate> dates() {
        Map<String, LocalDate> result = new HashMap<>(); result.put("a", DAY.minusDays(1)); result.put("b", DAY); return result;
    }
    static void staleTasks() throws Exception {
        for (String field : new String[]{"start", "durationMinutes", "lessonID", "lessonName", "courseID", "floatingWindowStart", "floatingWindowEnd"}) {
            JSONObject state = fixture(); ConfirmationDraft draft = draft(state); JSONObject task = task(state, 1);
            if (field.equals("durationMinutes")) task.put(field, 90);
            else if (field.equals("start") || field.startsWith("floating")) task.put(field, NOW + 10800);
            else task.put(field, "changed");
            rejected(state, () -> draft.apply(state, amounts(20, 20), dates(), NOW));
        }
        for (String change : new String[]{"deleted", "confirmed", "archived", "removedCourse"}) {
            JSONObject state = fixture(); ConfirmationDraft draft = draft(state);
            if (change.equals("deleted")) state.getJSONArray("tasks").remove(1);
            if (change.equals("confirmed")) Planner.confirm(state, "b", 0, NOW);
            if (change.equals("archived")) state.getJSONArray("courses").getJSONObject(0).put("isArchived", true);
            if (change.equals("removedCourse")) state.getJSONArray("courses").remove(0);
            rejected(state, () -> draft.apply(state, amounts(20, 20), dates(), NOW));
        }
    }
    static void validationAndAtomicity() throws Exception {
        for (int invalid : new int[]{-1, 61}) {
            JSONObject state = fixture(); ConfirmationDraft draft = draft(state);
            rejected(state, () -> draft.apply(state, amounts(20, invalid), dates(), NOW));
        }
        JSONObject state = fixture(); ConfirmationDraft draft = draft(state);
        Map<String, LocalDate> future = dates(); future.put("b", DAY.plusDays(1));
        rejected(state, () -> draft.apply(state, amounts(20, 20), future, NOW));
        Map<String, LocalDate> missing = dates(); missing.remove("b");
        rejected(state, () -> draft.apply(state, amounts(20, 20), missing, NOW));
        rejected(state, () -> draft.apply(state, Collections.emptyMap(), dates(), NOW));
        rejected(state, () -> draft.apply(state, Collections.singletonMap("unseen", 20), dates(), NOW));
        task(state, 1).put("start", NOW + 1);
        check(draft.apply(state, Collections.singletonMap("a", 0), dates(), NOW), "Unfilled changed row blocked a valid missed confirmation");
        check(state.getJSONArray("completions").length() == 1 && Planner.pending(task(state, 1)), "Blank row was confirmed");
    }
    static void preservedProgressAndDates() throws Exception {
        JSONObject state = fixture(); ConfirmationDraft draft = draft(state);
        JSONObject course = state.getJSONArray("courses").getJSONObject(0);
        course.put("name", "同步改名").put("initialCompletedMinutes", 200);
        task(state, 0).put("status", "planned");
        check(draft.apply(state, amounts(30, 30), dates(), NOW), "Partial batch did not request replan");
        check(task(state, 0).getInt("completedMinutes") == 30 && task(state, 1).getInt("completedMinutes") == 10,
            "Batch did not use latest progress with deterministic order");
        JSONArray records = state.getJSONArray("completions");
        check(Planner.day(records.getJSONObject(0).getDouble("studyDate")).equals(DAY.minusDays(1)), "Backfill date lost");
        check(Planner.day(records.getJSONObject(1).getDouble("studyDate")).equals(DAY), "Current study date lost");
        check(course.getString("name").equals("同步改名") && course.getInt("initialCompletedMinutes") == 200, "Fresh course edits lost");
        rejected(state, () -> draft.apply(state, amounts(30, 30), dates(), NOW));
    }
    static void currentTimeAndFloating() throws Exception {
        for (double now : new double[]{NOW + 3599, NOW + 3600}) {
            JSONObject state = fixture(); ConfirmationDraft draft = draft(state);
            check(draft.apply(state, Collections.singletonMap("a", 60), dates(), now) == (now >= NOW + 3600),
                "Replan used form-opening time");
        }
        for (double now : new double[]{NOW + 3600, NOW + 5400}) {
            JSONObject state = fixture();
            task(state, 0).put("floatingWindowStart", NOW).put("floatingWindowEnd", NOW + 5400);
            ConfirmationDraft draft = draft(state);
            check(draft.apply(state, Collections.singletonMap("a", 60), dates(), now) == (now >= NOW + 5400),
                "Floating confirmation ignored reserved window end");
        }
    }
    static void staleUndo() throws Exception {
        for (String change : new String[]{"reconfirmed", "date", "minutes", "removedRecord", "removedTask", "undone"}) {
            JSONObject state = fixture(); Planner.confirm(state, "a", 20, NOW);
            ConfirmationDraft.Undo undo = new ConfirmationDraft.Undo(state, task(state, 0));
            if (change.equals("reconfirmed")) {
                Planner.undoConfirmation(state, "a", NOW + 1); Planner.confirm(state, "a", 20, NOW + 2);
            }
            if (change.equals("date")) state.getJSONArray("completions").getJSONObject(0).put("studyDate", Planner.at(DAY.minusDays(1), 0));
            if (change.equals("minutes")) state.getJSONArray("completions").getJSONObject(0).put("minutes", 30);
            if (change.equals("removedRecord")) state.getJSONArray("completions").remove(0);
            if (change.equals("removedTask")) state.getJSONArray("tasks").remove(0);
            if (change.equals("undone")) Planner.undoConfirmation(state, "a", NOW + 1);
            rejected(state, () -> undo.apply(state, NOW + 3));
        }
        for (int actual : new int[]{0, 20, 60}) {
            JSONObject state = fixture(); Planner.confirm(state, "a", actual, NOW);
            ConfirmationDraft.Undo undo = new ConfirmationDraft.Undo(state, task(state, 0));
            Planner.confirm(state, "b", 30, NOW + 1);
            state.getJSONArray("courses").getJSONObject(0).put("name", "同步后的名称");
            String other = SyncLedger.canonical(task(state, 1));
            undo.apply(state, NOW + 2);
            check(Planner.pending(task(state, 0)) && task(state, 0).getInt("completedMinutes") == 0, "Reviewed confirmation was not undone");
            check(state.getJSONArray("completions").length() == 1 && other.equals(SyncLedger.canonical(task(state, 1))), "Undo removed another task's confirmation");
            check(state.getJSONArray("courses").getJSONObject(0).getString("name").equals("同步后的名称"), "Undo replaced unrelated course metadata");
        }
    }
    public static void main(String[] args) throws Exception {
        staleTasks(); validationAndAtomicity(); preservedProgressAndDates(); currentTimeAndFloating(); staleUndo();
        System.out.println("ConfirmationDraftTests: " + checks + " checks passed");
    }
}
