package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Synthetic planner scenarios and an independent exhaustive rest-bound oracle. */
public final class ScheduleRestConflictTests {
    static final LocalDate DAY=LocalDate.of(2026,9,14);
    static final double NOW=Planner.at(DAY,480);
    static int checks;
    static void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    static JSONObject fixture(int end,int... minutes)throws Exception {
        JSONObject s=DailyConsequenceTests.state(minutes);
        s.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(2,480,end)));
        return s;
    }
    static JSONObject course(JSONObject s)throws Exception{return s.getJSONArray("courses").getJSONObject(0);}
    static JSONObject rest(JSONObject s)throws Exception {
        for(JSONObject conflict:Planner.list(s.getJSONArray("androidConflicts")))
            if(conflict.has("restConflict"))return conflict;
        throw new AssertionError("Expected rest proof");
    }
    static JSONObject event(int start,int end,Integer floating)throws Exception {
        return new JSONObject().put("id",Planner.id()).put("title","合成事项").put("startMinute",start).put("endMinute",end)
            .put("startDate",Planner.at(DAY,0)).put("endDate",Planner.at(DAY,0)).put("weekdays",new JSONArray()).put("floatingDurationMinutes",floating);
    }
    static void complete(JSONObject s)throws Exception {
        Planner.replan(s,NOW);
        check(s.getJSONArray("androidConflicts").length()==0,"Feasible plan was called a conflict");
        check(s.getJSONArray("androidRisks").length()==0,"Feasible plan lost study work");
        check(PlannerTests.totalMinutes(s)==120,"Feasible plan changed learning amount");
        List<JSONObject> tasks=PlannerTests.sortedTasks(s);
        for(int i=1;i<tasks.size();i++)check(tasks.get(i).getDouble("start")>=Planner.end(tasks.get(i-1))+15*60,"Rest was lost");
    }
    static void proofAndRecovery()throws Exception {
        JSONObject s=fixture(600,60,60),original=CourseTools.copy(s);
        Planner.replan(s,NOW);JSONObject conflict=rest(s),proof=conflict.getJSONObject("restConflict");
        check(proof.getInt("requiredStudyMinutes")==120&&proof.getInt("minimumRestMinutes")==15&&proof.getInt("availableMinutes")==120,"Wrong rest budget");
        check(!conflict.has("provenDeficit")&&!conflict.has("minimumContinuousMinutes"),"Rest became missing learning or a continuous-gap proof");
        check(PlannerTests.unscheduledMinutes(s)==60,"Unplaced learning is distinct from missing rest");
        check(ScheduleHealth.assess(s,NOW,480).getString("kind").equals("shortage"),"Rest proof not surfaced");
        check(ScheduleRestConflict.explanation(proof).contains("15 分钟休息"),"Missing numerical explanation");
        check(ScheduleRestConflict.recovery().contains("截止日期仍保留"),"Recovery must retain deadline");
        check(s.getJSONArray("courses").similar(original.getJSONArray("courses"))&&s.getJSONArray("completions").length()==0,"Diagnosis modified progress or deadlines");
        s.getJSONObject("settings").getJSONArray("availability").getJSONObject(0).put("endMinute",615);
        complete(s);
        check(s.getJSONArray("courses").similar(original.getJSONArray("courses")),"Recovery changed learning configuration");
        complete(fixture(600,120)); // No trailing rest after the only block.
        complete(fixture(615,60,60));
        s=fixture(600,60);s.getJSONArray("courses").put(PlannerTests.course("普通时间块",60,DAY,DAY,30));
        Planner.replan(s,NOW);conflict=rest(s);
        check(conflict.getJSONObject("restConflict").getInt("minimumRestMinutes")==30&&conflict.getJSONArray("courseNames").length()==2,"Mixed lesson/time-block rest not counted");
    }
    static void eventGapsAndUncertainty()throws Exception {
        for(boolean floating:new boolean[]{false,true}){
            JSONObject s=fixture(615,60,60);s.getJSONArray("fixedEvents").put(event(540,555,floating?15:null));
            complete(s); // A fixed or floating event may occupy the same 15 minutes as rest.
        }
        JSONObject s=fixture(605,60,60);s.getJSONArray("fixedEvents").put(event(540,545,null));
        Planner.replan(s,NOW);
        check(PlannerTests.unscheduledMinutes(s)>0,"Short gap unexpectedly supplied 15 minutes of rest");
        check(s.getJSONArray("androidConflicts").length()==0,"Optimistic bound must not prove a short external gap impossible");
        check(ScheduleHealth.outcome(s,NOW,480).getString("kind").equals("pending"),"Unresolved case reported as proven infeasible");
        s=fixture(615,60,60);s.getJSONArray("fixedEvents").put(event(480,615,30));Planner.replan(s,NOW);
        check(PlannerTests.unscheduledMinutes(s)>0&&s.getJSONArray("androidConflicts").length()==0,"Floating occupancy was charged as mandatory internal rest");
        s=fixture(600,60,60);s.getJSONArray("fixedEvents").put(event(480,600,5));Planner.replan(s,NOW);
        check(rest(s).getJSONObject("restConflict").getInt("availableMinutes")==120,"Rest proof subtracted floating occupancy");
        // A search budget of zero returns no witness, even for a feasible plan.
        JSONObject c=PlannerTests.course("可行但未搜索",60,DAY,DAY,60);
        int base=ScheduleFeasibilitySearch.minute(NOW);
        check(ScheduleFeasibilitySearch.find(Collections.singletonList(new ScheduleFeasibilitySearch.Queue(c,Collections.singletonList(new Planner.Work(60,null,null)))),
            Collections.singletonList(new ScheduleFeasibilitySearch.Window(base,base+60)),Collections.emptyList(),Collections.emptyList(),base,base,0)==null,"Budget exhaustion yielded a partial witness");
        check(ScheduleRestConflict.diagnose(60,1,60,1)==null,"Missing search witness became a proof");
    }
    static void windowsAndDates()throws Exception {
        for(int secondStart:new int[]{520,540}){
            JSONObject s=fixture(540,60,60);s.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(2,secondStart,600));
            Planner.replan(s,NOW);check(rest(s).getJSONObject("restConflict").getInt("minimumRestMinutes")==15,"Adjacent/overlapping windows created extra rest exemptions");
        }
        JSONObject s=fixture(540,60,60);course(s).put("deadline",Planner.at(DAY.plusDays(1),0));
        s.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(3,480,540));complete(s);
        s=fixture(780,60,60);course(s).put("startDate",Planner.at(DAY.plusDays(1),0)).put("deadline",Planner.at(DAY.plusDays(1),0));
        s.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(3,480,600));Planner.replan(s,NOW);
        JSONObject conflict=rest(s);
        check(conflict.getDouble("windowStart")==Planner.at(DAY.plusDays(1),0)&&conflict.getJSONObject("restConflict").getInt("availableMinutes")==120,"Future release hidden behind earlier free time");
        s=fixture(600,60,60);s.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(3,480,780));Planner.replan(s,NOW);
        check(rest(s).getJSONObject("restConflict").getInt("availableMinutes")==120,"Time after the deadline hid a rest conflict");
        s=fixture(600,60,60);course(s).put("autoScheduleEnabled",false);Planner.replan(s,NOW);
        check(s.getJSONArray("androidConflicts").length()==0&&ScheduleHealth.assess(s,NOW,480).getString("kind").equals("pending"),"Paused work was proved impossible");
    }
    static void historySavedPlanAndForecast()throws Exception {
        JSONObject s=fixture(615,60,60);Planner.replan(s,NOW);
        String first=s.getJSONArray("tasks").getJSONObject(0).getString("id");Planner.confirm(s,first,60,Planner.at(DAY,540));
        Planner.replan(s,Planner.at(DAY,540));
        check(s.getJSONArray("androidConflicts").length()==0&&s.getJSONArray("androidRisks").length()==0,"History rest was charged twice");
        check(Planner.remaining(s,course(s))==60,"History progress changed");
        s=fixture(615,60,60);Planner.replan(s,NOW);JSONObject before=CourseTools.copy(s),draft=CourseTools.copy(s);
        Planner.replan(draft,NOW+60);rest(draft);
        Planner.refreshDiagnostics(s,NOW+60);
        check(s.getJSONArray("androidConflicts").length()==0&&s.getJSONArray("androidRisks").length()==0,"Complete saved plan inherited an unapplied draft proof");
        for(String key:new String[]{"courses","tasks","settings","completions"})check(SyncLedger.canonical(s.get(key)).equals(SyncLedger.canonical(before.get(key))),"Refresh mutated saved "+key);
        s=fixture(600,60,60);Planner.replan(s,NOW);Planner.refreshDiagnostics(s,NOW);
        check(rest(s).getJSONObject("restConflict").getInt("minimumRestMinutes")==15,"Refresh dropped a relevant proof");
        s=fixture(600,60,60);course(s).put("startDate",Planner.at(DAY.plusDays(1),0)).put("deadline",Planner.at(DAY.plusDays(1),0));
        s.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(3,480,600)));Planner.replan(s,NOW);
        before=CourseTools.copy(s);JSONObject entry=DailyConsequences.capture(s,s,NOW,480),forecast=DailyConsequences.forecast(entry,0,1),outcome=forecast.getJSONObject("firstDay");
        check(outcome.getString("kind").equals("shortage")&&outcome.getJSONObject("restConflict").getInt("minimumRestMinutes")==15,"Daily forecast lost reason");
        check(!outcome.has("provenDeficit")&&!outcome.has("minimumContinuousMinutes"),"Forecast invented a study deficit");
        check(new JSONObject(forecast.toString()).similar(forecast),"Forecast JSON lost proof");
        check(SyncLedger.canonical(s).equals(SyncLedger.canonical(before)),"Forecast mutated real plan");
    }
    static void oldForecastCache()throws Exception {
        JSONObject s=fixture(615,60,60);Planner.replan(s,NOW);
        JSONObject today=DailyConsequences.capture(s,s,NOW,480);
        today.remove("forecastRevision");today.getJSONArray("forecasts").put(new JSONObject().put("fraction",0).put("firstDay",new JSONObject().put("kind","pending")));
        today.getJSONArray("celebrated").put(0);
        JSONObject yesterday=CourseTools.copy(today);yesterday.put("id",Planner.id()).put("date",Planner.at(DAY.minusDays(1),0));
        JSONObject before=CourseTools.copy(today),old=CourseTools.copy(yesterday),stateBefore=CourseTools.copy(s);
        JSONObject journal=new JSONObject().put("version",1).put("days",new JSONArray().put(yesterday).put(today));
        DailyConsequences.Update update=DailyConsequences.refresh(journal,s,NOW,480,today.getString("id"));
        check(today.getJSONArray("forecasts").length()==0&&today.getInt("forecastRevision")==DailyConsequences.FORECAST_REVISION,"Old current forecast not invalidated");
        for(String key:new String[]{"id","goalMinutes","baseline","capturedAt","capturedRecords","celebrated","plannedToday","revision"})
            check(SyncLedger.canonical(today.get(key)).equals(SyncLedger.canonical(before.get(key))),"Forecast update changed "+key);
        check(update.celebrations.isEmpty(),"Forecast revision repeated celebrations");
        check(SyncLedger.canonical(yesterday).equals(SyncLedger.canonical(old)),"Forecast update rewrote historical report");
        check(SyncLedger.canonical(s).equals(SyncLedger.canonical(stateBefore)),"Forecast update mutated shared state");
        today.getJSONArray("forecasts").put(DailyConsequences.forecast(today,0,1));
        JSONObject reopened=new JSONObject(journal.toString());String saved=SyncLedger.canonical(reopened);
        DailyConsequences.refresh(reopened,s,NOW,480,null);
        check(SyncLedger.canonical(reopened).equals(saved),"Restart discarded already updated forecasts");
    }
    // Earliest feasible placement dominates later starts for each permutation.
    // This oracle has no dependency on the production scheduler or rest bound.
    static boolean canPlace(int[] lengths,int mask,int[][] windows,int after){
        if(mask==(1<<lengths.length)-1)return true;
        for(int i=0;i<lengths.length;i++)if((mask&(1<<i))==0)for(int[] window:windows){
            int start=Math.max(after,window[0]);
            if(start+lengths[i]<=window[1]&&canPlace(lengths,mask|(1<<i),windows,start+lengths[i]+15))return true;
        }
        return false;
    }
    static void independentOracle()throws Exception {
        int feasible=0,proven=0,unresolved=0;
        for(int a:new int[]{15,30,60})for(int b:new int[]{15,30,60})for(int gap:new int[]{5,15,30})
            for(int x:new int[]{15,30,45})for(int y:new int[]{15,30,45})for(int z:new int[]{15,30,45}){
                boolean fits=canPlace(new int[]{x,y,z},0,new int[][]{{0,a},{a+gap,a+gap+b}},0);
                JSONObject proof=ScheduleRestConflict.diagnose(x+y+z,3,a+b,2);
                if(fits){feasible++;check(proof==null,"Rest proof rejected a feasible witness");}
                if(proof!=null){proven++;check(!fits,"Rest proof contradicted independent oracle");}
                if(!fits&&proof==null)unresolved++;
            }
        for(int capacity=60;capacity<=150;capacity++){
            JSONObject proof=ScheduleRestConflict.diagnose(120,2,capacity,1);
            check((proof!=null)==(capacity>=120&&capacity<135),"Single-window proof boundary wrong");
        }
        check(feasible>0&&proven>0&&unresolved>0,"Oracle must cover all three outcomes");
        check(ScheduleRestConflict.diagnose(0,0,0,0)==null,"Empty work reported as conflict");
        JSONObject large=ScheduleRestConflict.diagnose(Integer.MAX_VALUE,200000000,Integer.MAX_VALUE,1);
        check(large.getLong("minimumRestMinutes")==2999999985L,"Rest arithmetic overflowed");
    }
    public static void main(String[] args)throws Exception {
        proofAndRecovery();eventGapsAndUncertainty();windowsAndDates();historySavedPlanAndForecast();oldForecastCache();independentOracle();
        System.out.println("PASS "+checks+" conservative Android rest conflict, recovery, event, deadline, history, saved-plan, forecast and independent-oracle checks");
    }
}
