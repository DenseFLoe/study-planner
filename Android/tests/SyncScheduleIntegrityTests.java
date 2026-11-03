package local.studyplanner;

import org.json.*;
import java.time.*;

/** Merged drafts must obey the current course constraints and retained-history rest. */
public final class SyncScheduleIntegrityTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject state(double now)throws Exception{
        JSONObject state=SyncExchangeTests.fixture(now);
        JSONObject course=state.getJSONArray("courses").getJSONObject(0);
        course.put("totalMinutes",180).put("autoScheduleEnabled",true);
        JSONArray windows=new JSONArray();for(int day=1;day<=7;day++)windows.put(new JSONObject().put("id",Planner.id()).put("weekday",day).put("startMinute",0).put("endMinute",1440));
        state.getJSONObject("settings").put("availability",windows);state.put("tasks",new JSONArray());
        return state;
    }
    static JSONObject confirmedHistoryAndDraft(double now,int gapMinutes,int completed)throws Exception{
        JSONObject state=state(now);String course=state.getJSONArray("courses").getJSONObject(0).getString("id");
        JSONObject history=Planner.task(course,now-3600,60);state.getJSONArray("tasks").put(history);
        Planner.confirm(state,history.getString("id"),completed,now);
        state.getJSONArray("tasks").put(Planner.task(course,now+gapMinutes*60,60));return state;
    }
    static void restBoundaries()throws Exception{
        double now=Planner.at(LocalDate.of(2026,11,3),540);
        for(int gap:new int[]{-5,0,14,15}){
            JSONObject state=confirmedHistoryAndDraft(now,gap,60);
            check(SyncExchange.invalidPending(state,now)==(gap<15),"confirmed history rest boundary incorrect: "+gap);
        }
        JSONObject missed=confirmedHistoryAndDraft(now,0,0);
        check(!SyncExchange.invalidPending(missed,now),"missed task reserved study rest");
        JSONObject ended=confirmedHistoryAndDraft(now,0,0);
        JSONObject oldDraft=ended.getJSONArray("tasks").getJSONObject(0);
        oldDraft.remove("confirmedAt");oldDraft.put("status","planned");
        check(SyncExchange.invalidPending(ended,now),"ended unconfirmed task lost the scheduler's rest boundary");
        ended.getJSONObject("settings").put("actualStudyStart",now);
        check(!SyncExchange.invalidPending(ended,now),"explicit actual start retained obsolete same-day draft rest");
        JSONObject early=confirmedHistoryAndDraft(now,15,60);
        early.getJSONArray("tasks").getJSONObject(0).put("floatingWindowStart",now-3600).put("floatingWindowEnd",now+3600);
        check(!SyncExchange.invalidPending(early,now),"resolved floating window blocked valid rest boundary");
        JSONObject adjacent=state(now);String id=adjacent.getJSONArray("courses").getJSONObject(0).getString("id");
        JSONObject first=Planner.task(id,now,30),second=Planner.task(id,now+44*60,30);
        adjacent.getJSONArray("tasks").put(first).put(second);
        check(SyncExchange.invalidPending(adjacent,now),"adjacent pending tasks lost rest");
        second.put("start",now+45*60);check(!SyncExchange.invalidPending(adjacent,now),"exact pending rest boundary rejected");
        double midnight=Planner.at(LocalDate.of(2026,11,4),0);
        JSONObject crossDay=confirmedHistoryAndDraft(midnight-5*60,10,30);
        check(SyncExchange.invalidPending(crossDay,midnight),"history rest was lost across midnight");
    }
    static void offlineConfirmationReplan()throws Exception{
        LocalDate day=LocalDate.of(2026,11,3);double initialTime=Planner.at(day,470),syncTime=Planner.at(day,540);
        JSONObject state=state(initialTime),course=state.getJSONArray("courses").getJSONObject(0);
        course.put("startDate",Planner.at(day,0)).put("deadline",Planner.at(day,0));
        state.getJSONObject("settings").put("availability",new JSONArray().put(new JSONObject().put("id",Planner.id()).put("weekday",Planner.weekday(day)).put("startMinute",480).put("endMinute",660)));
        Planner.replan(state,initialTime);String oldID=state.getJSONArray("tasks").getJSONObject(0).getString("id");
        SyncLedger base=new SyncLedger();base.capture(state,1000);
        SyncLedger mac=new SyncLedger(CourseTools.copy(base.value)),phone=new SyncLedger(CourseTools.copy(base.value));
        mac.value.put("device","MAC");phone.value.put("device","PHONE");
        JSONObject edited=mac.materialize();Planner.replan(edited,Planner.at(day,535));mac.capture(edited,2000);
        JSONObject confirmed=phone.materialize();Planner.confirm(confirmed,oldID,60,syncTime);phone.capture(confirmed,3000);
        exchange(mac,phone,day,syncTime);
        JSONObject merged=mac.materialize();int pending=0;
        for(JSONObject task:Planner.list(merged.getJSONArray("tasks")))if(Planner.pending(task)&&Planner.end(task)>syncTime){
            pending++;check(task.getDouble("start")>=syncTime+Planner.BREAK_SECONDS,"offline confirmation overlaps replacement draft or its rest");
        }
        check(pending>0,"repair discarded all feasible work");
        check(merged.getJSONArray("completions").length()==1&&merged.getJSONArray("completions").getJSONObject(0).getInt("minutes")==60,"repair changed confirmed progress");
        check(Planner.remaining(merged,merged.getJSONArray("courses").getJSONObject(0))==120,"repair lost unfinished work");
        long sequence=mac.sequence();exchange(mac,phone,day,syncTime);
        check(mac.sequence()==sequence,"repeated sync regenerated an already valid schedule");
    }
    static void exchange(SyncLedger local,SyncLedger remote,LocalDate day,double now)throws Exception{
        SyncExchange.apply(local,consumer->{
            for(JSONObject row:Planner.list(remote.changes(0)))consumer.accept(row);
            return new JSONObject().put("protocol",1).put("cursor",0).put("automatic",false).put("date",day.toString());
        },now);
    }
    static void offlineScheduleAfterCourseEdit()throws Exception{
        LocalDate monday=LocalDate.of(2026,11,2),tuesday=monday.plusDays(1),wednesday=monday.plusDays(2);
        double syncTime=Planner.at(tuesday,495);
        JSONObject initial=state(Planner.at(monday,420));
        initial.getJSONArray("courses").getJSONObject(0).put("totalMinutes",60)
            .put("startDate",Planner.at(monday,0)).put("deadline",Planner.at(wednesday,0));
        initial.getJSONObject("settings").put("availability",new JSONArray().put(new JSONObject().put("id",Planner.id())
            .put("weekday",Planner.weekday(tuesday)).put("startMinute",480).put("endMinute",600)));
        Planner.replan(initial,Planner.at(monday,420));SyncLedger base=new SyncLedger();base.capture(initial,1000);
        for(String edit:new String[]{"pause","start","deadline"}){
            SyncLedger local=new SyncLedger(CourseTools.copy(base.value)),offline=new SyncLedger(CourseTools.copy(base.value));
            JSONObject changed=local.materialize(),course=changed.getJSONArray("courses").getJSONObject(0);
            if(edit.equals("pause"))course.put("autoScheduleEnabled",false);
            else course.put(edit.equals("start")?"startDate":"deadline",Planner.at(edit.equals("start")?wednesday:monday,0));
            Planner.replan(changed,Planner.at(monday,480));local.capture(changed,2000);
            check(changed.getJSONArray("tasks").length()==0,"course edit fixture still has a feasible task");
            JSONObject stale=offline.materialize();Planner.replan(stale,syncTime);offline.capture(stale,3000);
            check(stale.getJSONArray("tasks").length()==1,"offline fixture did not create a later draft");
            exchange(local,offline,tuesday,syncTime);JSONObject merged=local.materialize();
            check(SyncLedger.equivalent(merged.getJSONArray("courses").getJSONObject(0),course),"stale course row replaced newer "+edit);
            check(merged.getJSONArray("tasks").length()==0,"offline task bypassed newer course "+edit);
            check(Planner.remaining(merged,merged.getJSONArray("courses").getJSONObject(0))==60,"course constraint repair discarded unfinished work");
            long sequence=local.sequence();exchange(local,offline,tuesday,syncTime);
            check(local.sequence()==sequence,"retry recreated rejected stale course task");
        }
        JSONObject history=confirmedHistoryAndDraft(syncTime,15,60);
        history.getJSONArray("courses").getJSONObject(0).put("autoScheduleEnabled",false);
        history.getJSONArray("tasks").remove(1);
        check(!SyncExchange.invalidPending(history,syncTime),"paused course invalidated confirmed history");
    }
    public static void main(String[] args)throws Exception{
        restBoundaries();offlineConfirmationReplan();offlineScheduleAfterCourseEdit();
        System.out.println("PASS "+checks+" sync schedule checks: offline confirmations, stale course drafts, retained history, floating windows and cross-day rest");
    }
}
