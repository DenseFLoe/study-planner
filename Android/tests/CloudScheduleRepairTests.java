package local.studyplanner;

import org.json.*;
import java.time.LocalDate;

public final class CloudScheduleRepairTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static int booked(JSONObject state){int n=0;for(JSONObject task:Planner.list(state.optJSONArray("tasks")))if(Planner.pending(task))n+=task.optInt("durationMinutes");return n;}
    public static void main(String[] args)throws Exception{
        LocalDate day=LocalDate.of(2026,11,5);double now=Planner.at(day,420);
        JSONObject base=SyncScheduleIntegrityTests.state(now),course=base.getJSONArray("courses").getJSONObject(0);
        course.put("totalMinutes",120).put("minimumBlockMinutes",0).put("startDate",Planner.at(day,0)).put("deadline",Planner.at(day,0));
        base.getJSONObject("settings").put("minimumScheduleUnit",60).put("availability",new JSONArray().put(new JSONObject().put("id",Planner.id()).put("weekday",Planner.weekday(day)).put("startMinute",480).put("endMinute",660)));
        Planner.replan(base,now);
        SyncLedger initial=new SyncLedger();initial.capture(base,1000);
        SyncLedger a=new SyncLedger(CourseTools.copy(initial.value)),b=new SyncLedger(CourseTools.copy(initial.value));
        a.value.put("device","mac");b.value.put("device","phone");
        JSONObject local=CourseTools.copy(base),remote=CourseTools.copy(base);
        local.getJSONObject("settings").put("minimumScheduleUnit",30);Planner.replan(local,now);a.capture(local,2000);
        remote.getJSONObject("settings").getJSONArray("availability").getJSONObject(0).put("startMinute",780).put("endMinute",960);
        Planner.replan(remote,now);b.capture(remote,3000);
        for(boolean reverse:new boolean[]{false,true}){
            SyncLedger ledger=new SyncLedger();ledger.merge((reverse?b:a).changes(0));ledger.merge((reverse?a:b).changes(0));
            check(booked(ledger.materialize())==240,"fixture must reproduce two concurrent plans");
            JSONObject state=SyncExchange.repairMergedSchedule(ledger,now);
            check(booked(state)==120,"cloud repair did not remove duplicate work");
            check(!SyncExchange.invalidPending(state,now),"cloud repair left invalid windows");
            for(JSONObject task:Planner.list(state.getJSONArray("tasks")))check(task.getDouble("start")>=Planner.at(day,780),"task outside winning window");
            long sequence=ledger.sequence();ledger.merge(a.changes(0));ledger.merge(b.changes(0));
            JSONObject repeated=SyncExchange.repairMergedSchedule(ledger,now);
            check(ledger.sequence()==sequence,"repeat download changed legal plan");
            check(SyncLedger.equivalent(state.getJSONArray("tasks"),repeated.getJSONArray("tasks")),"repeat download moved tasks");
            // Old inputs can arrive later under previously unseen task IDs.
            JSONObject late=Planner.task(course.getString("id"),Planner.at(day,480),30);
            repeated.getJSONArray("tasks").put(late);ledger.capture(repeated);
            state=SyncExchange.repairMergedSchedule(ledger,now);
            check(booked(state)==120&&!SyncExchange.invalidPending(state,now),"late stale task survived");
        }
        System.out.println("Cloud schedule repair: "+checks+" checks passed");
    }
}
