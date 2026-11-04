package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.*;
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
    private JSONObject read() throws Exception {
        if (!file.isFile()) throw new IOException("导入结果已不存在，请重新抓取课程。");
        if (file.length() > MAX_BYTES) throw new IOException("导入结果超过大小上限，原文件已保留。");
        StringBuilder text = new StringBuilder();
        try (Reader reader = new BufferedReader(new InputStreamReader(new CloudSnapshot.LimitedInput(new FileInputStream(file), MAX_BYTES),
                StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)))) {
            char[] buffer = new char[8192]; int count; while ((count = reader.read(buffer)) != -1) text.append(buffer, 0, count);
        }
        JSONTokener tokens = new JSONTokener(text.toString()); JSONObject result = new JSONObject(tokens);
        if (tokens.nextClean() != 0) throw new IOException("导入结果含有多余内容，原文件已保留。");
        return result;
    }
    static final class Result {
        final JSONObject state;
        final boolean removed;
        Result(JSONObject state, boolean removed) { this.state = state; this.removed = removed; }
    }
    Result commit(StateMutation.Store<JSONObject> store, DoubleSupplier clock) throws Exception {
        JSONObject payload = read(); List<JSONObject> snapshots = Planner.list(payload.getJSONArray("snapshots"));
        if (snapshots.isEmpty()) throw new IOException("导入结果没有选中的课程。");
        double deadline = payload.getDouble("deadline");
        JSONObject state = StateMutation.apply(store, latest -> { double now = clock.getAsDouble(); WebCourseImport.save(latest, snapshots, deadline, now); Planner.replan(latest, now); });
        return new Result(state, file.delete() || !file.exists());
    }
}
