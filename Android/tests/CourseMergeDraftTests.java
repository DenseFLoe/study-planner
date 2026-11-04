package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class CourseMergeDraftTests {
    static int checks;
    static final LocalDate DAY=LocalDate.of(2026,11,4);
    static final double NOW=Planner.at(DAY,600);
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject fixture() throws Exception {
        JSONObject state=PlannerTests.empty();
        for(String name:new String[]{"来源 A","来源 B","其他课程"})state.getJSONArray("courses").put(PlannerTests.course(name,60,DAY,DAY.plusDays(1),30));
        state.getJSONArray("tasks").put(Planner.task(state.getJSONArray("courses").getJSONObject(0).getString("id"),NOW-3600,30));
        return state;
    }
    static Set<String> ids(JSONObject state) throws Exception {
        return new HashSet<>(Arrays.asList(state.getJSONArray("courses").getJSONObject(0).getString("id"),state.getJSONArray("courses").getJSONObject(1).getString("id")));
    }
    static void reject(CourseMergeDraft draft,JSONObject latest) throws Exception {
        String before=SyncLedger.canonical(latest);
        try{draft.apply(latest);throw new AssertionError("Changed merge review accepted");}
        catch(IllegalArgumentException expected){check(expected.getMessage().contains("核对"),"Conflict is not actionable");}
        check(before.equals(SyncLedger.canonical(latest)),"Rejected merge changed source data");
    }
    public static void main(String[] args) throws Exception {
        JSONObject original=fixture();Set<String> selected=ids(original);
        CourseMergeDraft draft=new CourseMergeDraft(original,selected," 合并名称 ");selected.clear();
        JSONObject latest=CourseTools.copy(original);latest.getJSONArray("courses").getJSONObject(2).put("notes","同步的备注");
        latest.getJSONArray("tasks").getJSONObject(0).put("start",NOW-1800);
        JSONObject merged=draft.apply(latest);
        check(merged.getString("name").equals("合并名称")&&merged.getInt("totalMinutes")==120,"Selection/name changed after capture");
        check(latest.getJSONArray("tasks").getJSONObject(0).getDouble("start")==NOW-1800,"Latest pending plan overwritten");
        check(Planner.course(latest,original.getJSONArray("courses").getJSONObject(2).getString("id")).getString("notes").equals("同步的备注"),"Unrelated course edit lost");
        for(int minutes:new int[]{0,20,30}){
            latest=CourseTools.copy(original);Planner.confirm(latest,latest.getJSONArray("tasks").getJSONObject(0).getString("id"),minutes,NOW);
            reject(draft,latest);CourseMergeDraft fresh=new CourseMergeDraft(latest,ids(original),"合并名称");
            merged=fresh.apply(latest);
            check(Planner.completed(latest,merged)==minutes,"Fresh review lost completion credit");
            check(latest.getJSONArray("completions").getJSONObject(0).getString("courseID").equals(merged.getString("id")),"Record owner was not migrated");
        }
        for(String key:new String[]{"name","deadline","isArchived"}){
            latest=CourseTools.copy(original);JSONObject course=latest.getJSONArray("courses").getJSONObject(0);
            if(key.equals("name"))course.put(key,"同步后名称");else if(key.equals("deadline"))course.put(key,NOW+86400*3);else course.put(key,true);
            reject(draft,latest);
        }
        latest=CourseTools.copy(original);latest.getJSONArray("courses").remove(0);reject(draft,latest);
        latest=CourseTools.copy(original);JSONArray courses=latest.getJSONArray("courses");latest.put("courses",new JSONArray().put(courses.get(2)).put(courses.get(1)).put(courses.get(0)));
        check(draft.apply(latest).getInt("totalMinutes")==120,"Array reordering invalidated the same review");
        selected=ids(original);latest=CourseTools.copy(original);latest.getJSONArray("courses").getJSONObject(0).put("isArchived",true);
        String before=SyncLedger.canonical(latest);check(CourseMergeDraft.retainSelection(selected,latest)==1&&selected.size()==1,"Refresh did not remove only missing selections");
        check(selected.contains(original.getJSONArray("courses").getJSONObject(1).getString("id")),"Refresh lost a surviving selection");
        check(CourseMergeDraft.retainSelection(selected,latest)==0&&before.equals(SyncLedger.canonical(latest)),"Refresh changed data or repeatedly dropped selections");
        try{new CourseMergeDraft(original,selected,"合并");throw new AssertionError("One source accepted");}catch(IllegalArgumentException expected){checks++;}
        try{new CourseMergeDraft(original,ids(original)," ");throw new AssertionError("Blank name accepted");}catch(IllegalArgumentException expected){checks++;}
        System.out.println("PASS "+checks+" merge review, refresh and progress preservation checks");
    }
}
