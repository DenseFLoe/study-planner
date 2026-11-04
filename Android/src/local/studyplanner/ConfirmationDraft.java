package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** The task details the user saw, checked again inside the save transaction. */
public final class ConfirmationDraft {
    private final Map<String, String> tasks = new LinkedHashMap<>();

    public ConfirmationDraft(List<JSONObject> displayed) throws Exception {
        for (JSONObject task : displayed) tasks.put(task.getString("id"), identity(task));
    }

    private static String identity(JSONObject task) throws Exception {
        JSONObject value = new JSONObject();
        for (String key : new String[]{"id", "courseID", "lessonID", "lessonName", "start",
                "durationMinutes", "floatingWindowStart", "floatingWindowEnd"})
            if (task.has(key)) value.put(key, task.get(key));
        return SyncLedger.canonical(value);
    }

    /** Returns whether the freshly read plan needs rebuilding after this confirmation. */
    public boolean apply(JSONObject state, Map<String, Integer> minutes,
                         Map<String, LocalDate> studyDates, double now) throws Exception {
        if (minutes.isEmpty()) throw new IllegalArgumentException("请至少填写一项");
        Map<String, JSONObject> current = new HashMap<>();
        for (JSONObject task : Planner.list(state.getJSONArray("tasks"))) current.put(task.getString("id"), task);
        boolean replan = false;
        for (Map.Entry<String, Integer> entry : minutes.entrySet()) {
            String id = entry.getKey(); JSONObject task = current.get(id);
            JSONObject course = task == null ? null : Planner.course(state, task.optString("courseID"));
            if (!tasks.containsKey(id) || task == null || !Planner.pending(task) || course == null ||
                    course.optBoolean("isArchived") || !tasks.get(id).equals(identity(task)))
                throw new IllegalArgumentException("待确认任务已被修改、确认或删除。本次填写尚未保存，请关闭窗口并核对最新任务后重试。");
            if (entry.getValue() == null || entry.getValue() < 0 || entry.getValue() > task.getInt("durationMinutes"))
                throw new IllegalArgumentException("实际时长必须在 0 与计划时长之间");
            LocalDate date = studyDates.get(id);
            if (date == null || date.isAfter(Planner.day(now)))
                throw new IllegalArgumentException("请核对实际学习日期，不能晚于今天");
            replan |= Planner.confirmationRequiresReplan(task, entry.getValue(), now);
        }
        JSONObject next = CourseTools.copy(state);
        // A batch commits only after every confirmation succeeds, including credit calculations.
        for (Map.Entry<String, Integer> entry : minutes.entrySet())
            Planner.confirm(next, entry.getKey(), entry.getValue(), now, studyDates.get(entry.getKey()));
        state.put("tasks", next.getJSONArray("tasks")).put("completions", next.getJSONArray("completions"));
        return replan;
    }
}
