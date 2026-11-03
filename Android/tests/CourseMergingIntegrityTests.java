package local.studyplanner;

import org.json.*;
import java.util.*;

public final class CourseMergingIntegrityTests {
    static int checks;
    static final double NOW=800_000_000;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject fixture(int[] totals,int[] baselines)throws Exception{
        JSONObject state=SyncExchangeTests.initial(),template=SyncExchangeTests.fixture(NOW).getJSONArray("courses").getJSONObject(0);
        for(int i=0;i<totals.length;i++)state.getJSONArray("courses").put(CourseTools.copy(template).put("id",Planner.id()).put("name","Course "+i).put("totalMinutes",totals[i]).put("initialCompletedMinutes",baselines[i]));
        JSONObject task=Planner.task(state.getJSONArray("courses").getJSONObject(totals.length-1).getString("id"),NOW,60);state.getJSONArray("tasks").put(task);
        Planner.confirm(state,task.getString("id"),20,NOW);return state;
    }
    static Set<String> ids(JSONObject state)throws Exception{Set<String> ids=new HashSet<>();for(JSONObject c:Planner.list(state.getJSONArray("courses")))ids.add(c.getString("id"));return ids;}
    static void overflow()throws Exception{
        JSONObject[] inputs={fixture(new int[]{Integer.MAX_VALUE,Integer.MAX_VALUE,122},new int[]{0,0,0}),fixture(new int[]{60,60},new int[]{Integer.MAX_VALUE,1}),fixture(new int[]{60,60},new int[]{Integer.MIN_VALUE,-1})};
        for(JSONObject state:inputs){String before=state.toString();boolean rejected=false;
            try{CourseTools.merge(state,ids(state),"Merged");}catch(IllegalArgumentException expected){rejected=true;}
            check(rejected,"merge accepted overflowing course totals or baselines");check(before.equals(state.toString()),"overflowing merge changed courses/tasks/completions");
        }
    }
    static void limit()throws Exception{
        JSONObject state=fixture(new int[]{300000,300000},new int[]{10,20});String taskID=state.getJSONArray("tasks").getJSONObject(0).getString("id");
        JSONObject merged=CourseTools.merge(state,ids(state),"At limit");
        check(merged.getInt("totalMinutes")==600000,"existing maximum total was not retained");check(merged.getInt("initialCompletedMinutes")==30,"baseline sum changed");
        check(Planner.completed(state,merged)==50,"merge at boundary lost progress");check(state.getJSONArray("tasks").getJSONObject(0).getString("id").equals(taskID),"merge changed task identity");
        check(state.getJSONArray("tasks").getJSONObject(0).getString("courseID").equals(merged.getString("id")),"task was not reparented");
        check(state.getJSONArray("completions").getJSONObject(0).getString("courseID").equals(merged.getString("id")),"completion was not reparented");
        state=fixture(new int[]{300000,300001},new int[]{0,0});String before=state.toString();boolean rejected=false;
        try{CourseTools.merge(state,ids(state),"Over limit");}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,"existing total upper limit changed");check(before.equals(state.toString()),"over-limit merge mutated input");
    }
    static void nested()throws Exception{
        JSONObject state=fixture(new int[]{60,60,60},new int[]{10,0,0});JSONArray courses=state.getJSONArray("courses");String firstID=courses.getJSONObject(0).getString("id"),secondID=courses.getJSONObject(1).getString("id"),thirdID=courses.getJSONObject(2).getString("id");
        String taskID=state.getJSONArray("tasks").getJSONObject(0).getString("id");
        JSONObject first=CourseTools.merge(state,new HashSet<>(Arrays.asList(firstID,thirdID)),"First merge");
        JSONObject merged=CourseTools.merge(state,new HashSet<>(Arrays.asList(first.getString("id"),secondID)),"Nested merge");
        check(merged.getInt("totalMinutes")==180&&merged.getInt("initialCompletedMinutes")==10,"nested merge totals changed");
        check(Planner.completed(state,merged)==30&&Planner.remaining(state,merged)==150,"nested merge progress changed");
        JSONObject task=state.getJSONArray("tasks").getJSONObject(0);check(task.getString("id").equals(taskID),"nested merge changed task ID");
        check(task.getString("lessonID").equals(first.getString("id")+"/"+thirdID+"/whole"),"nested merge lost source prefix");
        check(state.getJSONArray("completions").getJSONObject(0).getString("courseID").equals(merged.getString("id")),"nested merge lost completion owner");
        SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize();check(Planner.completed(restored,Planner.course(restored,merged.getString("id")))==30,"nested merge progress changed on sync roundtrip");
    }
    public static void main(String[] args)throws Exception{overflow();limit();nested();System.out.println("Course merging integrity checks passed: "+checks);}
}
