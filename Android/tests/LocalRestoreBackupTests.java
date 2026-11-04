package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Stream;

public final class LocalRestoreBackupTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    interface Action { void run() throws Exception; }
    static void rejected(JSONObject state, Action action) throws Exception {
        String before = SyncLedger.canonical(state);
        try { action.run(); throw new AssertionError("Invalid restore accepted"); }
        catch (IllegalArgumentException | java.io.IOException expected) { check(before.equals(SyncLedger.canonical(state)), "Failed backup write changed current planner"); }
    }
    static JSONObject state(String name) throws Exception {
        JSONObject value = PlannerBackupFileTests.fixture(); value.getJSONArray("courses").getJSONObject(0).put("name", name); return value;
    }
    static String name(JSONObject value) throws Exception { return value.getJSONArray("courses").getJSONObject(0).getString("name"); }
    static void roundTripAndUndo(Path directory) throws Exception {
        Path path = directory.resolve("recovery.json"); LocalRestoreBackup store = new LocalRestoreBackup(path.toFile());
        JSONObject current = state("恢复之前"), target = state("文件里的课程");
        PlannerBackupFile file = PlannerBackupFile.create(target, PlannerBackupFileTests.NOW);
        store.restore(current, new PlannerBackupFile.Restore(file, current), PlannerBackupFileTests.NOW);
        check(name(current).equals("文件里的课程"), "Reviewed file was not restored");
        LocalRestoreBackup reopened = new LocalRestoreBackup(path.toFile());
        PlannerBackupFile recovery = reopened.load();
        check(name(recovery.state()).equals("恢复之前") && recovery.state().getJSONArray("completions").length() == 1, "Recovery point lost original history");
        reopened.restore(current, new PlannerBackupFile.Restore(recovery, current), PlannerBackupFileTests.NOW + 1);
        check(name(current).equals("恢复之前"), "Undo restore did not recover original planner");
        check(name(reopened.load().state()).equals("文件里的课程"), "Restoring recovery point did not preserve current data first");
        try (Stream<Path> files = Files.list(directory)) { check(files.count() == 1, "Recovery files grew or temporary file leaked"); }
        if (Files.getFileStore(path).supportsFileAttributeView("posix")) {
            Set<java.nio.file.attribute.PosixFilePermission> permissions = Files.getPosixFilePermissions(path);
            check(!permissions.contains(java.nio.file.attribute.PosixFilePermission.GROUP_READ) && !permissions.contains(java.nio.file.attribute.PosixFilePermission.OTHERS_READ), "Recovery file is readable by others");
        }
    }
    static void failures(Path directory) throws Exception {
        Path path = directory.resolve("recovery.json"); LocalRestoreBackup store = new LocalRestoreBackup(path.toFile());
        JSONObject current = state("本机"); PlannerBackupFile file = PlannerBackupFile.create(state("备份"), PlannerBackupFileTests.NOW);
        byte[] saved = Files.readAllBytes(path);
        PlannerBackupFile.Restore stale = new PlannerBackupFile.Restore(file, current);
        current.getJSONArray("courses").getJSONObject(0).put("notes", "新的同步备注");
        rejected(current, () -> store.restore(current, stale, PlannerBackupFileTests.NOW));
        check(Arrays.equals(saved, Files.readAllBytes(path)), "Stale restore replaced the existing recovery file");
        Path blocker = directory.resolve("not-a-directory"); Files.write(blocker, new byte[]{1});
        LocalRestoreBackup blocked = new LocalRestoreBackup(blocker.resolve("recovery.json").toFile());
        PlannerBackupFile.Restore reviewed = new PlannerBackupFile.Restore(file, current);
        rejected(current, () -> blocked.restore(current, reviewed, PlannerBackupFileTests.NOW));
        check(Arrays.equals(saved, Files.readAllBytes(path)), "Failed write changed previous recovery point");
        Files.delete(blocker);
        Path invalid = directory.resolve("bad.json"); Files.write(invalid, new byte[]{'{'});
        try { new LocalRestoreBackup(invalid.toFile()).load(); throw new AssertionError("Corrupt recovery accepted"); }
        catch (JSONException expected) { check(Files.size(invalid) == 1, "Corrupt recovery was deleted"); }
        Files.delete(invalid);
        try { new LocalRestoreBackup(directory.resolve("missing.json").toFile()).load(); throw new AssertionError("Missing recovery accepted"); }
        catch (java.io.IOException expected) { checks++; }
    }
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("study-restore-backup-");
        try { roundTripAndUndo(directory); failures(directory); }
        finally { try (Stream<Path> files = Files.walk(directory)) { for (Path path : (Iterable<Path>)files.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(path); } }
        System.out.println("LocalRestoreBackupTests: " + checks + " checks passed");
    }
}
