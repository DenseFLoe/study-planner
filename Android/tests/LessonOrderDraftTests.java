package local.studyplanner;

import org.json.*;
import java.time.*;
import java.util.*;

public final class LessonOrderDraftTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 480);
    static final List<String> REORDERED = Arrays.asList("b", "a", "c"), RETAINED = Arrays.asList("b", "c");
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject fixture() throws Exception {
        JSONObject state = PlannerTests.empty(), course = PlannerTests.course("排序课程", 180, DAY, DAY.plusDays(7), 60);
        JSONArray lessons = new JSONArray();
        for (String id : Arrays.asList("a", "b", "c")) lessons.put(new JSONObject().put("id", id).put("name", id).put("durationMinutes", 60));
        state.getJSONArray("courses").put(course.put("type", "不定时录播课程").put("manualLessons", lessons)
            .put("lessonOrder", new JSONArray(Arrays.asList("a", "b", "c"))));
        return state;
    }
    static JSONObject course(JSONObject state) throws Exception { return state.getJSONArray("courses").getJSONObject(0); }
    static LessonOrderDraft draft(JSONObject state) throws Exception { return new LessonOrderDraft(state, course(state).getString("id")); }
    static void confirm(JSONObject state, String lesson, int minutes) throws Exception {
        JSONObject task = Planner.task(course(state).getString("id"), NOW - 7200, 60).put("lessonID", lesson);
        state.getJSONArray("tasks").put(task); Planner.confirm(state, task.getString("id"), minutes, NOW);
    }
    static void rejected(LessonOrderDraft draft, JSONObject state, List<String> order, Set<String> deleted, String message) throws Exception {
        String before = SyncLedger.canonical(state);
        try { draft.apply(state, order, deleted); throw new AssertionError(message); }
        catch (IllegalArgumentException expected) { check(before.equals(SyncLedger.canonical(state)), "Rejected operation changed current data"); }
    }
    static void staleAndNoop() throws Exception {
        JSONObject state = fixture(); LessonOrderDraft draft = draft(state);
        course(state).put("lessonOrder", new JSONArray(Arrays.asList("c", "a", "b")));
        rejected(draft, state, REORDERED, Collections.emptySet(), "Stale ordering accepted");
        String before = SyncLedger.canonical(state);
        draft.apply(state, draft.originalOrder(), Collections.emptySet());
        check(before.equals(SyncLedger.canonical(state)), "Unchanged form overwrote new ordering");
        JSONObject preview = fixture();
        // Baseline identity is retained across failures, rather than rewritten from current data.
        preview.getJSONArray("courses").getJSONObject(0).put("id", course(state).getString("id"));
        draft.apply(preview, REORDERED, Collections.emptySet());
        check(CourseTools.order(course(preview)).equals(REORDERED), "Rejected save corrupted the draft baseline");
    }
    static void independentChanges() throws Exception {
        JSONObject state = fixture(); LessonOrderDraft draft = draft(state);
        confirm(state, "a", 20); course(state).put("name", "同步改名").put("priority", 3);
        String records = state.getJSONArray("completions").toString(), tasks = state.getJSONArray("tasks").toString();
        draft.apply(state, REORDERED, Collections.emptySet());
        check(records.equals(state.getJSONArray("completions").toString()) && tasks.equals(state.getJSONArray("tasks").toString()), "Reorder changed confirmation evidence");
        check(course(state).getString("name").equals("同步改名") && course(state).getInt("priority") == 3, "Reorder overwrote independent changes");
        String after = SyncLedger.canonical(state); draft.apply(state, REORDERED, Collections.emptySet());
        check(after.equals(SyncLedger.canonical(state)), "Identical order was not idempotent");
    }
    static void changedCatalogAndInvalidOrders() throws Exception {
        for (String change : Arrays.asList("add", "delete", "rename", "resize", "removed", "archived")) {
            JSONObject state = fixture(); LessonOrderDraft draft = draft(state);
            if (change.equals("add")) { course(state).getJSONArray("manualLessons").put(new JSONObject().put("id", "d").put("name", "d").put("durationMinutes", 60)); course(state).put("totalMinutes", 240); }
            if (change.equals("delete")) CourseTools.removeLessons(state, course(state).getString("id"), Collections.singleton("a"));
            if (change.equals("rename")) course(state).getJSONArray("manualLessons").getJSONObject(0).put("name", "新课节");
            if (change.equals("resize")) { course(state).getJSONArray("manualLessons").getJSONObject(0).put("durationMinutes", 70); course(state).put("totalMinutes", 190); }
            if (change.equals("removed")) Planner.removeCourse(state, course(state).getString("id"));
            if (change.equals("archived")) course(state).put("isArchived", true);
            rejected(draft, state, REORDERED, Collections.emptySet(), "Catalog change accepted: " + change);
        }
        JSONObject state = fixture(); LessonOrderDraft draft = draft(state);
        for (List<String> order : Arrays.asList(Arrays.asList("a", "a", "c"), Arrays.asList("a", "b"), Arrays.asList("a", "b", "unknown"), Collections.<String>emptyList()))
            rejected(draft, state, order, Collections.emptySet(), "Invalid permutation accepted");
        rejected(draft, state, Collections.emptyList(), new HashSet<>(draft.originalOrder()), "Deleting all lessons accepted");
    }
    static void deletionEvidence() throws Exception {
        JSONObject state = fixture(); LessonOrderDraft draft = draft(state);
        confirm(state, "a", 20);
        rejected(draft, state, RETAINED, Collections.singleton("a"), "New completion deleted");

        state = fixture(); confirm(state, "a", 60); draft = draft(state); confirm(state, "a", 20);
        rejected(draft, state, RETAINED, Collections.singleton("a"), "Extra completion of finished lesson deleted");

        state = fixture(); draft = draft(state); confirm(state, "b", 20);
        course(state).put("notes", "另一课节的记录应保留");
        String records = state.getJSONArray("completions").toString();
        draft.apply(state, RETAINED, Collections.singleton("a"));
        check(records.equals(state.getJSONArray("completions").toString()) && course(state).getInt("totalMinutes") == 120, "Deletion lost unrelated completion");
        check(course(state).getString("notes").equals("另一课节的记录应保留"), "Deletion lost new notes");

        state = fixture(); confirm(state, "a", 20); confirm(state, "b", 20); draft = draft(state);
        draft.apply(state, RETAINED, Collections.singleton("a"));
        check(state.getJSONArray("completions").length() == 1 && state.getJSONArray("tasks").getJSONObject(0).getString("lessonID").equals("b"), "Reviewed deletion removed the wrong history");

        state = fixture(); draft = draft(state);
        state.getJSONArray("tasks").put(Planner.task(course(state).getString("id"), NOW, 60).put("lessonID", "a"));
        draft.apply(state, RETAINED, Collections.singleton("a"));
        check(state.getJSONArray("tasks").length() == 0, "New pending plan incorrectly blocked deletion");
    }
    static void websiteProgress() throws Exception {
        JSONObject state = PlannerTests.empty(), snapshot = LessonDeletionTests.snapshot(NOW, "a", "b", "c");
        WebCourseImport.save(state, Collections.singletonList(snapshot), Planner.at(DAY.plusDays(7), 0), NOW);
        LessonOrderDraft draft = draft(state);
        JSONObject refreshed = CourseTools.copy(snapshot).put("fetchedAt", NOW + 60);
        refreshed.getJSONArray("lessons").getJSONObject(0).put("watchedPercent", 50);
        WebCourseImport.save(state, Collections.singletonList(refreshed), Planner.at(DAY.plusDays(7), 0), NOW + 60);
        rejected(draft, state, RETAINED, Collections.singleton("a"), "New website progress deleted");
        draft.apply(state, REORDERED, Collections.emptySet());
        check(course(state).getJSONObject("webCourse").getJSONArray("lessons").getJSONObject(0).getInt("watchedPercent") == 50, "Reorder lost web progress");
        check(course(state).getBoolean("lessonOrderCustomized"), "Custom ordering mode lost");
        LessonOrderDraft follow = draft(state); follow.apply(state, Arrays.asList("a", "b", "c"), Collections.emptySet());
        check(!course(state).getBoolean("lessonOrderCustomized"), "Website order did not restore follow mode");
        course(state).put("lessonOrderCustomized", true);
        follow = draft(state); follow.apply(state, follow.originalOrder(), Collections.emptySet(), true);
        check(!course(state).getBoolean("lessonOrderCustomized"), "Explicit follow action ignored when visible order already matched");
    }
    public static void main(String[] args) throws Exception {
        staleAndNoop(); independentChanges(); changedCatalogAndInvalidOrders(); deletionEvidence(); websiteProgress();
        System.out.println("LessonOrderDraftTests: " + checks + " checks passed");
    }
}
