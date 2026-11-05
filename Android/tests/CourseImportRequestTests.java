package local.studyplanner;

import org.json.*;
import java.util.*;

public final class CourseImportRequestTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static CourseImportRequest request(List<JSONObject> captures, String merge) {
        Set<String> ids = new HashSet<>();
        for (JSONObject capture : captures) ids.add(WebCourseImport.identity(capture));
        return new CourseImportRequest(captures, ids, merge, ImportParityTests.deadline);
    }
    static void rejects(CourseImportRequest request, String message) throws Exception {
        try { request.prepare(); throw new AssertionError(message); }
        catch (IllegalArgumentException expected) { checks++; }
    }
    public static void main(String[] args) throws Exception {
        JSONObject first = ImportParityTests.snapshot(50, 0, ImportParityTests.now);
        JSONObject second = CourseTools.copy(first).put("packageID", "second");
        List<JSONObject> captures = new ArrayList<>(Arrays.asList(first, second));
        Set<String> selected = new HashSet<>(Collections.singleton(WebCourseImport.identity(first)));
        CourseImportRequest pending = new CourseImportRequest(captures, selected, null, ImportParityTests.deadline);
        selected.clear(); selected.add(WebCourseImport.identity(second)); captures.clear();
        check(pending.prepare().equals(Collections.singletonList(first)), "Later UI selection/refresh changed queued import");
        check(pending.deadline == ImportParityTests.deadline, "Queued import lost its deadline");
        String before = first.toString(); pending.prepare();
        check(first.toString().equals(before), "Preparation changed captured progress");
        rejects(request(Collections.emptyList(), null), "Empty selection accepted");
        rejects(new CourseImportRequest(Collections.singletonList(first), Collections.singleton("missing"), null, 0), "Missing selected course silently omitted");
        rejects(request(Arrays.asList(first, first), null), "Ambiguous duplicate capture accepted");
        JSONObject invalid = CourseTools.copy(first).put("refusal", "incomplete");
        rejects(request(Collections.singletonList(invalid), null), "Refused capture accepted");
        invalid = CourseTools.copy(first); invalid.getJSONArray("lessons").getJSONObject(0).remove("watchedPercent");
        rejects(request(Collections.singletonList(invalid), null), "Unverified progress accepted");
        // Constructor must only snapshot containers, even for thousands of lessons.
        JSONObject unread = new JSONObject() {
            @Override public String optString(String key) { throw new AssertionError("UI traversed captured JSON"); }
            @Override public String toString() { throw new AssertionError("UI serialized captured JSON"); }
        };
        new CourseImportRequest(Collections.singletonList(unread), Collections.singleton("course"), "合并", 0);
        checks++;
        JSONArray entries = new JSONArray();
        for (String folder : new String[]{"基础课程", "强化课程"}) {
            entries.put(ImportParityTests.folder(folder));
            for (int i = 1; i <= 3; i++) entries.put(ImportParityTests.video(folder, folder + i, folder + "第" + i + "讲.mp4", 600.0));
        }
        List<JSONObject> net = NetdiskImport.build(ImportParityTests.scan(entries));
        check(net.size() == 2, "Netdisk fixture did not identify both directories");
        String netBefore = new JSONArray(net).toString();
        List<JSONObject> merged = request(net, "数学合并").prepare();
        check(merged.size() == 1 && merged.get(0).getString("name").equals("数学合并"), "Queued merge lost requested title");
        check(merged.get(0).getJSONArray("lessons").length() == 6, "Queued merge lost lessons");
        check(new JSONArray(net).toString().equals(netBefore), "Merge preparation mutated source directories");
        rejects(request(net, " "), "Blank merge title accepted");
        rejects(request(net.subList(0, 1), "数学合并"), "Single-directory merge accepted");
        System.out.println("Course import request: " + checks + " checks passed");
    }
}
