package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.LocalDate;

public final class PlannerBackupFileTests {
    static int checks;
    static final double NOW = Planner.at(LocalDate.of(2026, 11, 4), 480);
    interface Action { void run() throws Exception; }
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static void rejected(Action action) throws Exception {
        try { action.run(); throw new AssertionError("Invalid backup accepted"); } catch (IllegalArgumentException | IOException | JSONException expected) { checks++; }
    }
    static JSONObject fixture() throws Exception {
        JSONObject course = CourseEditingTests.course(), state = PlannerTests.empty();
        course.put("notes", "备份互读 中文"); state.getJSONArray("courses").put(course);
        JSONObject task = Planner.task(course.getString("id"), NOW, 60).put("lessonID", "a").put("lessonName", "第一节");
        state.getJSONArray("tasks").put(task); Planner.confirm(state, task.getString("id"), 20, NOW);
        state.put("androidWarnings", new JSONArray().put("仅本机诊断"));
        return state;
    }
    static PlannerBackupFile read(String value) throws Exception { return PlannerBackupFile.read(new ByteArrayInputStream(value.getBytes(StandardCharsets.UTF_8))); }
    static String encoded(PlannerBackupFile backup) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream(); backup.write(output); return output.toString("UTF-8");
    }
    static void formatsAndIsolation() throws Exception {
        JSONObject original = fixture(); String before = SyncLedger.canonical(original);
        PlannerBackupFile backup = PlannerBackupFile.create(original, NOW), reopened = read(encoded(backup));
        JSONObject result = reopened.state();
        check(!reopened.legacy && !result.has("androidWarnings"), "Export retained local diagnostics or lost wrapper");
        check(result.getJSONArray("completions").getJSONObject(0).getInt("minutes") == 20, "Export lost progress");
        check(reopened.summary().contains("2026-11-04") && reopened.summary().contains("1 条学习记录"), "Preview summary is incomplete");
        PlannerBackupFile legacy = read(original.toString());
        check(legacy.legacy && SyncLedger.canonical(legacy.state()).equals(SyncLedger.canonical(result)), "Legacy file compatibility changed");
        check(before.equals(SyncLedger.canonical(original)), "Creating backup mutated source");
        result.getJSONArray("courses").getJSONObject(0).put("name", "外部修改");
        check(!reopened.state().getJSONArray("courses").getJSONObject(0).getString("name").equals("外部修改"), "Caller modified saved backup");
        original.getJSONArray("courses").getJSONObject(0).put("name", "导出后修改");
        check(!backup.state().getJSONArray("courses").getJSONObject(0).getString("name").equals("导出后修改"), "Export references live data");
    }
    static void invalidFiles() throws Exception {
        String good = encoded(PlannerBackupFile.create(fixture(), NOW));
        for (Object version : new Object[]{2, 1.5, "1"}) rejected(() -> read(new JSONObject(good).put("format", version).toString()));
        rejected(() -> read(new JSONObject(good).put("id", "invalid").toString()));
        rejected(() -> read(new JSONObject(good).put("createdAt", "today").toString()));
        rejected(() -> read(new JSONObject(good).put("reason", 123).toString()));
        rejected(() -> read(good + " trailing")); rejected(() -> read(good.substring(0, good.length() - 1)));
        rejected(() -> read("[]")); rejected(() -> read("{}"));
        rejected(() -> PlannerBackupFile.read(new ByteArrayInputStream(good.getBytes(StandardCharsets.UTF_8)), 100));
        rejected(() -> PlannerBackupFile.read(new ByteArrayInputStream(new byte[]{(byte)0xc3, (byte)0x28})));
        StringBuilder deep = new StringBuilder(); for (int i = 0; i < 65; i++) deep.append('[');
        rejected(() -> read(deep.toString()));
        JSONObject malformed = new JSONObject(good); malformed.getJSONObject("state").getJSONArray("tasks").getJSONObject(0).put("durationMinutes", -1);
        rejected(() -> read(malformed.toString()));
        class Closed extends ByteArrayInputStream { boolean closed; Closed() { super(good.getBytes(StandardCharsets.UTF_8)); } public void close() { closed = true; } }
        Closed stream = new Closed(); rejected(() -> PlannerBackupFile.read(stream, 100)); check(stream.closed, "Invalid input stream not closed");
    }
    static void restoreReview() throws Exception {
        JSONObject current = fixture(), target = fixture(); target.getJSONArray("courses").getJSONObject(0).put("name", "恢复后的课程");
        PlannerBackupFile file = PlannerBackupFile.create(target, NOW);
        PlannerBackupFile.Restore review = new PlannerBackupFile.Restore(file, current);
        current.getJSONArray("courses").getJSONObject(0).put("notes", "核对期间的新备注");
        String changed = SyncLedger.canonical(current);
        rejected(() -> review.apply(current)); check(changed.equals(SyncLedger.canonical(current)), "Failed restore changed current data");
        SyncLedger ledger = new SyncLedger(); ledger.capture(current);
        PlannerBackupFile.Restore fresh = new PlannerBackupFile.Restore(file, current);
        current.put("androidWarnings", new JSONArray().put("新的诊断"));
        fresh.apply(current);
        check(current.getJSONArray("courses").getJSONObject(0).getString("name").equals("恢复后的课程"), "Reviewed restore not applied");
        check(current.getJSONArray("completions").length() == 1 && !current.has("androidWarnings"), "Restore lost history or retained stale diagnostics");
        ledger.capture(current); JSONObject reopened = ledger.materialize();
        check(SyncLedger.canonical(PlannerBackupFile.businessState(reopened)).equals(SyncLedger.canonical(current)), "Restore did not survive ledger persistence");
        current.getJSONArray("courses").getJSONObject(0).put("name", "之后的更改");
        check(file.state().getJSONArray("courses").getJSONObject(0).getString("name").equals("恢复后的课程"), "Restore aliased backup state");
    }
    static void legacyStartupIntegrity() throws Exception {
        JSONObject original = fixture();
        original.put("futureLocalMetadata", new JSONObject().put("note", "保留字段"));
        String json = original.toString(); byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        JSONObject loaded = PlannerBackupFile.readLegacyState(new ByteArrayInputStream(bytes), bytes.length);
        check(SyncLedger.canonical(loaded).equals(SyncLedger.canonical(original)), "Startup discarded legacy fields or progress");
        rejected(() -> PlannerBackupFile.readLegacyState(new ByteArrayInputStream(bytes), bytes.length - 1));
        rejected(() -> PlannerBackupFile.readLegacyState(new ByteArrayInputStream((json + " {}").getBytes(StandardCharsets.UTF_8))));
        byte[] damaged = json.replace("保留字段", "BAD").getBytes(StandardCharsets.UTF_8);
        for (int i = 0; i + 2 < damaged.length; i++) if (damaged[i] == 'B' && damaged[i + 1] == 'A' && damaged[i + 2] == 'D') { damaged[i] = (byte)0xff; break; }
        rejected(() -> PlannerBackupFile.readLegacyState(new ByteArrayInputStream(damaged)));
        rejected(() -> PlannerBackupFile.readLegacyState(new ByteArrayInputStream(encoded(PlannerBackupFile.create(original, NOW)).getBytes(StandardCharsets.UTF_8))));
        JSONObject old = fixture(); old.getJSONObject("settings").getJSONArray("availability").put(new JSONObject()
            .put("id", "default-availability-1").put("weekday", 1).put("startMinute", 480).put("endMinute", 1380));
        loaded = PlannerBackupFile.readLegacyState(new ByteArrayInputStream(old.toString().getBytes(StandardCharsets.UTF_8)));
        check(Planner.canonicalID(loaded.getJSONObject("settings").getJSONArray("availability").getJSONObject(0).getString("id")), "Existing availability migration was skipped");
        class Closed extends ByteArrayInputStream { boolean closed; Closed(byte[] value) { super(value); } public void close() { closed = true; } }
        Closed success = new Closed(bytes); PlannerBackupFile.readLegacyState(success); check(success.closed, "Startup stream not closed");
        Closed failure = new Closed(damaged); rejected(() -> PlannerBackupFile.readLegacyState(failure)); check(failure.closed, "Failed startup stream not closed");
    }
    static void wireFixtures() throws Exception {
        String directory = System.getenv("STUDY_CLOUD_FIXTURE_DIR"); if (directory == null) return;
        Path folder = Paths.get(directory);
        PlannerBackupFile swift = PlannerBackupFile.read(Files.newInputStream(folder.resolve("swift-file-backup.json")));
        check(!swift.legacy && swift.state().getJSONArray("courses").length() == 1, "Swift file backup unreadable");
        PlannerBackupFile.create(fixture(), NOW).write(Files.newOutputStream(folder.resolve("android-file-backup.json")));
    }
    public static void main(String[] args) throws Exception {
        formatsAndIsolation(); invalidFiles(); restoreReview(); legacyStartupIntegrity(); wireFixtures();
        System.out.println("PlannerBackupFileTests: " + checks + " checks passed");
    }
}
