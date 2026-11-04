package local.studyplanner;

import org.json.*;
import java.util.*;

public final class CourseFileSearchTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject fixture() throws Exception {
        JSONArray lessons = new JSONArray(); JSONObject files = new JSONObject();
        for (int i = 0; i < 205; i++) {
            String id = "file-" + i;
            lessons.put(new JSONObject().put("id", id).put("name", "高数 Lesson " + i).put("durationMinutes", 60));
            files.put(id, new JSONObject().put("path", "/基础/Chapter " + (i / 100) + "/" + i + ".mp4")
                .put("size", 3000000000L + i).put("estimatedDuration", i % 2 == 0));
        }
        return new JSONObject().put("manualLessons", lessons).put("netdiskLessons", files);
    }
    static void paginationAndSearch() throws Exception {
        JSONObject course = fixture(); String before = SyncLedger.canonical(course);
        CourseFileSearch search = new CourseFileSearch(course); CourseFileSearch.Result all = search.find("");
        check(all.count() == 205 && all.pageCount() == 3, "File list was truncated");
        check(all.page(0).size() == 100 && all.page(1).size() == 100 && all.page(2).size() == 5, "File pages lost rows");
        check(all.page(-1).isEmpty() && all.page(3).isEmpty(), "Out-of-range file page accepted");
        Set<String> ids = new HashSet<>(); for (int i = 0; i < all.pageCount(); i++) for (CourseFileSearch.Row row : all.page(i)) ids.add(row.id);
        check(ids.size() == 205, "Pagination duplicated rows");
        check(search.find("基础 ＬＥＳＳＯＮ Chapter 2/").count() == 5, "Combined normalized name/path query failed");
        check(search.find("  \t ").count() == 205 && search.find("unknown").count() == 0, "Blank or unmatched query incorrect");
        check(all.page(0).get(0).label().contains("3000000000 字节 · 估算时长"), "Large file size or estimated marker lost");
        check(all.page(0).get(1).label().contains("网站时长"), "Verified duration incorrectly marked estimated");
        check(before.equals(SyncLedger.canonical(course)), "Search changed course or file metadata");
        course.getJSONArray("manualLessons").getJSONObject(0).put("name", "新名字");
        course.getJSONObject("netdiskLessons").getJSONObject("file-0").put("path", "/新路径");
        check(all.page(0).get(0).name.equals("高数 Lesson 0") && search.find("新路径").count() == 0, "Index retained mutable JSON rows");
        try { all.page(0).clear(); throw new AssertionError("Mutable result page"); }
        catch (UnsupportedOperationException expected) { checks++; }
    }
    static void missingFilesAndVisibleLessons() throws Exception {
        JSONObject course = fixture(); course.remove("netdiskLessons");
        CourseFileSearch.Result missing = new CourseFileSearch(course).find("Lesson");
        check(missing.count() == 205 && missing.page(0).get(0).label().contains("未记录文件信息"), "Missing file metadata hid lesson");
        JSONArray lessons = new JSONArray()
            .put(new JSONObject().put("id", "visible").put("name", "可见课节").put("published", true).put("requiresDuration", true))
            .put(new JSONObject().put("id", "unpublished").put("name", "未发布").put("published", false).put("requiresDuration", true))
            .put(new JSONObject().put("id", "document").put("name", "文档").put("published", true).put("requiresDuration", false));
        course.put("webCourse", new JSONObject().put("lessons", lessons));
        CourseFileSearch.Result web = new CourseFileSearch(course).find("");
        check(web.count() == 1 && web.page(0).get(0).id.equals("visible"), "Hidden or non-learning items appeared as course lessons");
        check(new CourseFileSearch(new JSONObject()).find("").pageCount() == 0, "Empty course did not render empty result");
    }
    public static void main(String[] args) throws Exception {
        paginationAndSearch(); missingFilesAndVisibleLessons();
        System.out.println("CourseFileSearchTests: " + checks + " checks passed");
    }
}
