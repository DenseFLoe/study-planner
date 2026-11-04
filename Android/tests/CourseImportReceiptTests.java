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
    static void reviewedImports(Path directory) throws Exception {
        JSONObject payload = payload(); JSONArray snapshots = new JSONArray();
        JSONObject capture = payload.getJSONArray("snapshots").getJSONObject(0);
        for (int i = 0; i < 205; i++) snapshots.put(CourseTools.copy(capture).put("packageID", "preview-" + i).put("name", "待核对课程 " + i));
        payload.put("snapshots", snapshots);
        Path file = write(directory, payload.toString()); byte[] original = Files.readAllBytes(file);
        CourseImportReceipt receipt = new CourseImportReceipt(directory.toFile(), file.toString());
        CourseImportReceipt.Preview preview = receipt.preview();
        check(preview.count() == 205 && preview.pageCount() == 3, "Preview lost courses or pagination");
        check(preview.page(0).size() == 100 && preview.page(1).size() == 100 && preview.page(2).size() == 5, "Preview exceeds page size or truncates courses");
        check(preview.page(-1).isEmpty() && preview.page(3).isEmpty(), "Preview accepts invalid page");
        check(preview.page(2).get(4).contains("待核对课程 204") && preview.page(0).get(0).contains("抓取时间 2026-11-04 08:00"), "Preview lacks names or capture time");
        check(preview.deadline.equals("2026-11-11") && preview.totalMinutes == 205L * WebCourseImport.total(capture), "Preview lost deadline or total workload");
        check(Arrays.equals(Files.readAllBytes(file), original), "Preview modified its pending file");
        try { preview.page(0).clear(); throw new AssertionError("Preview rows are mutable"); }
        catch (UnsupportedOperationException expected) { checks++; }
        byte[] fingerprint = preview.fingerprint(); fingerprint[0] ^= 1;
        check(!Arrays.equals(fingerprint, preview.fingerprint()), "Preview exposed its mutable fingerprint");
        payload.put("deadline", Planner.at(DAY.plusDays(8), 0)); Files.write(file, payload.toString().getBytes(StandardCharsets.UTF_8));
        Store store = new Store();
        try { receipt.commit(store, () -> NOW, preview.fingerprint()); throw new AssertionError("Unreviewed file contents imported"); }
        catch (IOException expected) { check(store.saves == 0 && Files.exists(file) && expected.getMessage().contains("核对后发生变化"), "Changed file was saved or consumed"); }
        Files.delete(file);
        file = write(directory, payload().toString()); receipt = new CourseImportReceipt(directory.toFile(), file.toString()); preview = receipt.preview();
        CourseImportReceipt.Result result = receipt.commit(store, () -> NOW, preview.fingerprint());
        check(result.removed && store.value.getJSONArray("courses").length() == 1, "Reviewed unchanged import did not save and consume file");
    }
    static void reviewedDiscard(Path directory) throws Exception {
        Path target = write(directory, payload().toString()), other = write(directory, payload().toString());
        CourseImportReceipt receipt = new CourseImportReceipt(directory.toFile(), target.toString());
        CourseImportReceipt.Preview preview = receipt.preview();
        for (byte[] fingerprint : new byte[][]{null, new byte[0], new byte[31], new byte[32]}) {
            try { receipt.discard(fingerprint); throw new AssertionError("Unreviewed file discarded"); }
            catch (IOException expected) { check(Files.exists(target) && Files.exists(other), "Invalid discard removed a file"); }
        }
        byte[] changed = payload().put("deadline", NOW + 86400).toString().getBytes(StandardCharsets.UTF_8);
        Files.write(target, changed);
        try { receipt.discard(preview.fingerprint()); throw new AssertionError("Changed file discarded with old review"); }
        catch (IOException expected) { check(Arrays.equals(changed, Files.readAllBytes(target)) && expected.getMessage().contains("未删除"), "Changed receipt not protected"); }
        preview = receipt.preview();
        check(receipt.discard(preview.fingerprint()) && !Files.exists(target), "Reviewed discard failed");
        check(Files.exists(other) && CourseImportReceipt.pending(directory.toFile()).size() == 1, "Discard removed another pending import");
        check(!receipt.discard(preview.fingerprint()), "Already removed file should report absence");
        CourseImportReceipt remaining = new CourseImportReceipt(directory.toFile(), other.toString());
        Store store = new Store();
        check(remaining.commit(store, () -> NOW).removed && store.value.getJSONArray("courses").length() == 1, "Discard damaged a different import");
    }
    static void revisedDeadline(Path directory) throws Exception {
        Path path = write(directory, payload().put("deadline", Planner.at(DAY.minusDays(1), 0)).toString());
        CourseImportReceipt receipt = new CourseImportReceipt(directory.toFile(), path.toString());
        CourseImportReceipt.Preview preview = receipt.preview(); byte[] bytes = Files.readAllBytes(path); Store store = new Store();
        try { receipt.commit(store, () -> NOW, preview.fingerprint()); throw new AssertionError("Expired deadline accepted"); }
        catch (IllegalArgumentException expected) { check(store.saves == 0 && Files.exists(path), "Expired deadline consumed capture"); }
        for (double invalid : new double[]{Double.NaN, Double.POSITIVE_INFINITY, Planner.at(DAY.minusDays(1), 0), Planner.at(DAY.plusYears(10).plusDays(1), 0)}) {
            try { receipt.commit(store, () -> NOW, preview.fingerprint(), invalid); throw new AssertionError("Invalid revised deadline accepted"); }
            catch (IOException | IllegalArgumentException expected) { check(store.saves == 0 && Arrays.equals(bytes, Files.readAllBytes(path)), "Invalid date changed capture or saved partial state"); }
        }
        double desired = Planner.at(DAY.plusDays(30), 0);
        try { receipt.commit(store, () -> Planner.at(DAY.plusDays(1), 0), preview.fingerprint(), Planner.at(DAY, 0)); throw new AssertionError("Yesterday's revised date accepted after midnight"); }
        catch (IllegalArgumentException expected) { check(store.saves == 0 && receipt.exists(), "Date was not checked against commit clock"); }
        try { receipt.commit(store, () -> NOW, null, desired); throw new AssertionError("Unreviewed override accepted"); }
        catch (IOException expected) { check(store.saves == 0 && receipt.exists(), "Override bypassed review"); }
        byte[] wrong = preview.fingerprint(); wrong[0] ^= 1;
        try { receipt.commit(store, () -> NOW, wrong, desired); throw new AssertionError("Date override bypassed file fingerprint"); }
        catch (IOException expected) { check(store.saves == 0 && receipt.exists(), "Changed review saved with revised date"); }
        CourseImportReceipt.Result saved = receipt.commit(store, () -> NOW, preview.fingerprint(), desired);
        JSONObject imported = saved.state.getJSONArray("courses").getJSONObject(0);
        check(saved.removed && imported.getDouble("deadline") == desired, "Revised date did not recover pending import");
        check(preview.deadline.equals(DAY.minusDays(1).toString()), "Date override changed original preview");
        double start = imported.getDouble("startDate"); String id = imported.getString("id");
        path = write(directory, payload().toString()); receipt = new CourseImportReceipt(directory.toFile(), path.toString()); preview = receipt.preview();
        saved = receipt.commit(store, () -> NOW + 60, preview.fingerprint(), Planner.at(DAY.plusDays(60), 0));
        check(saved.state.getJSONArray("courses").length() == 1 && Planner.course(saved.state, id).getDouble("deadline") == desired &&
            Planner.course(saved.state, id).getDouble("startDate") == start, "Reviewed deadline rewrote an existing course's dates");
    }
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("study-import-receipt-");
        try { successfulRetry(directory); invalidPayloads(directory); pathScope(directory); atomicStaging(directory); staleRetry(directory); reviewedImports(directory); reviewedDiscard(directory); revisedDeadline(directory); }
        finally { try (Stream<Path> files = Files.walk(directory)) { for (Path path : (Iterable<Path>)files.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(path); } }
        System.out.println("CourseImportReceiptTests: " + checks + " checks passed");
    }
}
