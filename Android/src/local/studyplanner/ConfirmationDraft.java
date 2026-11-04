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

    /** Read a detached, still-confirmable task for an explicitly refreshed form. */
    public static JSONObject pendingTask(JSONObject state, String id) throws Exception {
        for (JSONObject task : Planner.list(state.optJSONArray("tasks"))) if (task.optString("id").equals(id)) {
            JSONObject course = Planner.course(state, task.optString("courseID"));
            if (Planner.pending(task) && course != null && !course.optBoolean("isArchived")) return CourseTools.copy(task);
            break;
        }
        throw new IllegalArgumentException("这项任务已确认、移除或所属课程已删除、归档，请返回日历核对。");
    }

    /** Undo applies only to the confirmation rendered on the card. */
    public static final class Undo {
        private final String taskID, task, records;

        public Undo(JSONObject state, JSONObject displayed) throws Exception {
            this(displayed, records(state, displayed.getString("id")));
        }

        private Undo(JSONObject displayed, String capturedRecords) throws Exception {
            taskID = displayed.getString("id");
            task = SyncLedger.canonical(displayed);
            records = capturedRecords;
        }

        /** Capture every displayed historical card with one pass over all completion records. */
        public static Map<String, Undo> captureRecorded(JSONObject state, Collection<JSONObject> displayed) throws Exception {
            Map<String, JSONObject> tasks = new LinkedHashMap<>(), records = new HashMap<>();
            for (JSONObject task : displayed) if (!Planner.pending(task)) tasks.put(task.getString("id"), task);
            if (tasks.isEmpty()) return Collections.emptyMap();
            for (JSONObject record : Planner.list(state.getJSONArray("completions"))) {
                String taskID = record.optString("taskID");
                if (!tasks.containsKey(taskID)) continue;
                JSONObject rows = records.computeIfAbsent(taskID, key -> new JSONObject());
                rows.put(record.getString("id"), record);
            }
            Map<String, Undo> result = new LinkedHashMap<>();
            for (Map.Entry<String, JSONObject> entry : tasks.entrySet()) {
                JSONObject rows = records.get(entry.getKey());
                result.put(entry.getKey(), new Undo(entry.getValue(), SyncLedger.canonical(rows == null ? new JSONObject() : rows)));
            }
            return Collections.unmodifiableMap(result);
        }

        private static String records(JSONObject state, String id) throws Exception {
            JSONObject rows = new JSONObject();
            for (JSONObject record : Planner.list(state.getJSONArray("completions")))
                if (record.optString("taskID").equals(id)) rows.put(record.getString("id"), record);
            return SyncLedger.canonical(rows);
        }

        public void apply(JSONObject state, double now) throws Exception {
            JSONObject current = null;
            for (JSONObject row : Planner.list(state.getJSONArray("tasks")))
                if (row.optString("id").equals(taskID)) current = row;
            if (current == null || !task.equals(SyncLedger.canonical(current)) || !records.equals(records(state, taskID)))
                throw new IllegalArgumentException("这条完成记录已更新或撤销，未执行本次撤销。请核对最新记录后重试。");
            JSONObject next = CourseTools.copy(state);
            Planner.undoConfirmation(next, taskID, now);
            for (String key : new String[]{"courses", "tasks", "completions"}) state.put(key, next.get(key));
        }
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
                throw new IllegalArgumentException("待确认任务已被修改、确认或删除。本次填写尚未保存，可刷新待确认列表或重新打开确认窗口，核对最新任务后重试。");
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
