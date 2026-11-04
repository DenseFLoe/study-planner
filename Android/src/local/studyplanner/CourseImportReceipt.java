package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.*;
import java.nio.file.*;
import java.security.*;
import java.util.*;
import java.util.function.DoubleSupplier;

/** A private handoff file is consumed only after the database confirms a durable save. */
final class CourseImportReceipt {
    static final long MAX_BYTES = 25_000_000;
    private final File file;
    CourseImportReceipt(File cache, String path) throws IOException {
        file = new File(path).getCanonicalFile();
        if (!cache.getCanonicalFile().equals(file.getParentFile()) || !validName(file.getName()))
            throw new IOException("导入结果路径无效。");
    }
    private static boolean validName(String name) { return name.matches("course-import-[A-Fa-f0-9-]+\\.json"); }
    boolean exists() { return file.isFile(); }
    static List<File> pending(File cache) {
        File[] files = cache.listFiles(file -> file.isFile() && validName(file.getName()));
        List<File> result = files == null ? new ArrayList<>() : new ArrayList<>(Arrays.asList(files));
        result.sort(Comparator.comparingLong(File::lastModified).reversed().thenComparing(File::getName)); return result;
    }
    static File stage(File cache, List<JSONObject> captures, double deadline) throws Exception {
        return stage(cache, captures, deadline, MAX_BYTES);
    }
    static File stage(File cache, List<JSONObject> captures, double deadline, long limit) throws Exception {
        if (captures.isEmpty()) throw new IllegalArgumentException("请先选择课程。");
        JSONArray clean = new JSONArray(); for (JSONObject capture : captures) clean.put(WebCourseImport.cleanCapture(capture));
        JSONObject payload = new JSONObject().put("snapshots", clean).put("deadline", deadline);
        File temporary = File.createTempFile("course-import-", ".tmp", cache);
        try {
            temporary.setReadable(false, false); temporary.setWritable(false, false);
            temporary.setReadable(true, true); temporary.setWritable(true, true);
            try (FileOutputStream bytes = new FileOutputStream(temporary)) {
                OutputStream retained = new FilterOutputStream(bytes) {
                    public void write(byte[] value, int offset, int count) throws IOException { out.write(value, offset, count); }
                    public void close() throws IOException { flush(); }
                };
                try (Writer writer = new BufferedWriter(new OutputStreamWriter(new CloudSnapshot.LimitedOutput(retained, limit), StandardCharsets.UTF_8))) {
                    SyncJSON.write(writer, payload);
                }
                bytes.getFD().sync();
            }
            File result = new File(cache, "course-import-" + UUID.randomUUID() + ".json");
            Files.move(temporary.toPath(), result.toPath(), StandardCopyOption.ATOMIC_MOVE);
            return result;
        } finally { Files.deleteIfExists(temporary.toPath()); }
    }
    private static final class Payload {
        final JSONObject data; final byte[] fingerprint;
        Payload(JSONObject data, byte[] fingerprint) { this.data = data; this.fingerprint = fingerprint; }
    }
    private Payload read() throws Exception {
        if (!file.isFile()) throw new IOException("导入结果已不存在，请重新抓取课程。");
        if (file.length() > MAX_BYTES) throw new IOException("导入结果超过大小上限，原文件已保留。");
        StringBuilder text = new StringBuilder(); MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (Reader reader = new BufferedReader(new InputStreamReader(new DigestInputStream(new CloudSnapshot.LimitedInput(new FileInputStream(file), MAX_BYTES), digest),
                StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)))) {
            char[] buffer = new char[8192]; int count; while ((count = reader.read(buffer)) != -1) text.append(buffer, 0, count);
        }
        JSONTokener tokens = new JSONTokener(text.toString()); JSONObject result = new JSONObject(tokens);
        if (tokens.nextClean() != 0) throw new IOException("导入结果含有多余内容，原文件已保留。");
        return new Payload(result, digest.digest());
    }
    static final class Preview {
        static final int PAGE_SIZE = 100;
        private final List<String> rows;
        private final byte[] fingerprint;
        final String deadline;
        final long totalMinutes;
        Preview(List<String> rows, byte[] fingerprint, String deadline, long totalMinutes) {
            this.rows = Collections.unmodifiableList(rows); this.fingerprint = fingerprint;
            this.deadline = deadline; this.totalMinutes = totalMinutes;
        }
        byte[] fingerprint() { return fingerprint.clone(); }
        int count() { return rows.size(); }
        int pageCount() { return (rows.size() - 1) / PAGE_SIZE + 1; }
        List<String> page(int index) {
            if (index < 0 || index >= pageCount()) return Collections.emptyList();
            int start = index * PAGE_SIZE; return rows.subList(start, Math.min(rows.size(), start + PAGE_SIZE));
        }
    }
    Preview preview() throws Exception {
        Payload payload = read(); List<String> rows = new ArrayList<>(); long total = 0;
        for (JSONObject raw : Planner.list(payload.data.getJSONArray("snapshots"))) {
            JSONObject snapshot = WebCourseImport.sanitize(raw); String problem = WebCourseImport.problem(snapshot);
            if (problem != null) throw new IOException(snapshot.optString("name") + "：" + problem);
            int minutes = WebCourseImport.total(snapshot); total += minutes;
            double fetched = snapshot.getDouble("fetchedAt");
            rows.add(snapshot.getString("name") + "\n" + snapshot.getJSONArray("lessons").length() + " 节 · 总量 " + minutes +
                " 分钟 · 网站已学 " + WebCourseImport.completed(snapshot) + " 分钟\n抓取时间 " + Planner.date(fetched) + " " + Planner.clock(fetched));
        }
        if (rows.isEmpty()) throw new IOException("导入结果没有选中的课程。");
        return new Preview(rows, payload.fingerprint, Planner.date(payload.data.getDouble("deadline")), total);
    }
    static final class Result {
        final JSONObject state;
        final boolean removed;
        Result(JSONObject state, boolean removed) { this.state = state; this.removed = removed; }
    }
    Result commit(StateMutation.Store<JSONObject> store, DoubleSupplier clock) throws Exception {
        return commit(store, clock, null);
    }
    Result commit(StateMutation.Store<JSONObject> store, DoubleSupplier clock, byte[] reviewedFingerprint) throws Exception {
        Payload input = read();
        if (reviewedFingerprint != null && !MessageDigest.isEqual(reviewedFingerprint, input.fingerprint))
            throw new IOException("导入文件在核对后发生变化，未保存。请重新查看未完成的导入。");
        JSONObject payload = input.data; List<JSONObject> snapshots = Planner.list(payload.getJSONArray("snapshots"));
        if (snapshots.isEmpty()) throw new IOException("导入结果没有选中的课程。");
        double deadline = payload.getDouble("deadline");
        JSONObject state = StateMutation.apply(store, latest -> { double now = clock.getAsDouble(); WebCourseImport.save(latest, snapshots, deadline, now); Planner.replan(latest, now); });
        return new Result(state, file.delete() || !file.exists());
    }
}
