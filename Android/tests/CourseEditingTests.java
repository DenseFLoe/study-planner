package local.studyplanner;

import org.json.*;
import java.time.*;
import java.util.*;

public final class CourseEditingTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 480);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    interface Action { void run() throws Exception; }
    static void rejected(JSONObject state, Action action, String message) throws Exception {
        String before = SyncLedger.canonical(state);
        try { action.run(); throw new AssertionError(message); }
        catch (IllegalArgumentException expected) { check(before.equals(SyncLedger.canonical(state)), "Rejected save modified current state"); }
    }
    static JSONObject course() throws Exception {
        return PlannerTests.course("原课程", 180, DAY, DAY.plusDays(7), 60)
            .put("type", "不定时录播课程").put("notes", "原备注").put("color", "blue")
            .put("manualLessons", new JSONArray()
                .put(new JSONObject().put("id", "a").put("name", "第一节").put("durationMinutes", 60))
                .put(new JSONObject().put("id", "b").put("name", "第二节").put("durationMinutes", 120)));
    }
    static JSONObject state(JSONObject course) throws Exception {
        JSONObject state = PlannerTests.empty(); state.getJSONArray("courses").put(CourseTools.copy(course)); return state;
    }
    static void displayAndProgress() throws Exception {
        JSONObject baseline = course(), state = state(baseline), draft = CourseTools.copy(baseline).put("name", "新名称");
        JSONObject current = Planner.course(state, baseline.getString("id"));
        current.put("notes", "另一端备注").put("dailyStudyWeight", 2).put("initialCompletedMinutes", 20);
        current.getJSONArray("manualLessons").getJSONObject(1).put("name", "更新后的第二节");
        JSONObject task = Planner.task(current.getString("id"), NOW, 40).put("lessonID", "b");
        state.getJSONArray("tasks").put(task); Planner.confirm(state, task.getString("id"), 30, NOW + 1);
        String history = state.getJSONArray("completions").toString(), tasks = state.getJSONArray("tasks").toString();
        CourseEditing.save(state, draft, baseline, NOW);
        current = Planner.course(state, baseline.getString("id"));
        check(current.getString("name").equals("新名称") && current.getString("notes").equals("另一端备注"), "Independent display edits were lost");
        check(current.getInt("initialCompletedMinutes") == 20 && current.getInt("dailyStudyWeight") == 2, "Latest progress/rules were overwritten");
        check(current.getJSONArray("manualLessons").getJSONObject(1).getString("name").equals("更新后的第二节"), "Synced catalog was overwritten");
        check(history.equals(state.getJSONArray("completions").toString()) && tasks.equals(state.getJSONArray("tasks").toString()), "Confirmation evidence changed");
        check(!baseline.has("dailyStudyWeight") && draft.getString("notes").equals("原备注"), "Draft or baseline mutated");
        Planner.validate(state);
    }
    static void conflictingAndDeleted() throws Exception {
        JSONObject baseline = course(), state = state(baseline), draft = CourseTools.copy(baseline).put("deadline", Planner.at(DAY.plusDays(8), 0));
        Planner.course(state, baseline.getString("id")).put("priority", 3);
        rejected(state, () -> CourseEditing.save(state, draft, baseline, NOW), "Conflicting scheduling inputs accepted");
        JSONObject nameDraft = CourseTools.copy(baseline).put("name", "本地名");
        Planner.course(state, baseline.getString("id")).put("name", "远端名");
        rejected(state, () -> CourseEditing.save(state, nameDraft, baseline, NOW), "Conflicting names accepted");
        Planner.removeCourse(state, baseline.getString("id"));
        rejected(state, () -> CourseEditing.save(state, draft, baseline, NOW), "Deleted course resurrected");
        state.getJSONArray("courses").put(CourseTools.copy(baseline).put("isArchived", true));
        rejected(state, () -> CourseEditing.save(state, nameDraft, baseline, NOW), "Archived course resurrected");
        rejected(state, () -> CourseEditing.save(state, draft, null, NOW), "New course replaced an existing ID");
    }
    static void schedulingAndDeletion() throws Exception {
        JSONObject baseline = course(), state = state(baseline), draft = CourseTools.copy(baseline);
        Planner.course(state, baseline.getString("id")).put("color", "green");
        Planner.updateManualLessons(draft, new JSONArray().put(CourseTools.copy(draft.getJSONArray("manualLessons").getJSONObject(1))));
        CourseEditing.save(state, draft, baseline, NOW);
        JSONObject current = Planner.course(state, baseline.getString("id"));
        check(current.getInt("totalMinutes") == 120 && current.getString("color").equals("green"), "Deletion or independent color lost");
        check(CourseTools.deletedIDs(current).contains("a"), "Deletion marker lost");
        JSONObject staleRename = CourseTools.copy(baseline).put("name", "删除后改名");
        CourseEditing.save(state, staleRename, baseline, NOW);
        check(CourseTools.order(Planner.course(state, baseline.getString("id"))).equals(Collections.singletonList("b")), "Old rename restored deleted lesson");
    }
    static void defaultsAndIdenticalEdits() throws Exception {
        JSONObject baseline = course(), state = state(baseline), draft = CourseTools.copy(baseline);
        // The editor materializes an unchanged implicit order before saving.
        Planner.updateManualLessons(draft, CourseTools.copy(draft).getJSONArray("manualLessons"));
        draft.put("name", "新名"); Planner.course(state, baseline.getString("id")).put("priority", 3);
        CourseEditing.save(state, draft, baseline, NOW);
        check(Planner.course(state, baseline.getString("id")).getInt("priority") == 3, "Implicit order caused a false scheduling edit");
        baseline = CourseTools.copy(Planner.course(state, baseline.getString("id")));
        draft = CourseTools.copy(baseline).put("deadline", Planner.at(DAY.plusDays(9), 0));
        Planner.course(state, baseline.getString("id")).put("deadline", draft.get("deadline")).put("notes", "更新");
        CourseEditing.save(state, draft, baseline, NOW);
        check(Planner.course(state, baseline.getString("id")).getString("notes").equals("更新"), "Identical edit did not preserve notes");
    }
    static void manualEditorDeletionHistory() throws Exception {
        for (int actual : new int[]{0, 20, 60}) {
            JSONObject baseline = course(), state = state(baseline), edited = CourseTools.copy(baseline);
            CourseEditing.Draft session = new CourseEditing.Draft(state, baseline);
            Planner.updateManualLessons(edited, new JSONArray().put(CourseTools.copy(edited.getJSONArray("manualLessons").getJSONObject(1))));
            JSONObject task = Planner.task(baseline.getString("id"), NOW, 60).put("lessonID", "a");
            state.getJSONArray("tasks").put(task); Planner.confirm(state, task.getString("id"), actual, NOW + 1);
            rejected(state, () -> session.save(state, edited, NOW), "Manual form deleted a new " + actual + " minute confirmation");
            check(edited.getJSONArray("manualLessons").length() == 1, "Rejected deletion changed the form draft");
        }
        JSONObject baseline = course(), state = state(baseline), edited = CourseTools.copy(baseline);
        CourseEditing.Draft session = new CourseEditing.Draft(state, baseline);
        Planner.updateManualLessons(edited, new JSONArray().put(CourseTools.copy(edited.getJSONArray("manualLessons").getJSONObject(1))));
        JSONObject task = Planner.task(baseline.getString("id"), NOW, 60).put("lessonID", "b");
        state.getJSONArray("tasks").put(task); Planner.confirm(state, task.getString("id"), 20, NOW + 1);
        String records = state.getJSONArray("completions").toString();
        session.save(state, edited, NOW);
        check(Planner.course(state, baseline.getString("id")).getInt("totalMinutes") == 120 && records.equals(state.getJSONArray("completions").toString()), "Manual deletion lost unrelated completion");

        state = state(baseline);
        task = Planner.task(baseline.getString("id"), NOW, 60).put("lessonID", "a");
        state.getJSONArray("tasks").put(task); Planner.confirm(state, task.getString("id"), 20, NOW + 1);
        session = new CourseEditing.Draft(state, baseline);
        session.save(state, edited, NOW);
        check(state.getJSONArray("completions").length() == 0 && state.getJSONArray("tasks").length() == 0, "Reviewed history was not deleted atomically");
    }
    public static void main(String[] args) throws Exception {
        displayAndProgress(); conflictingAndDeleted(); schedulingAndDeletion(); defaultsAndIdenticalEdits(); manualEditorDeletionHistory();
        System.out.println("CourseEditingTests: " + checks + " checks passed");
    }
}
