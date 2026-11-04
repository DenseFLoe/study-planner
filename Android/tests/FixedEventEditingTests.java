package local.studyplanner;

import org.json.*;
import java.time.*;
import java.util.*;

public final class FixedEventEditingTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 480);
    interface Action { void run() throws Exception; }
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static void rejected(JSONObject state, Action action, String message) throws Exception {
        String before = SyncLedger.canonical(state);
        try { action.run(); throw new AssertionError(message); }
        catch (IllegalArgumentException expected) { check(before.equals(SyncLedger.canonical(state)), "Rejected save changed state"); }
    }
    static JSONObject event(String title, int start, int end) throws Exception {
        return new JSONObject().put("id", Planner.id()).put("title", title).put("startMinute", start).put("endMinute", end)
            .put("startDate", Planner.at(DAY, 0)).put("endDate", Planner.at(DAY.plusDays(7), 0))
            .put("weekdays", new JSONArray().put(1).put(2).put(3).put(4).put(5).put(6).put(7))
            .put("excludedDates", new JSONArray()).put("notes", "").put("color", "orange");
    }
    static void save(JSONObject state, JSONObject draft, JSONObject baseline) throws Exception {
        FixedEventEditing.save(state, draft, baseline, NOW, Collections.emptySet(), Collections.emptySet(), null);
    }
    static FixedEventEditing.ReviewRequired review(JSONObject state, JSONObject draft) throws Exception {
        try { save(state, draft, null); throw new AssertionError("Expected a conflict review"); }
        catch (FixedEventEditing.ReviewRequired required) { return required; }
    }
    static void metadataAndRuleConflicts() throws Exception {
        JSONObject baseline = event("原事项", 540, 600), state = PlannerTests.empty();
        JSONObject current = CourseTools.copy(baseline).put("startMinute", 600).put("endMinute", 660).put("notes", "同步备注");
        current.getJSONArray("excludedDates").put(Planner.at(DAY.plusDays(2), 0));
        state.getJSONArray("fixedEvents").put(current);
        JSONObject draft = CourseTools.copy(baseline).put("title", "新名称");
        save(state, draft, baseline);
        current = state.getJSONArray("fixedEvents").getJSONObject(0);
        check(current.getInt("startMinute") == 600 && current.getString("notes").equals("同步备注"), "Metadata edit replaced latest rule/notes");
        check(current.getString("title").equals("新名称") && current.getJSONArray("excludedDates").length() == 1, "Metadata merge lost title or exclusions");
        JSONObject timeDraft = CourseTools.copy(baseline).put("endMinute", 620);
        rejected(state, () -> save(state, timeDraft, baseline), "Conflicting rule accepted");
        JSONObject nameDraft = CourseTools.copy(baseline).put("title", "另一名称");
        rejected(state, () -> save(state, nameDraft, baseline), "Conflicting title accepted");
        state.put("fixedEvents", new JSONArray());
        rejected(state, () -> save(state, draft, baseline), "Deleted event resurrected");
        state.getJSONArray("fixedEvents").put(CourseTools.copy(baseline));
        rejected(state, () -> save(state, draft, null), "New event overwrote existing ID");
    }
    static void changedReview() throws Exception {
        for (String change : new String[]{"replace", "title", "window", "added", "removed"}) {
            JSONObject state = PlannerTests.empty(), local = event("原占用", 540, 600), draft = event("新事项", 550, 580);
            state.getJSONArray("fixedEvents").put(local);
            FixedEventEditing.ReviewRequired seen = review(state, draft);
            if (change.equals("replace")) local.put("id", Planner.id());
            if (change.equals("title")) local.put("title", "另一件事");
            if (change.equals("window")) local.put("endMinute", 610);
            if (change.equals("added")) state.getJSONArray("fixedEvents").put(event("新同步事项", 545, 590));
            if (change.equals("removed")) state.put("fixedEvents", new JSONArray());
            Set<LocalDate> days = new HashSet<>(); for (Planner.EventConflict c : seen.conflicts) days.add(c.date);
            rejected(state, () -> FixedEventEditing.save(state, draft, null, NOW, Collections.emptySet(), days, seen.conflicts), "Unseen " + change + " conflict accepted");
            check(draft.getJSONArray("excludedDates").length() == 0, "Failed save changed the input draft");
        }
    }
    static void reviewedChoicesAndIsolation() throws Exception {
        JSONObject state = PlannerTests.empty(), local = event("保留历史的本地事项", 540, 600), draft = event("新事项", 550, 580);
        state.getJSONArray("fixedEvents").put(local);
        FixedEventEditing.ReviewRequired seen = review(state, draft);
        Set<LocalDate> days = new HashSet<>(); for (Planner.EventConflict c : seen.conflicts) days.add(c.date);
        rejected(state, () -> FixedEventEditing.save(state, draft, null, NOW, Collections.emptySet(), days, null), "Skipping without review accepted");
        JSONObject skipNew = CourseTools.copy(state);
        FixedEventEditing.save(skipNew, draft, null, NOW, days, Collections.emptySet(), seen.conflicts);
        check(Planner.occurs(skipNew.getJSONArray("fixedEvents").getJSONObject(0), DAY), "Skipping new event cancelled the local event");
        check(!Planner.occurs(skipNew.getJSONArray("fixedEvents").getJSONObject(1), DAY), "New event was not skipped");
        FixedEventEditing.save(state, draft, null, NOW, Collections.emptySet(), days, seen.conflicts);
        check(!Planner.occurs(state.getJSONArray("fixedEvents").getJSONObject(0), DAY), "Reviewed local event not skipped");
        check(Planner.occurs(state.getJSONArray("fixedEvents").getJSONObject(1), DAY), "New event not saved");
        check(draft.getJSONArray("excludedDates").length() == 0 && local.getJSONArray("excludedDates").length() == 0, "Caller references were mutated");
    }
    static void splitRetryAndEquivalentRules() throws Exception {
        JSONObject baseline = event("有历史的事项", 540, 600).put("startDate", Planner.at(DAY.minusDays(7), 0));
        JSONObject state = PlannerTests.empty(); state.getJSONArray("fixedEvents").put(CourseTools.copy(baseline));
        JSONObject draft = CourseTools.copy(baseline).put("title", "改名");
        String input = SyncLedger.canonical(draft);
        // A surrounding persistence failure discards this state, then retries the same intent.
        JSONObject abandoned = CourseTools.copy(state); save(abandoned, draft, baseline);
        check(input.equals(SyncLedger.canonical(draft)), "Historical split changed draft ID/date before commit");
        save(state, draft, baseline);
        check(state.getJSONArray("fixedEvents").length() == 2, "Retry did not retain history and one future rule");
        check(state.getJSONArray("fixedEvents").getJSONObject(0).getDouble("endDate") == Planner.at(DAY.minusDays(1), 0), "History boundary incorrect");
        JSONObject simple = event("顺序无关", 540, 600), reordered = CourseTools.copy(simple);
        reordered.put("weekdays", new JSONArray().put(7).put(6).put(5).put(4).put(3).put(2).put(1));
        check(FixedEventEditing.schedulingInputs(simple).equals(FixedEventEditing.schedulingInputs(reordered)), "Weekday set order caused a false conflict");
    }
    public static void main(String[] args) throws Exception {
        metadataAndRuleConflicts(); changedReview(); reviewedChoicesAndIsolation(); splitRetryAndEquivalentRules();
        System.out.println("FixedEventEditingTests: " + checks + " checks passed");
    }
}
