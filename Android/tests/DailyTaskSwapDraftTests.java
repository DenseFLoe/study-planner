package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class DailyTaskSwapDraftTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 480);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject fixture() throws Exception {
        JSONObject state = PlannerTests.empty();
        for (int weekday = 1; weekday <= 7; weekday++) state.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(weekday, 480, 1200));
        for (int i = 0; i < 3; i++) {
            JSONObject course = PlannerTests.course("课程" + i, 120, DAY, DAY.plusDays(1), 60);
            state.getJSONArray("courses").put(course);
            state.getJSONArray("tasks").put(Planner.task(course.getString("id"), NOW + i * 4500, 60));
        }
        return state;
    }
    static String id(JSONObject state, int index) throws Exception { return state.getJSONArray("tasks").getJSONObject(index).getString("id"); }
    static DailyTaskSwapDraft draft(JSONObject state) throws Exception { return new DailyTaskSwapDraft(state, id(state, 0), id(state, 1), NOW); }
    static void rejected(DailyTaskSwapDraft draft, JSONObject state, double now) throws Exception {
        String before = SyncLedger.canonical(state);
        try { draft.apply(state, now); throw new AssertionError("Stale swap was accepted"); }
        catch (IllegalArgumentException expected) { check(before.equals(SyncLedger.canonical(state)), "Rejected swap changed current data"); }
    }
    static void previewAndRetry() throws Exception {
        JSONObject state = fixture(); String before = SyncLedger.canonical(state); DailyTaskSwapDraft draft = draft(state);
        check(before.equals(SyncLedger.canonical(state)), "Preview changed source state");
        draft.apply(state, NOW + 60); String after = SyncLedger.canonical(state);
        check(after.equals(SyncLedger.canonical(draft.preview)), "Saved swap differs from preview");
        draft.apply(state, NOW + 120);
        check(after.equals(SyncLedger.canonical(state)), "Repeated or already-synced swap reversed the intended order");
    }
    static void staleChanges() throws Exception {
        for (String change : new String[]{"time", "duration", "name", "confirmed", "removed", "new", "other-swap", "preference"}) {
            JSONObject state = fixture(); DailyTaskSwapDraft draft = draft(state); JSONObject first = state.getJSONArray("tasks").getJSONObject(0);
            switch (change) {
                case "time": first.put("start", NOW + 60); break;
                case "duration": first.put("durationMinutes", 30); break;
                case "name": first.put("lessonName", "同步后的课节"); break;
                case "confirmed": Planner.confirm(state, first.getString("id"), 30, NOW + 60); break;
                case "removed": state.getJSONArray("tasks").remove(0); break;
                case "new": state.getJSONArray("tasks").put(Planner.task(first.getString("courseID"), NOW + 20000, 30)); break;
                case "other-swap": DailyTaskOrdering.swap(state, id(state, 1), id(state, 2), NOW); break;
                case "preference": state.getJSONObject("settings").put("dailyTaskOrders", new JSONArray().put(new JSONObject().put("day", Planner.at(DAY, 0)).put("keys", new JSONArray().put("new")))); break;
            }
            rejected(draft, state, NOW + 120);
        }
        JSONObject state = fixture(); rejected(draft(state), state, Planner.at(DAY.plusDays(1), 0));
    }
    static void independentChangesAndFreshConstraints() throws Exception {
        JSONObject state = fixture(); DailyTaskSwapDraft draft = draft(state);
        state.getJSONArray("courses").getJSONObject(0).put("notes", "另一端新备注");
        JSONObject otherDay = Planner.task(state.getJSONArray("courses").getJSONObject(0).getString("id"), Planner.at(DAY.plusDays(1), 480), 30);
        state.getJSONArray("tasks").put(otherDay); Planner.confirm(state, otherDay.getString("id"), 10, NOW, DAY);
        String records = state.getJSONArray("completions").toString(), other = otherDay.toString();
        draft.apply(state, NOW + 60);
        check(records.equals(state.getJSONArray("completions").toString()) && other.equals(otherDay.toString()), "Swap lost unrelated history");
        check(state.getJSONArray("courses").getJSONObject(0).getString("notes").equals("另一端新备注"), "Swap lost synced metadata");
        state = fixture(); draft = draft(state); state.getJSONObject("settings").put("availability", new JSONArray());
        rejected(draft, state, NOW + 60);
    }
    public static void main(String[] args) throws Exception {
        previewAndRetry(); staleChanges(); independentChangesAndFreshConstraints();
        System.out.println("DailyTaskSwapDraftTests: " + checks + " checks passed");
    }
}
