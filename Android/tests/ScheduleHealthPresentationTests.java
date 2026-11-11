package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class ScheduleHealthPresentationTests {
    static int checks;
    static final LocalDate DAY=DailyConsequenceTests.DAY;
    static final double NOW=DailyConsequenceTests.NOW;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static ScheduleHealthPresentation assess(JSONObject state,double now)throws Exception{
        return new ScheduleHealthPresentation(state,ScheduleHealth.assess(state,now,480),480);
    }
    static JSONObject pending(JSONObject state)throws Exception{for(JSONObject t:PlannerTests.sortedTasks(state))if(Planner.pending(t))return t;throw new AssertionError("No pending task");}
    static void confirm(JSONObject state,int minutes,double now)throws Exception{
        Planner.confirm(state,pending(state).getString("id"),minutes,now);Planner.replan(state,now);
    }
    static void reconcile(JSONObject state,ScheduleHealthPresentation p)throws Exception{
        long itemTotal=0,dayTotal=0;
        for(JSONObject day:Planner.list(p.health.getJSONArray("recovery"))){
            long sum=0;for(JSONObject item:Planner.list(p.health.getJSONArray("recoveryItems")))
                if(Planner.day(item.getDouble("start")).equals(Planner.day(day.getDouble("date"))))sum+=item.getLong("minutes");
            check(sum==day.getLong("plannedMinutes"),"Recovery day and detail totals differ");dayTotal+=sum;
        }
        for(JSONObject item:Planner.list(p.health.getJSONArray("recoveryItems"))){
            JSONObject task=null;for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(t.getString("id").equals(item.getString("id")))task=t;
            check(task!=null&&Planner.pending(task),"Recovery detail must reference a pending task");
            check(task.getString("courseID").equals(item.getString("courseID"))&&task.optString("lessonName").equals(item.getString("lessonName")),"Recovery detail lost course/lesson identity");
            check(item.getInt("minutes")>0&&item.getInt("minutes")<=task.getInt("durationMinutes"),"Recovery detail exceeds task");
            itemTotal+=item.getLong("minutes");
        }
        check(itemTotal==dayTotal&&itemTotal==p.recoveryScheduledMinutes,"Recovery totals do not reconcile");
    }
    static void repeatedAndLaterProgress()throws Exception{
        JSONObject state=DailyConsequenceTests.state(120);Planner.replan(state,NOW);
        confirm(state,0,NOW);confirm(state,0,NOW);
        ScheduleHealthPresentation p=assess(state,NOW);
        check(p.health.getInt("reviewedMinutes")==240&&p.recoveryRemainingMinutes==120,"Repeated lesson attempts inflated recovery");reconcile(state,p);
        double later=Planner.at(DAY,540);confirm(state,45,later);later=Planner.at(DAY,600);confirm(state,30,later);
        p=assess(state,later);check(p.recoveryRemainingMinutes==45&&p.recoveryScheduledMinutes==45,"Later progress did not reduce lesson recovery");reconcile(state,p);
        check(p.recoverySummary().contains("天的课表里。按当天课表学习就行"),"Recovery must not request extra study time");
        confirm(state,45,Planner.at(DAY,660));p=assess(state,Planner.at(DAY,660));
        check(p.recoveryRemainingMinutes==0&&p.recoverySummary().contains("没有需要重新安排的未学内容"),"Completed lesson retained recovery debt");
    }
    static void unplacedAndRemovedLessons()throws Exception{
        JSONObject state=DailyConsequenceTests.state(60,60);Planner.replan(state,NOW);
        for(JSONObject task:PlannerTests.sortedTasks(state))Planner.confirm(state,task.getString("id"),0,NOW);
        state.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(2,480,540)));Planner.replan(state,NOW);
        ScheduleHealthPresentation p=assess(state,NOW);
        check(p.recoveryScheduledMinutes==60&&p.health.getLong("recoveryUnscheduledMinutes")==60&&p.recoveryRemainingMinutes==120,"Partial recovery allocation lost unplaced portion");reconcile(state,p);
        state.getJSONObject("settings").put("availability",new JSONArray());Planner.replan(state,NOW);p=assess(state,NOW);
        check(p.recoveryRemainingMinutes==120&&p.recoveryScheduledMinutes==0&&p.recoverySummary().contains("暂时没有安排好学习日期"),"Unplaced recovery confused with no recovery");
        state.getJSONArray("courses").getJSONObject(0).getJSONArray("manualLessons").remove(0);
        state.getJSONArray("courses").getJSONObject(0).put("totalMinutes",60);Planner.replan(state,NOW);p=assess(state,NOW);
        check(p.recoveryRemainingMinutes==60,"Removed lesson left phantom recovery debt");
        state.getJSONArray("courses").getJSONObject(0).put("isArchived",true);Planner.replan(state,NOW);
        check(assess(state,NOW).recoveryRemainingMinutes==0,"Archived course retained recovery debt");
    }
    static void genericRecoveryAndDates()throws Exception{
        JSONObject state=PlannerTests.empty(),course=PlannerTests.course("普通课程",180,DAY,DAY.plusDays(2),60);
        state.getJSONArray("courses").put(course);for(int w=1;w<=7;w++)state.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(w,480,780));
        Planner.replan(state,NOW);List<JSONObject> original=PlannerTests.sortedTasks(state);
        Planner.confirm(state,original.get(0).getString("id"),20,NOW);Planner.confirm(state,original.get(1).getString("id"),0,NOW);Planner.replan(state,NOW);
        ScheduleHealthPresentation p=assess(state,NOW);check(p.recoveryRemainingMinutes==100,"Distinct generic task debts should add");reconcile(state,p);
        String before=state.toString();assess(state,Planner.at(DAY.plusDays(1),480));
        check(before.equals(state.toString()),"Assessment changed stored state");
        check(assess(state,Planner.at(DAY.plusDays(1),480)).recoveryRemainingMinutes==0,"Yesterday's confirmations counted as today's recovery");
    }
    static void courseBreakdown()throws Exception{
        JSONObject state=PlannerTests.empty(),first=PlannerTests.course("同名课程",180,DAY,DAY,60),second=PlannerTests.course("同名课程",300,DAY,DAY.plusDays(1),60);
        JSONObject paused=PlannerTests.course("暂停课程",90,DAY,DAY.plusDays(2),30).put("autoScheduleEnabled",false);
        JSONObject archived=PlannerTests.course("归档课程",180,DAY,DAY,60).put("isArchived",true);
        JSONObject complete=PlannerTests.course("排完课程",60,DAY,DAY,60);
        state.getJSONArray("courses").put(first).put(second).put(paused).put(archived).put(complete);
        state.getJSONArray("tasks").put(Planner.task(first.getString("id"),NOW,120)).put(Planner.task(second.getString("id"),NOW+86400,120))
            .put(Planner.task(paused.getString("id"),NOW,90)).put(Planner.task(complete.getString("id"),NOW,120));
        state.put("androidRisks",new JSONArray().put(new JSONObject().put("unscheduledMinutes",60)).put(new JSONObject().put("unscheduledMinutes",240)));
        List<ScheduleHealthPresentation.CourseAttention> rows=ScheduleHealthPresentation.courses(state,NOW);
        check(rows.size()==3&&rows.get(0).course==first&&rows.get(1).course==second,"Course attention matched names or retained archived/fully placed courses");
        check(rows.get(0).unplacedMinutes==60&&rows.get(1).unplacedMinutes==180,"Course attention summed cumulative risks");
        check(rows.get(2).plannedMinutes==0&&rows.get(2).unplacedMinutes==90,"Paused pending task incorrectly counted as scheduled");
        JSONObject completion=new JSONObject().put("id",Planner.id()).put("courseID",first.getString("id")).put("taskID",Planner.id()).put("minutes",60).put("recordedAt",NOW);
        state.getJSONArray("completions").put(completion);state.getJSONArray("tasks").getJSONObject(0).put("durationMinutes",90);
        rows=ScheduleHealthPresentation.courses(state,NOW);check(rows.get(0).remainingMinutes==120&&rows.get(0).unplacedMinutes==30,"Course attention ignored completed work");
        state.getJSONArray("tasks").getJSONObject(0).put("start",NOW-86400);
        rows=ScheduleHealthPresentation.courses(state,NOW);check(rows.get(0).plannedMinutes==0,"Expired pending task counted as current placement");
    }
    static void dailyLoad()throws Exception{
        JSONObject state=PlannerTests.empty(),health=new JSONObject().put("kind","pending").put("remainingMinutes",600).put("unplacedMinutes",120).put("pausedMinutes",60);
        JSONArray days=new JSONArray();int[] minutes={480,481,600,0};
        for(int i=0;i<minutes.length;i++)days.put(new JSONObject().put("date",Planner.at(DAY.plusDays(i),0)).put("plannedMinutes",minutes[i]).put("availableMinutes",900));state.put("androidDayPlans",days);
        ScheduleHealthPresentation p=new ScheduleHealthPresentation(state,health,480);
        check(p.plannedMinutes()==420,"Overview failed to separate paused and active unplaced work");
        check(p.days.size()==3&&p.heavyDays.size()==2&&p.dailyScale()==600,"Load uses incorrect threshold or scale");
        check(p.loadSummary().contains("有 2 天")&&p.loadSummary().contains("10 小时"),"Load summary missing peak/threshold context");
        check(p.guidance().contains("并不代表一定来不及学完"),"Unplaced work incorrectly presented as impossible");
        p=new ScheduleHealthPresentation(state,health,700);check(p.heavyDays.isEmpty()&&p.dailyScale()==700,"Threshold above peak was not kept on scale");
        check(new ScheduleHealthPresentation(state,health,-1).warningMinutes==30,"Minimum threshold differs from analyzer");
        state.put("androidDayPlans",new JSONArray());check(new ScheduleHealthPresentation(state,health,480).loadSummary().contains("暂时无法评估"),"Empty schedule claims feasible load");
        check(ScheduleHealthPresentation.duration(0).equals("0 分钟")&&ScheduleHealthPresentation.duration(75).equals("1 小时 15 分"),"Minute precision lost");
    }
    public static void main(String[] args)throws Exception{
        repeatedAndLaterProgress();unplacedAndRemovedLessons();genericRecoveryAndDates();courseBreakdown();dailyLoad();
        System.out.println("PASS "+checks+" schedule health presentation, course identity, recovery and daily load checks");
    }
}
