package local.studyplanner;

import org.json.*;
import java.util.*;

public final class CourseCaptureIntakeTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject activity() throws Exception { return new JSONObject().put("pending", 0).put("failed", 0); }
    public static void main(String[] args) throws Exception {
        JSONObject raw = ImportParityTests.snapshot(50, 0, ImportParityTests.now + 978307200);
        JSONObject result = new JSONObject().put("snapshots", new JSONArray().put(raw)).put("issues", new JSONArray())
            .put("unavailable", new JSONArray().put(new JSONObject().put("name", "旧课程").put("reason", "已失效")));
        String rawBefore = result.toString();
        JSONObject envelope = CourseCaptureIntake.envelope(JSONObject.quote(new JSONObject().put("value", result).toString()));
        CourseCaptureIntake yantu = CourseCaptureIntake.yantu(envelope.getJSONObject("value"));
        check(yantu.values.size() == 1 && yantu.values.get(0).getDouble("fetchedAt") == ImportParityTests.now, "Browser timestamp not converted exactly once");
        check(yantu.notice.contains("旧课程") && yantu.notice.contains("已失效"), "Unavailable-course notice lost on background intake");
        check(result.toString().equals(rawBefore), "Intake mutated original browser envelope");
        check(CourseCaptureIntake.envelope(JSONObject.quote("{\"pending\":true,\"status\":\"正在读取\"}")).getBoolean("pending"), "Polling state lost");
        for (String invalid : new String[]{"null", "{}", JSONObject.quote("broken")}) {
            try { CourseCaptureIntake.envelope(invalid); throw new AssertionError("Malformed browser envelope accepted"); }
            catch (Exception expected) { checks++; }
        }
        result.getJSONArray("issues").put("incomplete");
        try { CourseCaptureIntake.yantu(result); throw new AssertionError("Partial provider capture accepted"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("部分课程"), "Incomplete capture lost actionable reason"); }
        JSONObject lesson = new JSONObject().put("id", "one").put("name", "极限").put("courseId", "math")
            .put("courseName", "数学").put("duration", 3600).put("progress", 0.5);
        JSONObject generic = new JSONObject().put("activity", activity()).put("url", "https://example.test/course?token=PRIVATE")
            .put("title", "数学").put("responses", new JSONArray().put(new JSONObject().put("url", "https://example.test/api")
                .put("body", new JSONObject().put("lessons", new JSONArray().put(lesson)).toString())));
        CourseCaptureIntake prepared = CourseCaptureIntake.generic(generic, ImportParityTests.now);
        check(prepared.values.size() == 1 && prepared.replay == null, "Generic course intake was routed to replay reading");
        check(prepared.values.get(0).getJSONArray("lessons").getJSONObject(0).getDouble("watchedPercent") == 50, "Generic progress changed during intake");
        check(!prepared.values.toString().contains("PRIVATE"), "Source credentials entered published capture");
        for (String flag : new String[]{"pending", "failed"}) {
            generic.getJSONObject("activity").put(flag, 1);
            try { CourseCaptureIntake.generic(generic, ImportParityTests.now); throw new AssertionError("Unfinished browser requests accepted"); }
            catch (IllegalArgumentException expected) { checks++; }
            generic.put("activity", activity());
        }
        JSONObject catalog = new JSONObject().put("courseID", "live42").put("name", "直播课程")
            .put("rows", new JSONArray().put(new JSONObject().put("name", "第一讲").put("key", "chapter/0").put("replay", true)));
        generic.put("url", "https://ixuecheng.cn/detail?id=live42&token=PRIVATE").put("catalog", catalog);
        CourseCaptureIntake live = CourseCaptureIntake.generic(generic, ImportParityTests.now);
        check(live.replay != null && live.replayRows.length() == 1, "Live replay continuation lost its rows");
        check(live.replay.getString("sourceURL").equals("https://ixuecheng.cn/detail?id=live42"), "Replay source did not use captured page URL");
        check(live.replay.getJSONArray("lessons").getJSONObject(0).getString("id").equals("generic:live42:live:第一讲:chapter/0"), "Background intake changed replay lesson identity");
        JSONObject old = prepared.values.get(0), fresh = CourseTools.copy(old);
        fresh.getJSONArray("lessons").put(ImportParityTests.lesson("new", 600, 0));
        fresh.getJSONArray("lessons").getJSONObject(0).put("watchedPercent", 0);
        String oldBefore = old.toString(), freshBefore = fresh.toString();
        Set<String> selected = new HashSet<>(Arrays.asList(WebCourseImport.identity(old), "missing"));
        CourseCaptureIntake.Accepted accepted = CourseCaptureIntake.accept(Collections.singletonList(old), Collections.singletonList(fresh), true, selected);
        check(accepted.captures.get(0).getJSONArray("lessons").length() == 2, "Cross-page merge lost newly captured lesson");
        check(accepted.captures.get(0).getJSONArray("lessons").getJSONObject(0).getDouble("watchedPercent") == 50, "Refresh erased verified progress");
        check(accepted.selected.equals(Collections.singleton(WebCourseImport.identity(old))) && selected.contains("missing"), "Selection was dropped, broadened, or mutated");
        check(oldBefore.equals(old.toString()) && freshBefore.equals(fresh.toString()), "Publication merge modified source captures");
        CourseCaptureIntake.Accepted empty = CourseCaptureIntake.accept(accepted.captures, Collections.emptyList(), true, accepted.selected);
        check(empty.captures.size() == 1 && empty.selected.equals(accepted.selected), "Empty incremental capture erased earlier pages");
        check(CourseCaptureIntake.accept(accepted.captures, Collections.emptyList(), false, accepted.selected).captures.isEmpty(), "Provider replacement kept removed courses");
        fresh.getJSONArray("issues").put("incomplete");
        CourseCaptureIntake.Accepted invalid = CourseCaptureIntake.accept(Collections.emptyList(), Collections.singletonList(fresh), false, accepted.selected);
        check(invalid.captures.size() == 1 && invalid.selected.isEmpty(), "Incomplete capture hidden from review or remained selected");
        System.out.println("Course capture intake: " + checks + " checks passed");
    }
}
