package local.studyplanner;

import org.json.*;
import java.util.*;

/** Browser envelopes and course reconciliation prepared before publishing to the UI. */
final class CourseCaptureIntake {
    final List<JSONObject> values;
    final JSONObject replay;
    final JSONArray replayRows;
    final String notice;
    private CourseCaptureIntake(List<JSONObject> values, JSONObject replay, JSONArray rows, String notice) {
        this.values = values; this.replay = replay; replayRows = rows; this.notice = notice;
    }
    static JSONObject envelope(String encoded) throws Exception {
        BackgroundCancellation.check();
        Object outer = new JSONTokener(encoded).nextValue();
        if (!(outer instanceof String)) throw new IllegalArgumentException("页面返回的数据无法读取，请重试。");
        JSONObject result = new JSONObject((String) outer);
        BackgroundCancellation.check();
        return result;
    }
    static CourseCaptureIntake yantu(JSONObject result) throws Exception {
        JSONArray issues = result.optJSONArray("issues");
        if (issues != null && issues.length() > 0) throw new IllegalArgumentException("部分课程抓取失败，请重试后再导入。");
        List<JSONObject> values = new ArrayList<>();
        for (JSONObject raw : Planner.list(result.getJSONArray("snapshots"))) {
            BackgroundCancellation.check();
            JSONObject snapshot = CourseTools.copy(raw);
            snapshot.put("fetchedAt", snapshot.getDouble("fetchedAt") - 978307200);
            values.add(snapshot);
        }
        StringBuilder notice = new StringBuilder();
        JSONArray unavailable = result.optJSONArray("unavailable");
        if (unavailable != null && unavailable.length() > 0) {
            notice.append("\n未导入的失效或不可读取课程：");
            for (JSONObject item : Planner.list(unavailable)) {
                BackgroundCancellation.check();
                notice.append('\n').append(item.optString("name")).append(" · ").append(item.optString("reason"));
            }
        }
        return new CourseCaptureIntake(values, null, null, notice.toString());
    }
    static CourseCaptureIntake generic(JSONObject result, double now) throws Exception {
        JSONObject activity = result.getJSONObject("activity");
        if (activity.optInt("pending") > 0 || activity.optInt("failed") > 0)
            throw new IllegalArgumentException("网页请求尚未完成或有请求失败，请刷新后重试。");
        BackgroundCancellation.check();
        String url = result.getString("url");
        List<JSONObject> values = GenericCourseDigest.snapshots(result.getJSONArray("responses"), url, result.optString("title"), now);
        BackgroundCancellation.check();
        JSONObject catalog = result.optJSONObject("catalog");
        return catalog == null ? new CourseCaptureIntake(values, null, null, "")
            : new CourseCaptureIntake(values, WebsiteCapture.xuecheng(catalog, values, url, now), catalog.getJSONArray("rows"), "");
    }
    static final class Accepted {
        final List<JSONObject> captures;
        final Set<String> selected;
        Accepted(List<JSONObject> captures, Set<String> selected) { this.captures = captures; this.selected = selected; }
    }
    static Accepted accept(List<JSONObject> previous, List<JSONObject> values, boolean append, Set<String> selected) throws Exception {
        BackgroundCancellation.check();
        List<JSONObject> captures = append ? WebsiteCapture.merge(previous, values) : new ArrayList<>(values);
        BackgroundCancellation.check();
        Set<String> retained = CourseImportCatalog.retainedSelection(captures, selected);
        BackgroundCancellation.check();
        return new Accepted(Collections.unmodifiableList(captures), Collections.unmodifiableSet(retained));
    }
}
