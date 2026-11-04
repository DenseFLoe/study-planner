package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.LocalDate;
import java.util.*;
import java.util.stream.Stream;

public final class CourseImportReceiptTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 480);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static final class Store implements StateMutation.Store<JSONObject> {
        JSONObject value; boolean fail; int saves;
        Store() throws Exception { value = PlannerTests.empty(); }
        public JSONObject load() throws Exception { return CourseTools.copy(value); }
        public void save(JSONObject next) throws Exception { saves++; if (fail) throw new IOException("Synthetic disk failure"); value = CourseTools.copy(next); }
    }
    static JSONObject payload() throws Exception {
        return new JSONObject().put("snapshots", new JSONArray().put(LessonDeletionTests.snapshot(NOW, "a", "b"))).put("deadline", Planner.at(DAY.plusDays(7), 0));
    }
    static Path write(Path directory, String contents) throws Exception {
        Path path = directory.resolve("course-import-" + UUID.randomUUID() + ".json"); Files.write(path, contents.getBytes(StandardCharsets.UTF_8)); return path;
    }
    static void successfulRetry(Path directory) throws Exception {
        Store store = new Store(); Path path = write(directory, payload().toString());
        CourseImportReceipt receipt = new CourseImportReceipt(directory.toFile(), path.toString());
        String before = SyncLedger.canonical(store.value); store.fail = true;
        try { receipt.commit(store, () -> NOW); throw new AssertionError("Failed save was accepted"); }
        catch (IOException expected) { check(before.equals(SyncLedger.canonical(store.value)) && receipt.exists(), "Failed save deleted capture or changed stored data"); }
        check(CourseImportReceipt.pending(directory.toFile()).size() == 1, "Failed import cannot be discovered for retry");
        JSONObject other = PlannerTests.course("重试前的新课程", 60, DAY, DAY.plusDays(3), 60); store.value.getJSONArray("courses").put(other);
        store.fail = false; CourseImportReceipt.Result result = receipt.commit(store, () -> { check(Thread.holdsLock(store), "Import clock read before database transaction"); return NOW + 60; });
        check(result.removed && !Files.exists(path) && CourseImportReceipt.pending(directory.toFile()).isEmpty(), "Successful save left a consumed receipt");
        check(store.value.getJSONArray("courses").length() == 2 && Planner.course(store.value, other.getString("id")) != null, "Retry overwrote newer state");
        check(result.state.getJSONArray("courses").length() == 2, "UI result omitted saved import");
        try { receipt.commit(store, () -> NOW); throw new AssertionError("Consumed receipt was imported twice"); }
        catch (IOException expected) { check(store.saves == 2, "Consumed receipt reached database save"); }
    }
    static void invalidPayloads(Path directory) throws Exception {
        for (String content : new String[]{"{", payload().toString() + " trailing", new JSONObject().put("snapshots", new JSONArray()).put("deadline", NOW).toString(),
                new JSONObject().put("snapshots", new JSONArray().put(new JSONObject())).put("deadline", NOW).toString()}) {
            Store store = new Store(); Path file = write(directory, content); String before = SyncLedger.canonical(store.value);
            try { new CourseImportReceipt(directory.toFile(), file.toString()).commit(store, () -> NOW); throw new AssertionError("Invalid payload imported"); }
            catch (Exception expected) { check(store.saves == 0 && before.equals(SyncLedger.canonical(store.value)) && Files.exists(file), "Rejected import consumed file or persisted partial data"); }
            Files.delete(file);
        }
        for (boolean oversized : new boolean[]{false, true}) {
            Store store = new Store(); Path file = write(directory, "");
            if (oversized) try (RandomAccessFile output = new RandomAccessFile(file.toFile(), "rw")) { output.setLength(CourseImportReceipt.MAX_BYTES + 1); }
            else Files.write(file, new byte[]{(byte) 0xc3, (byte) 0x28});
            try { new CourseImportReceipt(directory.toFile(), file.toString()).commit(store, () -> NOW); throw new AssertionError("Invalid bytes accepted"); }
            catch (IOException expected) { check(Files.exists(file) && store.saves == 0, "Invalid byte file changed database or was deleted"); }
            Files.delete(file);
        }
    }
    static void pathScope(Path directory) throws Exception {
        Path unrelated = directory.resolve("private.json"); Files.write(unrelated, new byte[]{1});
        check(CourseImportReceipt.pending(directory.toFile()).isEmpty(), "Unrelated private file appeared as pending import");
        for (String path : new String[]{unrelated.toString(), directory.resolve("../course-import-abcd.json").toString()}) {
            try { new CourseImportReceipt(directory.toFile(), path); throw new AssertionError("Out-of-scope import path accepted"); }
            catch (IOException expected) { checks++; }
        }
        Files.delete(unrelated);
    }
    static void atomicStaging(Path directory) throws Exception {
        JSONObject capture = LessonDeletionTests.snapshot(NOW, "a", "b").put("accessToken", "synthetic-private-field");
        capture.put("name", "中文课程 😀"); String original = capture.toString();
        File file = CourseImportReceipt.stage(directory.toFile(), Collections.singletonList(capture), Planner.at(DAY.plusDays(7), 0));
        String saved = new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
        check(saved.contains("中文课程 😀") && !saved.contains("synthetic-private-field"), "Staging changed Unicode or retained unapproved capture fields");
        check(original.equals(capture.toString()), "Staging mutated selected capture");
        check(CourseImportReceipt.pending(directory.toFile()).size() == 1, "Complete staged file not available for import");
        byte[] before = Files.readAllBytes(file.toPath());
        try { CourseImportReceipt.stage(directory.toFile(), Collections.singletonList(capture), NOW, 32); throw new AssertionError("Oversized output accepted"); }
        catch (IOException expected) { check(Arrays.equals(before, Files.readAllBytes(file.toPath())), "Failed stage overwrote a completed capture"); }
        try (Stream<Path> files = Files.list(directory)) { check(files.count() == 1, "Failed stage leaked a partial import or temporary file"); }
        try { CourseImportReceipt.stage(directory.toFile(), Collections.emptyList(), NOW); throw new AssertionError("Empty capture staged"); }
        catch (IllegalArgumentException expected) { check(CourseImportReceipt.pending(directory.toFile()).size() == 1, "Empty capture produced a pending file"); }
        Store store = new Store(); CourseImportReceipt.Result imported = new CourseImportReceipt(directory.toFile(), file.getAbsolutePath()).commit(store, () -> NOW);
        check(imported.removed && store.value.getJSONArray("courses").getJSONObject(0).getString("name").equals("中文课程 😀"), "Staged capture did not round-trip into planner");
    }
    static void staleRetry(Path directory) throws Exception {
        JSONObject original = payload(), fresh = CourseTools.copy(original.getJSONArray("snapshots").getJSONObject(0)).put("fetchedAt", NOW + 60);
        fresh.getJSONArray("lessons").getJSONObject(0).put("watchedPercent", 50);
        Store store = new Store();
        WebCourseImport.save(store.value, Collections.singletonList(fresh), original.getDouble("deadline"), NOW + 60);
        Path file = write(directory, original.toString()); String before = SyncLedger.canonical(store.value);
        try { new CourseImportReceipt(directory.toFile(), file.toString()).commit(store, () -> NOW + 120); throw new AssertionError("Stale retry replaced newer course"); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains("较新的抓取结果"), "Stale retry did not explain freshness conflict");
            check(store.saves == 0 && SyncLedger.canonical(store.value).equals(before), "Stale retry changed durable planner");
            check(Files.exists(file), "Stale retry consumed the file needed for review");
        }
        Files.delete(file);
    }
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("study-import-receipt-");
        try { successfulRetry(directory); invalidPayloads(directory); pathScope(directory); atomicStaging(directory); staleRetry(directory); }
        finally { try (Stream<Path> files = Files.walk(directory)) { for (Path path : (Iterable<Path>)files.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(path); } }
        System.out.println("CourseImportReceiptTests: " + checks + " checks passed");
    }
}
