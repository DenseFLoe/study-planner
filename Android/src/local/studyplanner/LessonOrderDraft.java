package local.studyplanner;

import org.json.*;
import java.util.*;

/** Stable editor baseline; only ordering/deletion intent is written to fresh data. */
public final class LessonOrderDraft {
    private final JSONObject course, history;
    private final List<String> originalOrder;

    public LessonOrderDraft(JSONObject state, String courseID) throws Exception {
        JSONObject current = Planner.course(state, courseID);
        if (current == null || current.optBoolean("isArchived")) throw removed();
        course = CourseTools.copy(current);
        originalOrder = CourseTools.order(course);
        // Pending plans are replaceable and do not constitute deletion evidence.
        // Retain only this course's history, not a second copy of the whole planner.
        JSONArray records = new JSONArray(), tasks = new JSONArray();
        Set<String> confirmed = new HashSet<>();
        for (JSONObject record : Planner.list(state.getJSONArray("completions")))
            if (record.optString("courseID").equals(courseID)) {
                records.put(CourseTools.copy(record)); confirmed.add(record.optString("taskID"));
            }
        for (JSONObject task : Planner.list(state.getJSONArray("tasks")))
            if (task.optString("courseID").equals(courseID) && (!Planner.pending(task) || confirmed.contains(task.optString("id"))))
                tasks.put(CourseTools.copy(task));
        history = new JSONObject().put("tasks", tasks).put("completions", records);
    }

    public List<String> originalOrder() { return new ArrayList<>(originalOrder); }
    static IllegalArgumentException removed() {
        return new IllegalArgumentException("这门课程已被删除，不能保存旧排序草稿。请关闭窗口查看最新课程。");
    }
    static IllegalArgumentException changed(String detail) {
        return new IllegalArgumentException(detail + "。当前草稿仍保留，最新数据未被覆盖，请重新打开排序窗口后核对。");
    }

    private static JSONObject catalog(JSONObject course) throws Exception {
        JSONObject value = new JSONObject();
        for (String key : new String[]{"id", "type", "totalMinutes", "manualLessons"})
            if (course.has(key)) value.put(key, CourseTools.copyValue(course.get(key)));
        value.put("deletedLessonIDs", new JSONArray(new TreeSet<>(CourseTools.deletedIDs(course))));
        JSONObject web = course.optJSONObject("webCourse");
        if (web != null) {
            value.put("websiteID", WebCourseImport.identity(web));
            JSONArray lessons = new JSONArray();
            for (JSONObject raw : Planner.list(web.getJSONArray("lessons"))) {
                JSONObject lesson = CourseTools.copy(raw);
                lesson.remove("watchedPercent"); lesson.remove("markedFinished"); lessons.put(lesson);
            }
            value.put("websiteLessons", lessons);
        }
        JSONArray sources = course.optJSONArray("mergedSources");
        if (sources != null) {
            JSONArray values = new JSONArray();
            for (JSONObject source : Planner.list(sources)) values.put(catalog(source).put("name", source.optString("name")));
            value.put("sources", values);
        }
        return value;
    }

    private static String descriptions(JSONObject state, JSONObject course) throws Exception {
        JSONObject result = new JSONObject();
        for (Planner.Work item : Planner.lessonWorkAll(state, course)) result.put(item.lessonID, item.lessonName);
        return SyncLedger.canonical(result);
    }

    private static String deletionHistory(JSONObject state, JSONObject course, Set<String> deleted) throws Exception {
        JSONObject remaining = new JSONObject(), tasks = new JSONObject(), records = new JSONObject();
        for (Planner.Work item : Planner.lessonWorkAll(state, course))
            if (deleted.contains(item.lessonID)) remaining.put(item.lessonID, item.minutes);
        Set<String> taskIDs = new HashSet<>(), confirmed = new HashSet<>();
        for (JSONObject task : Planner.list(state.getJSONArray("tasks")))
            if (task.optString("courseID").equals(course.getString("id")) && deleted.contains(task.optString("lessonID")))
                taskIDs.add(task.getString("id"));
        for (JSONObject record : Planner.list(state.getJSONArray("completions")))
            if (record.optString("courseID").equals(course.getString("id")) && taskIDs.contains(record.optString("taskID"))) {
                records.put(record.getString("id"), record); confirmed.add(record.getString("taskID"));
            }
        for (JSONObject task : Planner.list(state.getJSONArray("tasks")))
            if (taskIDs.contains(task.optString("id")) && (!Planner.pending(task) || confirmed.contains(task.optString("id"))))
                tasks.put(task.getString("id"), task);
        return SyncLedger.canonical(new JSONObject().put("remaining", remaining).put("tasks", tasks).put("completions", records));
    }

    public void apply(JSONObject state, List<String> order, Set<String> deleted) throws Exception {
        apply(state, order, deleted, false);
    }

    public void apply(JSONObject state, List<String> order, Set<String> deleted, boolean followWebsite) throws Exception {
        JSONObject current = Planner.course(state, course.getString("id"));
        if (current == null || current.optBoolean("isArchived")) throw removed();
        if (!followWebsite && deleted.isEmpty() && order.equals(originalOrder)) return;
        Set<String> known = new HashSet<>(originalOrder), retained = new HashSet<>(known);
        retained.removeAll(deleted);
        if (!known.containsAll(deleted) || order.isEmpty() || new HashSet<>(order).size() != order.size() || !retained.equals(new HashSet<>(order)))
            throw changed("排序草稿与待保留课节不一致");
        if (!SyncLedger.canonical(catalog(course)).equals(SyncLedger.canonical(catalog(current))) ||
            !descriptions(history, course).equals(descriptions(state, current)))
            throw changed("课节列表、名称或时长在编辑期间已变化");
        List<String> website = new ArrayList<>();
        for (JSONObject lesson : CourseTools.lessons(course)) if (!deleted.contains(lesson.getString("id"))) website.add(lesson.getString("id"));
        if (followWebsite && (course.optJSONObject("webCourse") == null || !order.equals(website)))
            throw changed("请重新选择按网站顺序");
        boolean customized = course.optJSONObject("webCourse") == null || !order.equals(website);
        List<String> currentOrder = CourseTools.order(current);
        if ((!currentOrder.equals(originalOrder) && !(deleted.isEmpty() && currentOrder.equals(order))) ||
            (!Objects.equals(current.opt("lessonOrderCustomized"), course.opt("lessonOrderCustomized")) &&
             !Objects.equals(current.opt("lessonOrderCustomized"), customized)))
            throw changed("课节顺序在编辑期间已被修改");
        if (!deleted.isEmpty() && !deletionHistory(history, course, deleted).equals(deletionHistory(state, current, deleted)))
            throw changed("待删除课节的学习记录或进度已有变化，未执行删除");
        JSONObject next = CourseTools.copy(state);
        if (!deleted.isEmpty()) CourseTools.removeLessons(next, course.getString("id"), deleted);
        Planner.course(next, course.getString("id")).put("lessonOrder", new JSONArray(order)).put("lessonOrderCustomized", customized);
        for (String key : new String[]{"courses", "tasks", "completions"}) state.put(key, next.get(key));
    }
}
