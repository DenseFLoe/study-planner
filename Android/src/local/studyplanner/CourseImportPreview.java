package local.studyplanner;

import org.json.*;
import java.util.*;

/** Detached import projection. No database writes or receipt files are produced. */
final class CourseImportPreview {
    final SchedulePreview schedule;
    final String warnings;
    private CourseImportPreview(SchedulePreview schedule, String warnings) {
        this.schedule = schedule; this.warnings = warnings;
    }
    static CourseImportPreview calculate(JSONObject source, CourseImportRequest request, double now) throws Exception {
        BackgroundCancellation.check();
        List<JSONObject> data = request.prepare();
        JSONObject state = CourseTools.copy(source);
        BackgroundCancellation.check();
        WebCourseImport.save(state, data, request.deadline, now);
        BackgroundCancellation.check();
        Planner.replan(state, now);
        BackgroundCancellation.check();
        Set<String> packages = new HashSet<>(), courseIDs = new HashSet<>();
        for (JSONObject snapshot : data) packages.add(WebCourseImport.identity(snapshot));
        for (JSONObject course : Planner.list(state.getJSONArray("courses"))) {
            BackgroundCancellation.check();
            JSONObject web = course.optJSONObject("webCourse");
            if (!course.optBoolean("isArchived") && web != null && packages.contains(WebCourseImport.identity(web)))
                courseIDs.add(course.getString("id"));
        }
        SchedulePreview result = SchedulePreview.fromPlan(state, courseIDs, "导入编排预览", now);
        StringBuilder notes = new StringBuilder();
        JSONArray warnings = state.optJSONArray("androidWarnings");
        if (warnings != null) for (int i = 0; i < warnings.length(); i++) notes.append(warnings.getString(i)).append('\n');
        BackgroundCancellation.check();
        return new CourseImportPreview(result, notes.toString());
    }
}
