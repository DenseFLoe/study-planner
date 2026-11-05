package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.*;
import java.util.*;

/** File backups shared with macOS; the original Android state-only files remain readable. */
public final class PlannerBackupFile {
    public static final long MAX_BYTES = 64L * 1024 * 1024;
    private static final String[] FIELDS = {"schemaVersion", "courses", "fixedEvents", "tasks", "completions", "settings"};
    private final JSONObject envelope;
    public final boolean legacy;

    private PlannerBackupFile(JSONObject envelope, boolean legacy) { this.envelope = envelope; this.legacy = legacy; }

    static JSONObject businessState(JSONObject source) throws Exception {
        JSONObject result = new JSONObject();
        for (String key : FIELDS) result.put(key, CourseTools.copyValue(source.get(key)));
        result = CourseSourcePrivacy.state(result);
        Planner.validate(result);
        return result;
    }

    public static PlannerBackupFile create(JSONObject state, double now) throws Exception {
        return create(state, now, "Android 导出备份");
    }
    static PlannerBackupFile create(JSONObject state, double now, String reason) throws Exception {
        if (!Double.isFinite(now)) throw new IllegalArgumentException("备份时间无效");
        return new PlannerBackupFile(new JSONObject().put("format", 1).put("id", Planner.id()).put("createdAt", now)
            .put("reason", reason).put("state", businessState(state)), false);
    }

    public static PlannerBackupFile read(InputStream input) throws Exception { return read(input, MAX_BYTES); }
    static PlannerBackupFile read(InputStream input, long maximum) throws Exception {
        JSONObject value = BoundedJSONFile.read(input, maximum, "备份文件");
        if (value.has("format") || value.has("state")) {
            if (Planner.exactProgressInteger(value.opt("format")) != 1 || !CloudSnapshot.validID(value.getString("id")) ||
                    !(value.get("createdAt") instanceof Number) || !Double.isFinite(value.getDouble("createdAt")) || !(value.get("reason") instanceof String))
                throw new IllegalArgumentException("不支持此备份格式或备份信息不完整");
            value.put("state", businessState(value.getJSONObject("state")));
            return new PlannerBackupFile(value, false);
        }
        return new PlannerBackupFile(new JSONObject().put("state", businessState(value)), true);
    }

    /** Startup migration keeps all legacy fields until the existing open migration runs. */
    public static JSONObject readLegacyState(InputStream input) throws Exception { return readLegacyState(input, MAX_BYTES); }
    static JSONObject readLegacyState(InputStream input, long maximum) throws Exception {
        JSONObject value = BoundedJSONFile.read(input, maximum, "备份文件");
        Planner.validate(value);
        return CourseSourcePrivacy.state(value);
    }

    public void write(OutputStream output) throws Exception {
        if (output == null) throw new IOException("无法创建备份文件");
        if (legacy) throw new IllegalStateException("请从当前日程创建新备份后导出");
        try (Writer writer = new BufferedWriter(new OutputStreamWriter(new CloudSnapshot.LimitedOutput(output, MAX_BYTES), StandardCharsets.UTF_8))) {
            SyncJSON.write(writer, envelope);
        }
    }

    public JSONObject state() throws Exception { return CourseTools.copy(envelope.getJSONObject("state")); }
    String id() { return envelope.optString("id"); }
    double createdAt() { return envelope.optDouble("createdAt"); }
    String deletedCourseID() { return envelope.optString("deletedCourseID", ""); }
    void markDeletedCourse(String id) throws Exception {
        if(id!=null&&!id.isEmpty()){
            if(Planner.course(envelope.getJSONObject("state"),id)==null)throw new IllegalArgumentException("备份中没有待删除课程。");
            envelope.put("deletedCourseID",id);
        }
    }
    public String summary() throws Exception {
        JSONObject state = envelope.getJSONObject("state");
        String time = legacy ? "旧版 Android 备份" : "备份时间：" + Planner.date(envelope.getDouble("createdAt")) + " " + Planner.clock(envelope.getDouble("createdAt"));
        return time + (legacy ? "" : "\n" + envelope.getString("reason")) + "\n" + counts(state);
    }
    public static String counts(JSONObject state) throws Exception {
        return state.getJSONArray("courses").length() + " 门课程、" + state.getJSONArray("fixedEvents").length() + " 条固定规则、" +
            state.getJSONArray("tasks").length() + " 条任务、" + state.getJSONArray("completions").length() + " 条学习记录";
    }

    public static final class Restore {
        private final JSONObject candidate;
        private final String baseline;
        public final String summary;
        public Restore(PlannerBackupFile file, JSONObject current) throws Exception {
            candidate = file.state(); baseline = SyncLedger.canonical(businessState(current));
            summary = file.summary() + "\n\n手机当前：" + counts(current);
        }
        void check(JSONObject current) throws Exception {
            if (!baseline.equals(SyncLedger.canonical(businessState(current))))
                throw new IllegalArgumentException("日程在核对备份期间已有更新，未执行恢复。请重新选择备份并核对最新记录。");
        }
        public void apply(JSONObject current) throws Exception {
            check(current);
            JSONObject replacement = CourseTools.copy(candidate);
            List<String> keys = new ArrayList<>(); Iterator<String> names = current.keys(); while (names.hasNext()) keys.add(names.next());
            for (String key : keys) current.remove(key);
            for (String key : FIELDS) current.put(key, replacement.get(key));
        }
    }
}
