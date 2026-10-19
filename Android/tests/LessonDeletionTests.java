package local.studyplanner;

import org.json.*;
import java.time.*;
import java.util.*;

public final class LessonDeletionTests {
    static int checks;
    static final LocalDate DAY=LocalDate.of(2026,10,19);
    static final double NOW=Planner.at(DAY,480),DEADLINE=Planner.at(DAY.plusDays(7),0);
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject fixture()throws Exception {
        JSONObject state=PlannerTests.empty(),course=PlannerTests.course("部分删除",180,DAY,DAY.plusDays(7),60);
        JSONArray lessons=new JSONArray();for(String id:new String[]{"a","b","c"})lessons.put(new JSONObject().put("id",id).put("name",id).put("durationMinutes",60));
        course.put("type","不定时录播课程").put("manualLessons",lessons).put("initialCompletedMinutes",70).put("lessonOrder",new JSONArray().put("c").put("a").put("b"));state.getJSONArray("courses").put(course);
        for(String id:new String[]{"a","b","c"}){JSONObject task=Planner.task(course.getString("id"),NOW,60).put("lessonID",id);state.getJSONArray("tasks").put(task);if(!id.equals("a"))Planner.confirm(state,task.getString("id"),20,NOW+1);}
        return state;
    }
    static void manual()throws Exception {
        JSONObject state=fixture(),course=state.getJSONArray("courses").getJSONObject(0);String id=course.getString("id");
        CourseTools.removeLessons(state,id,new HashSet<>(Arrays.asList("a","c")));course=Planner.course(state,id);
        check(course.getInt("totalMinutes")==60&&course.getInt("initialCompletedMinutes")==10,"Manual baseline/total changed incorrectly");
        check(Planner.lessonWorkAll(state,course).get(0).minutes==30,"Retained lesson progress lost");
        check(state.getJSONArray("tasks").length()==1&&state.getJSONArray("completions").length()==1,"Deleted lesson history survived");
        check(CourseTools.order(course).equals(Collections.singletonList("b")),"Deleted lesson order survived");
        Planner.replan(state,NOW);Planner.validate(state);for(JSONObject task:Planner.list(state.getJSONArray("tasks")))check(task.optString("lessonID").equals("b"),"Replan restored removed lesson");
    }
    static void rejected()throws Exception {
        JSONObject state=fixture();String id=state.getJSONArray("courses").getJSONObject(0).getString("id");
        for(Set<String> ids:Arrays.asList(Collections.<String>emptySet(),Collections.singleton("missing"),new HashSet<>(Arrays.asList("a","b","c")))){
            String before=state.toString();try{CourseTools.removeLessons(state,id,ids);throw new AssertionError("Invalid deletion accepted");}catch(IllegalArgumentException expected){check(before.equals(state.toString()),"Rejected deletion changed state");}
        }
        state.getJSONArray("tasks").getJSONObject(1).remove("lessonID");String before=state.toString();try{CourseTools.removeLessons(state,id,Collections.singleton("a"));throw new AssertionError("Legacy ambiguous records accepted");}catch(IllegalArgumentException expected){check(before.equals(state.toString()),"Legacy rejection changed state");}
    }
    static JSONObject snapshot(double fetched,String... ids)throws Exception {
        JSONArray lessons=new JSONArray();for(String id:ids)lessons.put(ImportParityTests.lesson(id,3600,id.equals("b")?50:0));
        return ImportParityTests.snapshot(0,0,fetched).put("lessons",lessons);
    }
    static void website()throws Exception {
        JSONObject state=PlannerTests.empty();WebCourseImport.save(state,Collections.singletonList(snapshot(NOW,"a","b","c")),DEADLINE,NOW);String id=state.getJSONArray("courses").getJSONObject(0).getString("id");
        for(String lesson:new String[]{"a","b"}){JSONObject task=Planner.task(id,NOW,20).put("lessonID",lesson);state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),20,NOW+1);}
        CourseTools.removeLessons(state,id,Collections.singleton("a"));JSONObject course=Planner.course(state,id);
        check(course.getInt("totalMinutes")==120&&Planner.lessonWorkAll(state,course).get(0).minutes==10,"Website deletion lost retained progress");
        WebCourseImport.save(state,Collections.singletonList(snapshot(NOW+2,"a","b","c","d")),DEADLINE,NOW+2);course=Planner.course(state,id);
        check(CourseTools.order(course).equals(Arrays.asList("b","c","d")),"Website refresh restored deleted lesson");check(Planner.lessonWorkAll(state,course).get(0).minutes==10,"Refresh erased independent progress");
        Planner.undoConfirmation(state,state.getJSONArray("tasks").getJSONObject(0).getString("id"),NOW+3);check(Planner.lessonWorkAll(state,Planner.course(state,id)).get(0).minutes==30,"Undo erased website baseline");
    }
    static void merged()throws Exception {
        JSONObject state=fixture(),a=state.getJSONArray("courses").getJSONObject(0),b=PlannerTests.course("整门来源",45,DAY,DAY.plusDays(7),45);state.getJSONArray("courses").put(b);
        JSONObject first=CourseTools.merge(state,new HashSet<>(Arrays.asList(a.getString("id"),b.getString("id"))),"第一组合"),c=PlannerTests.course("保留来源",30,DAY,DAY.plusDays(7),30);state.getJSONArray("courses").put(c);
        JSONObject merged=CourseTools.merge(state,new HashSet<>(Arrays.asList(first.getString("id"),c.getString("id"))),"嵌套组合");String prefix=first.getString("id")+"/";
        CourseTools.removeLessons(state,merged.getString("id"),new HashSet<>(Arrays.asList(prefix+b.getString("id")+"/whole",prefix+a.getString("id")+"/a")));merged=Planner.course(state,merged.getString("id"));
        check(merged.getInt("totalMinutes")==150&&merged.getInt("initialCompletedMinutes")==10,"Merged deletion total/baseline incorrect");
        check(CourseTools.order(merged).size()==3,"Merged deletion lost source boundaries");check(Planner.remaining(state,merged)==100,"Merged retained progress changed");
    }
    static void mergeAfterDeletion()throws Exception {
        JSONObject state=fixture();String sourceID=state.getJSONArray("courses").getJSONObject(0).getString("id");CourseTools.removeLessons(state,sourceID,Collections.singleton("a"));JSONObject other=PlannerTests.course("新来源",30,DAY,DAY.plusDays(7),30);state.getJSONArray("courses").put(other);
        JSONObject merged=CourseTools.merge(state,new HashSet<>(Arrays.asList(sourceID,other.getString("id"))),"后续合并"),task=Planner.task(merged.getString("id"),NOW,30).put("lessonID",sourceID+"/a");state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),10,NOW+1);SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize();
        for(JSONObject t:Planner.list(restored.getJSONArray("tasks")))check(!t.optString("id").equals(task.getString("id")),"Later merge lost deletion markers");for(JSONObject r:Planner.list(restored.getJSONArray("completions")))check(!r.optString("taskID").equals(task.getString("id")),"Later merge restored deleted history");
    }
    static void offline()throws Exception {
        JSONObject state=fixture();String id=state.getJSONArray("courses").getJSONObject(0).getString("id");SyncLedger mac=new SyncLedger(),phone=new SyncLedger();mac.capture(state);phone.merge(mac.changes(0));JSONObject other=phone.materialize();JSONObject task=null;for(JSONObject t:Planner.list(other.getJSONArray("tasks")))if(t.optString("lessonID").equals("a"))task=t;
        Planner.confirm(other,task.getString("id"),10,NOW+1);phone.capture(other);CourseTools.removeLessons(state,id,Collections.singleton("a"));mac.capture(state);JSONArray local=mac.changes(0),remote=phone.changes(0);mac.merge(remote);phone.merge(local);JSONObject result=mac.materialize();
        check(SyncLedger.canonical(result).equals(SyncLedger.canonical(phone.materialize())),"Peers diverged after lesson deletion");for(JSONObject t:Planner.list(result.getJSONArray("tasks")))check(!t.optString("lessonID").equals("a"),"Offline confirmation restored task");for(JSONObject r:Planner.list(result.getJSONArray("completions")))check(!r.optString("taskID").equals(task.getString("id")),"Offline confirmation restored history");
    }
    public static void main(String[] args)throws Exception {manual();rejected();website();merged();mergeAfterDeletion();offline();System.out.println("LessonDeletionTests: "+checks+" checks passed");}
}
