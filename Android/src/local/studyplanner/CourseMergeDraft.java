package local.studyplanner;

import org.json.*;
import java.util.*;

/** A reviewed selection, checked again against rows read inside the database transaction. */
final class CourseMergeDraft {
    private final Set<String> ids;
    private final String name, signature;
    CourseMergeDraft(JSONObject reviewed,Set<String> selected,String name) throws Exception {
        this.ids=Collections.unmodifiableSet(new HashSet<>(selected));this.name=name.trim();
        int count=0;for(JSONObject course:Planner.list(reviewed.getJSONArray("courses")))
            if(ids.contains(course.getString("id"))&&!course.optBoolean("isArchived"))count++;
        if(ids.size()<2||count!=ids.size()||this.name.isEmpty())
            throw new IllegalArgumentException("请选择至少两门现有课程，并填写合并后的名称。");
        signature=signature(reviewed);
    }
    JSONObject apply(JSONObject current) throws Exception {
        if(!signature.equals(signature(current)))
            throw new IllegalArgumentException("所选课程或学习记录在核对后已有变化，未执行合并。选择和名称仍保留，请点「重新核对课程」后查看最新内容。");
        return CourseTools.merge(current,ids,name);
    }
    private String signature(JSONObject state) throws Exception {
        JSONObject courses=new JSONObject(),tasks=new JSONObject(),records=new JSONObject();Set<String> recorded=new HashSet<>();
        for(JSONObject course:Planner.list(state.getJSONArray("courses")))if(ids.contains(course.optString("id")))courses.put(course.getString("id"),course);
        for(JSONObject record:Planner.list(state.getJSONArray("completions")))if(ids.contains(record.optString("courseID"))){
            records.put(record.getString("id"),record);recorded.add(record.optString("taskID"));
        }
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))
            if(ids.contains(task.optString("courseID"))&&(!Planner.pending(task)||recorded.contains(task.optString("id"))))tasks.put(task.getString("id"),task);
        return SyncLedger.canonical(new JSONObject().put("courses",courses).put("tasks",tasks).put("completions",records));
    }
    static Set<String> availableIDs(JSONObject state) throws Exception {
        Set<String> ids=new HashSet<>();for(JSONObject course:Planner.list(state.getJSONArray("courses")))
            if(!course.optBoolean("isArchived"))ids.add(course.getString("id"));return ids;
    }
    static int retainSelection(Set<String> selected,JSONObject latest) throws Exception {
        int before=selected.size();selected.retainAll(availableIDs(latest));return before-selected.size();
    }
}
