package local.studyplanner;

import org.json.*;
import java.util.*;

/** Reapply a form's intent to the course read inside the database worker. */
public final class CourseEditing {
    private CourseEditing() {}

    public static final class Draft {
        private final JSONObject baseline;
        private final LessonOrderDraft deletionGuard;

        public Draft(JSONObject state, JSONObject original) throws Exception {
            baseline = original == null ? null : CourseTools.copy(original);
            deletionGuard = original != null && original.optJSONArray("manualLessons") != null &&
                Planner.isManualLessonCourse(original, original.optString("type"))
                ? new LessonOrderDraft(state, original.getString("id")) : null;
        }

        public void save(JSONObject state, JSONObject edited, double now) throws Exception {
            JSONObject resolved = resolve(state, edited, baseline);
            JSONObject current = Planner.course(state, resolved.getString("id"));
            if (deletionGuard != null && current != null && resolved.optJSONArray("manualLessons") != null &&
                Planner.isManualLessonCourse(resolved, resolved.optString("type"))) {
                Set<String> removed = new HashSet<>(), retained = new HashSet<>();
                for (JSONObject lesson : Planner.list(resolved.getJSONArray("manualLessons"))) retained.add(lesson.getString("id"));
                for (JSONObject lesson : Planner.list(current.optJSONArray("manualLessons")))
                    if (!retained.contains(lesson.getString("id"))) removed.add(lesson.getString("id"));
                deletionGuard.checkDeletionHistory(state, removed);
            }
            CourseTools.updateCourse(state, resolved, now);
        }
    }

    static IllegalArgumentException conflict() {
        return new IllegalArgumentException("这门课程在编辑期间已有其他修改，与当前草稿冲突。草稿仍保留，最新数据未被覆盖，请重新打开课程后编辑。");
    }

    static JSONObject schedulingInputs(JSONObject course) throws Exception {
        JSONObject value = CourseTools.copy(course);
        for (String field : new String[]{"name", "notes", "color"}) value.remove(field);
        // Older peers may omit default-valued fields which the form materializes.
        value.put("minimumBlockMinutes", course.optInt("minimumBlockMinutes", 0));
        value.put("priority", course.optInt("priority", 2));
        value.put("autoScheduleEnabled", course.optBoolean("autoScheduleEnabled", true));
        value.put("isArchived", course.optBoolean("isArchived", false));
        value.put("lessonOrder", new JSONArray(CourseTools.order(course)));
        return value;
    }

    public static JSONObject resolve(JSONObject state, JSONObject edited, JSONObject baseline) throws Exception {
        JSONObject current = Planner.course(state, edited.getString("id"));
        if (baseline == null) {
            if (current != null) throw conflict();
            return CourseTools.copy(edited);
        }
        if (!edited.getString("id").equals(baseline.getString("id"))) throw conflict();
        if (current == null || current.optBoolean("isArchived"))
            throw new IllegalArgumentException("这门课程已被删除，旧编辑窗口不能重新创建它。草稿仍保留，请关闭窗口后查看最新课程。");

        String oldInputs = SyncLedger.canonical(schedulingInputs(baseline));
        String draftInputs = SyncLedger.canonical(schedulingInputs(edited));
        String latestInputs = SyncLedger.canonical(schedulingInputs(current));
        JSONObject merged;
        if (draftInputs.equals(oldInputs)) merged = CourseTools.copy(current);
        else if (latestInputs.equals(oldInputs) || draftInputs.equals(latestInputs)) merged = CourseTools.copy(edited);
        else throw conflict();

        // Scheduling fields remain a coherent set; display fields merge independently.
        for (String field : new String[]{"name", "notes", "color"}) {
            String fallback = field.equals("color") ? "blue" : "";
            String old = baseline.optString(field, fallback), draft = edited.optString(field, fallback);
            String latest = current.optString(field, fallback);
            if (draft.equals(old)) merged.put(field, latest);
            else if (latest.equals(old) || latest.equals(draft)) merged.put(field, draft);
            else throw conflict();
        }
        return merged;
    }

    // Low-level merge entry for non-UI callers; interactive forms use Draft to capture history.
    static void save(JSONObject state, JSONObject edited, JSONObject baseline, double now) throws Exception {
        CourseTools.updateCourse(state, resolve(state, edited, baseline), now);
    }
}
