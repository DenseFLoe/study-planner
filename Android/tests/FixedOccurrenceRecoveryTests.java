package local.studyplanner;

import org.json.*;
import java.io.IOException;
import java.time.LocalDate;
import java.util.*;

public final class FixedOccurrenceRecoveryTests {
    static final LocalDate DAY = LocalDate.of(2026, 11, 5), TOMORROW = DAY.plusDays(1);
    static final double NOW = Planner.at(DAY, 600);
    static int checks;
    interface Work { void run() throws Exception; }
    static void check(boolean condition, String message) { checks++; if (!condition) throw new AssertionError(message); }
    static String snapshot(JSONObject state) throws Exception { return SyncLedger.canonical(state); }
    static JSONObject event(JSONObject state, int index) throws Exception { return state.getJSONArray("fixedEvents").getJSONObject(index); }
    static JSONObject rule(String title, int start, int end) throws Exception {
        return new JSONObject().put("id", Planner.id()).put("title", title).put("startMinute", start).put("endMinute", end)
            .put("startDate", Planner.at(DAY.minusDays(2), 0)).put("endDate", Planner.at(TOMORROW, 0))
            .put("weekdays", new JSONArray("[1,2,3,4,5,6,7]")).put("excludedDates", new JSONArray())
            .put("notes", "").put("color", "orange");
    }
    static JSONObject fixture(boolean floating) throws Exception {
        JSONObject state = PlannerTests.empty(), target = rule("待恢复", 540, 660), blocker = rule("原占用", 570, 600);
        target.put("excludedDates", new JSONArray().put(Planner.at(DAY, 0)).put(Planner.at(TOMORROW, 0)));
        if (floating) target.put("floatingDurationMinutes", 100);
        state.getJSONArray("fixedEvents").put(target).put(blocker);
        JSONObject course = PlannerTests.course("课程", 120, DAY.minusDays(2), TOMORROW, 30);
        state.getJSONArray("courses").put(course);
        JSONObject history = Planner.task(course.getString("id"), Planner.at(DAY.minusDays(1), 480), 60);
        state.getJSONArray("tasks").put(history);
        Planner.confirm(state, history.getString("id"), 45, Planner.at(DAY.minusDays(1), 540));
        for (int weekday = 1; weekday <= 7; weekday++)
            state.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(weekday, 480, 840));
        return state;
    }
    static List<Planner.EventConflict> review(JSONObject state, JSONObject displayed) throws Exception {
        String before = snapshot(state), input = snapshot(displayed);
        try { FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, null); throw new AssertionError("Expected review"); }
        catch (FixedEventEditing.ReviewRequired issue) {
            check(snapshot(state).equals(before), "Opening review changed state");
            check(snapshot(displayed).equals(input), "Opening review changed displayed event");
            check(issue.conflicts.stream().allMatch(item -> DAY.equals(item.date)), "Review contains another date");
            return issue.conflicts;
        }
    }
    static void rejected(JSONObject state, Work work) throws Exception {
        String before = snapshot(state);
        try { work.run(); throw new AssertionError("Unsafe recovery succeeded"); }
        catch (IllegalArgumentException expected) { check(snapshot(state).equals(before), "Failed recovery partially changed state"); }
    }
    static void recoveryAndHistory() throws Exception {
        for (boolean floating : new boolean[]{false, true}) {
            JSONObject state = fixture(floating), displayed = CourseTools.copy(event(state, 0)), before = CourseTools.copy(state);
            List<Planner.EventConflict> reviewed = review(state, displayed);
            check(reviewed.size() == 1 && reviewed.get(0).reason.equals(floating ? "capacity" : "overlap"), "Wrong diagnosis");
            FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, reviewed);
            JSONObject expected = CourseTools.copy(before);
            event(expected, 0).put("excludedDates", new JSONArray().put(Planner.at(TOMORROW, 0)));
            event(expected, 1).put("excludedDates", new JSONArray().put(Planner.at(DAY, 0)));
            check(snapshot(state).equals(snapshot(expected)), "Recovery changed rules, other dates or history");
            check(snapshot(displayed).equals(snapshot(event(before, 0))), "Recovery mutated reviewed input");
            Planner.replan(state, NOW);
            check(snapshot(state.getJSONArray("completions").getJSONObject(0)).equals(snapshot(before.getJSONArray("completions").getJSONObject(0))), "Learning record changed");
            check(Planner.remaining(state, state.getJSONArray("courses").getJSONObject(0)) == 75, "Progress changed");
            String confirmed = snapshot(before.getJSONArray("tasks").getJSONObject(0));
            check(Planner.list(state.getJSONArray("tasks")).stream().anyMatch(item -> {
                try { return snapshot(item).equals(confirmed); } catch (Exception error) { throw new RuntimeException(error); }
            }), "Confirmed task lost");
            check(!PlannerTests.warned(state, "无法"), "Recovery still cannot schedule");
        }
    }
    static void allOccupantsAndFreshMetadata() throws Exception {
        JSONObject state = fixture(false), displayed = CourseTools.copy(event(state, 0));
        state.getJSONArray("fixedEvents").put(rule("第二条", 620, 640)).put(rule("无关事项", 780, 810));
        List<Planner.EventConflict> reviewed = review(state, displayed);
        check(reviewed.size() == 2, "Both occupants must be reviewed");
        event(state, 0).put("notes", "另一端新备注");
        event(state, 1).put("color", "blue").put("excludedDates", new JSONArray().put(Planner.at(TOMORROW, 0)));
        JSONObject expected = CourseTools.copy(state);
        event(expected, 0).put("excludedDates", new JSONArray().put(Planner.at(TOMORROW, 0)));
        event(expected, 1).put("excludedDates", new JSONArray().put(Planner.at(DAY, 0)).put(Planner.at(TOMORROW, 0)));
        event(expected, 2).put("excludedDates", new JSONArray().put(Planner.at(DAY, 0)));
        Collections.reverse(reviewed = new ArrayList<>(reviewed));
        FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, reviewed);
        check(snapshot(state).equals(snapshot(expected)), "Recovery lost fresh metadata, changed another day or missed an occupant");
    }
    static void changedReview() throws Exception {
        for (String change : new String[]{"title", "window", "duration", "identity", "added", "removed"}) {
            JSONObject state = fixture(false), displayed = CourseTools.copy(event(state, 0));
            state.getJSONArray("fixedEvents").put(rule("第二条", 620, 640));
            List<Planner.EventConflict> reviewed = review(state, displayed);
            if (change.equals("title")) event(state, 1).put("title", "改名");
            if (change.equals("window")) event(state, 1).put("startMinute", 575);
            if (change.equals("duration")) event(state, 1).put("floatingDurationMinutes", 20);
            if (change.equals("identity")) event(state, 1).put("id", Planner.id());
            if (change.equals("added")) state.getJSONArray("fixedEvents").put(rule("新占用", 605, 615));
            if (change.equals("removed")) state.getJSONArray("fixedEvents").remove(1);
            String before = snapshot(state);
            try { FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, reviewed); throw new AssertionError("Stale " + change + " review accepted"); }
            catch (FixedEventEditing.ReviewRequired updated) {
                check(snapshot(state).equals(before), "Changed review partially skipped occupants");
                check(!FixedEventEditing.signature(reviewed).equals(FixedEventEditing.signature(updated.conflicts)), "Review not refreshed");
                FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, updated.conflicts);
                check(Planner.occurs(event(state, 0), DAY), "Fresh consent did not restore");
            }
        }
    }
    static void disappearedAndAlreadyRestored() throws Exception {
        for (boolean peerRestored : new boolean[]{false, true}) {
            JSONObject state = fixture(true), displayed = CourseTools.copy(event(state, 0));
            List<Planner.EventConflict> reviewed = review(state, displayed);
            if (peerRestored) event(state, 0).put("excludedDates", new JSONArray().put(Planner.at(TOMORROW, 0)));
            else event(state, 1).put("startMinute", 780).put("endMinute", 810);
            String occupant = snapshot(event(state, 1));
            FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, reviewed);
            check(Planner.occurs(event(state, 0), DAY), "Did not restore resolved occurrence");
            check(snapshot(event(state, 1)).equals(occupant), "Replayed obsolete skip choice");
            String restored = snapshot(state);
            FixedEventEditing.restoreOccurrence(state, displayed, DAY, NOW, reviewed);
            check(snapshot(state).equals(restored), "Retry was not idempotent");
        }
    }
    static void invalidTargetAndConsent() throws Exception {
        for (String change : new String[]{"title", "window", "duration", "dates", "removed", "past", "missing", "empty", "wrongDay"}) {
            JSONObject state = fixture(true), displayed = CourseTools.copy(event(state, 0));
            List<Planner.EventConflict> reviewed = review(state, displayed);
            if (change.equals("title")) event(state, 0).put("title", "另一个事项");
            if (change.equals("window")) event(state, 0).put("endMinute", 670);
            if (change.equals("duration")) event(state, 0).put("floatingDurationMinutes", 110);
            if (change.equals("dates")) event(state, 0).put("startDate", Planner.at(TOMORROW, 0));
            if (change.equals("removed")) state.getJSONArray("fixedEvents").remove(0);
            if (change.equals("missing")) reviewed = null;
            if (change.equals("empty")) reviewed = Collections.emptyList();
            if (change.equals("wrongDay")) {
                Planner.EventConflict item = reviewed.get(0);
                reviewed = Collections.singletonList(new Planner.EventConflict(item.eventID, item.title, TOMORROW,
                    item.start, item.end, item.requestedStart, item.requestedEnd, item.floatingMinutes, item.reason));
            }
            final List<Planner.EventConflict> consent = reviewed;
            rejected(state, () -> FixedEventEditing.restoreOccurrence(state, displayed, DAY,
                change.equals("past") ? Planner.at(TOMORROW, 0) : NOW, consent));
        }
        List<Planner.EventConflict> active = Collections.singletonList(new Planner.EventConflict("task", "进行中", DAY, 540, 660, 540, 660, null, "active"));
        check(!FixedEventEditing.canRestoreSkipping(DAY, active), "Active tasks offered automatic skip");
        check(!FixedEventEditing.canRestoreSkipping(DAY, Collections.emptyList()), "Empty review offered replacement");
        JSONObject state = fixture(false);
        check(!FixedEventEditing.canRestoreSkipping(TOMORROW, review(state, event(state, 0))), "Wrong day offered replacement");
    }
    static final class Store implements StateMutation.Store<JSONObject> {
        JSONObject value; int saves; boolean failSave;
        Store(JSONObject value) throws Exception { this.value = CourseTools.copy(value); }
        public JSONObject load() throws Exception { return CourseTools.copy(value); }
        public void save(JSONObject next) throws Exception {
            if (failSave) throw new IOException("disk full");
            value = CourseTools.copy(next); saves++;
        }
    }
    static void transactionFailureAndRetry() throws Exception {
        Store store = new Store(fixture(false)); JSONObject displayed = CourseTools.copy(event(store.value, 0));
        List<Planner.EventConflict> reviewed = review(store.value, displayed);
        String before = snapshot(store.value); store.failSave = true;
        try {
            StateMutation.apply(store, next -> { FixedEventEditing.restoreOccurrence(next, displayed, DAY, NOW, reviewed); Planner.replan(next, NOW); });
            throw new AssertionError("Failed disk write succeeded");
        } catch (IOException expected) { check(snapshot(store.value).equals(before) && store.saves == 0, "Disk failure committed partial recovery"); }
        store.failSave = false;
        event(store.value, 1).put("title", "同步新名称");
        try {
            StateMutation.apply(store, next -> FixedEventEditing.restoreOccurrence(next, displayed, DAY, NOW, reviewed));
            throw new AssertionError("Transaction accepted stale review");
        } catch (FixedEventEditing.ReviewRequired updated) {
            check(store.saves == 0 && !Planner.occurs(event(store.value, 0), DAY) && Planner.occurs(event(store.value, 1), DAY), "Stale transaction wrote data");
            StateMutation.apply(store, next -> { FixedEventEditing.restoreOccurrence(next, displayed, DAY, NOW, updated.conflicts); Planner.replan(next, NOW); });
            check(store.saves == 1 && Planner.occurs(event(store.value, 0), DAY) && !Planner.occurs(event(store.value, 1), DAY), "Retry did not commit both changes together");
            check(event(store.value, 1).getString("title").equals("同步新名称"), "Retry overwrote synchronized metadata");
        }
    }
    public static void main(String[] args) throws Exception {
        recoveryAndHistory(); allOccupantsAndFreshMetadata(); changedReview(); disappearedAndAlreadyRestored();
        invalidTargetAndConsent(); transactionFailureAndRetry();
        System.out.println("FixedOccurrenceRecoveryTests: " + checks + " checks passed");
    }
}
