package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

public final class SettingsNumberIntegrityTests {
    static int checks;
    interface Action { void run() throws Exception; }
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static void rejects(Action action) throws Exception {
        try { action.run(); throw new AssertionError("Malformed numeric field accepted"); }
        catch (IllegalArgumentException | JSONException expected) { checks++; }
    }
    static JSONObject fixture() throws Exception {
        JSONObject state = PlannerTests.empty(), settings = state.getJSONObject("settings");
        settings.getJSONArray("availability").put(new JSONObject().put("id", Planner.id()).put("weekday", 1).put("startMinute", 480).put("endMinute", 1380));
        settings.put("schedulingRuleLevels", new SchedulePriorities(settings).json());
        return state;
    }
    static JSONObject owner(JSONObject settings, String key) throws Exception {
        if (key.equals("weekday") || key.equals("startMinute") || key.equals("endMinute")) return settings.getJSONArray("availability").getJSONObject(0);
        if (key.equals("balancedLoad")) return settings.getJSONObject("schedulingRuleLevels");
        return settings;
    }
    static void malformedSettings() throws Exception {
        for (String key : new String[]{"minimumScheduleUnit", "notificationMinute", "weekday", "startMinute", "endMinute", "balancedLoad"}) {
            for (Object invalid : new Object[]{"1", true, 1.5, 4294967297L, new BigDecimal("1.0000000000000000001"), JSONObject.NULL}) {
                JSONObject valid = fixture(), damaged = CourseTools.copy(valid), settings = damaged.getJSONObject("settings");
                owner(settings, key).put(key, invalid);
                String before = SyncLedger.canonical(damaged);
                rejects(() -> Planner.validate(damaged));
                check(before.equals(SyncLedger.canonical(damaged)), "Validation modified malformed state");
                rejects(() -> PlannerBackupFile.read(new ByteArrayInputStream(damaged.toString().getBytes(StandardCharsets.UTF_8))));
                SyncLedger ledger = new SyncLedger(); ledger.capture(valid);
                ledger.records().getJSONObject("settings/settings").put("payload", Base64.getEncoder().encodeToString(settings.toString().getBytes(StandardCharsets.UTF_8)));
                String ledgerBefore = SyncLedger.canonical(ledger.value);
                rejects(ledger::materialize);
                check(ledgerBefore.equals(SyncLedger.canonical(ledger.value)), "Rejected settings modified ledger");
            }
        }
    }
    static void schemaAndValidNumbers() throws Exception {
        for (Object invalid : new Object[]{"1", true, 1.5, 4294967297L, new BigDecimal("1.0000000000000000001"), JSONObject.NULL, 2}) {
            JSONObject state = fixture().put("schemaVersion", invalid);
            rejects(() -> Planner.validate(state));
            rejects(() -> PlannerBackupFile.readLegacyState(new ByteArrayInputStream(state.toString().getBytes(StandardCharsets.UTF_8))));
        }
        for (Object version : new Object[]{1, 1L, 1.0, new BigDecimal("1e0")}) {
            JSONObject state = fixture().put("schemaVersion", version), settings = state.getJSONObject("settings");
            settings.put("minimumScheduleUnit", new BigDecimal("6e1")).put("notificationMinute", 1260.0);
            owner(settings, "weekday").put("weekday", 1.0).put("startMinute", 480L).put("endMinute", new BigDecimal("1.38e3"));
            owner(settings, "balancedLoad").put("balancedLoad", 4.0);
            Planner.validate(state); SyncLedger ledger = new SyncLedger(); ledger.capture(state);
            check(ledger.materialize().getJSONObject("settings").getInt("minimumScheduleUnit") == 60, "Exact integer-valued JSON number rejected");
        }
        JSONObject legacy = fixture(); legacy.getJSONObject("settings").remove("schedulingRuleLevels"); Planner.validate(legacy);
        legacy.getJSONObject("settings").put("schedulingRuleLevels", JSONObject.NULL); Planner.validate(legacy);
        checks += 2;
    }
    public static void main(String[] args) throws Exception {
        malformedSettings(); schemaAndValidNumbers();
        System.out.println("SettingsNumberIntegrityTests: " + checks + " checks passed");
    }
}
