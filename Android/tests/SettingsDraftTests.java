package local.studyplanner;

import org.json.*;
import java.time.*;

public final class SettingsDraftTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 480);
    interface Action { void run() throws Exception; }
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject settings() throws Exception {
        return PlannerTests.empty().getJSONObject("settings").put("availability", new JSONArray()
            .put(PlannerTests.window(2, 480, 720)).put(PlannerTests.window(2, 840, 1080)).put(PlannerTests.window(1, 600, 900)));
    }
    static void rejected(JSONObject state, Action action, String message) throws Exception {
        String before = SyncLedger.canonical(state);
        try { action.run(); throw new AssertionError(message); }
        catch (IllegalArgumentException expected) { check(before.equals(SyncLedger.canonical(state)), "Failed setting save modified current state"); }
    }
    static void rawDraftRestoration() throws Exception {
        JSONObject settings = settings(); SettingsDraft draft = new SettingsDraft(settings);
        check(!draft.isDirty(), "New form starts dirty");
        check(draft.availability[0].equals("08:00-12:00, 14:00-18:00") && draft.availability[6].equals("10:00-15:00"), "Weekdays mapped incorrectly");
        draft.unit = ""; draft.availability[3] = "09:30-"; draft.levels.put("balancedLoad", 1);
        check(draft.isDirty(), "Partially typed input not retained");
        SettingsDraft restored = SettingsDraft.restore(new JSONObject(draft.snapshot().toString()));
        check(restored.unit.equals("") && restored.availability[3].equals("09:30-") && restored.isDirty(), "Rotation lost raw invalid input");
        check(restored.levels.getInt("balancedLoad") == 1, "Restoration lost priorities");
        check(!settings.has("schedulingRuleLevels"), "Draft leaked into saved settings");
        settings.put("dailyTaskOrder", new JSONArray().put("large runtime data stays out of the saved UI bundle"));
        check(!new SettingsDraft(settings).snapshot().getJSONObject("baseline").has("dailyTaskOrder"), "UI bundle copied unrelated runtime history");
        String raw = restored.snapshot().toString();
        try { restored.editedSettings(); throw new AssertionError("Invalid draft accepted"); }
        catch (IllegalArgumentException expected) { check(raw.equals(restored.snapshot().toString()), "Parsing failure changed draft"); }
    }
    static void independentEditsAndRuntime() throws Exception {
        JSONObject baseline = settings(), current = CourseTools.copy(baseline).put("notificationMinute", 1300)
            .put("actualStudyStart", NOW).put("dailyTaskOrder", new JSONArray().put("runtime-intent"));
        SettingsDraft draft = new SettingsDraft(baseline); draft.unit = "30";
        String before = SyncLedger.canonical(current);
        JSONObject merged = SettingsEditing.resolve(draft.editedSettings(), draft.baseline, current);
        check(merged.getInt("minimumScheduleUnit") == 30 && merged.getInt("notificationMinute") == 1300, "Independent edits failed to merge");
        check(merged.getDouble("actualStudyStart") == NOW && merged.getJSONArray("dailyTaskOrder").getString(0).equals("runtime-intent"), "Runtime settings overwritten");
        check(merged.getJSONArray("availability").toString().equals(current.getJSONArray("availability").toString()), "Unchanged window IDs replaced");
        check(before.equals(SyncLedger.canonical(current)), "Merge mutated latest settings");
        current.put("minimumScheduleUnit", 30);
        check(SettingsEditing.resolve(draft.editedSettings(), draft.baseline, current).getInt("minimumScheduleUnit") == 30, "Identical edit rejected");
    }
    static void staleConflicts() throws Exception {
        for (String key : new String[]{"minimumScheduleUnit", "notificationMinute", "availability", "schedulingRuleLevels"}) {
            JSONObject baseline = settings(), state = PlannerTests.empty(), current = CourseTools.copy(baseline);
            SettingsDraft draft = new SettingsDraft(baseline);
            if (key.equals("minimumScheduleUnit")) { draft.unit = "30"; current.put(key, 45); }
            if (key.equals("notificationMinute")) { draft.notification = "20:00"; current.put(key, 1230); }
            if (key.equals("availability")) { draft.availability[0] = "09:00-12:00"; current.getJSONArray("availability").getJSONObject(0).put("startMinute", 600); }
            if (key.equals("schedulingRuleLevels")) { draft.levels.put("diversity", 3); current.put(key, new SchedulePriorities(baseline).json().put("diversity", 2)); }
            state.put("settings", current);
            JSONObject edited = draft.editedSettings(); String input = draft.snapshot().toString();
            rejected(state, () -> SettingsEditing.save(state, edited, draft.baseline, NOW), "Concurrent " + key + " overwritten");
            check(input.equals(draft.snapshot().toString()), "Conflict lost raw draft");
        }
    }
    static void equivalentWindowsAndDayAnchor() throws Exception {
        JSONObject baseline = settings(), state = PlannerTests.empty(); state.put("settings", CourseTools.copy(baseline));
        SettingsDraft draft = new SettingsDraft(baseline);
        draft.availability[0] = " 14:00-18:00，08:00-12:00 ";
        draft.notification = "20:00";
        SettingsEditing.save(state, draft.editedSettings(), draft.baseline, NOW);
        check(!state.getJSONObject("settings").has("actualStudyStart"), "Formatting/reordering reset today's start");
        check(state.getJSONObject("settings").getJSONArray("availability").toString().equals(baseline.getJSONArray("availability").toString()), "Equivalent windows lost stable IDs");
        SettingsDraft changed = new SettingsDraft(state.getJSONObject("settings")); changed.availability[0] = "";
        state.getJSONObject("settings").put("actualStudyStart", NOW - 60);
        SettingsEditing.save(state, changed.editedSettings(), changed.baseline, NOW);
        check(state.getJSONObject("settings").getDouble("actualStudyStart") == NOW - 60, "Latest actual start overwritten");
        check(state.getJSONObject("settings").getJSONArray("availability").length() == 1, "Rest day did not remove Monday windows");
    }
    static void invalidInputIsAtomic() throws Exception {
        JSONObject baseline = settings(), state = PlannerTests.empty(); state.put("settings", CourseTools.copy(baseline));
        for (String raw : new String[]{"0", "1441", "-1", "1.5", "999999999999"}) {
            SettingsDraft draft = new SettingsDraft(baseline); draft.unit = raw;
            rejected(state, () -> SettingsEditing.save(state, draft.editedSettings(), draft.baseline, NOW), "Invalid unit accepted");
        }
        for (String raw : new String[]{"12:00-08:00", "09:00-09:00", "24:00-24:00", "09:00-", "09:00-10:00,"}) {
            SettingsDraft draft = new SettingsDraft(baseline); draft.availability[0] = raw;
            rejected(state, () -> SettingsEditing.save(state, draft.editedSettings(), draft.baseline, NOW), "Invalid windows accepted");
        }
        SettingsDraft draft = new SettingsDraft(baseline); draft.notification = "24:00";
        rejected(state, () -> SettingsEditing.save(state, draft.editedSettings(), draft.baseline, NOW), "Invalid confirmation time accepted");
        JSONObject edited = CourseTools.copy(baseline).put("minimumScheduleUnit", 30.5);
        rejected(state, () -> SettingsEditing.save(state, edited, baseline, NOW), "Fractional settings accepted");
    }
    public static void main(String[] args) throws Exception {
        rawDraftRestoration(); independentEditsAndRuntime(); staleConflicts(); equivalentWindowsAndDayAnchor(); invalidInputIsAtomic();
        System.out.println("SettingsDraftTests: " + checks + " checks passed");
    }
}
