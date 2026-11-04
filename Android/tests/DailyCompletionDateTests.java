package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Historical study dates stay conservative while bulk reads index task history once. */
public final class DailyCompletionDateTests {
    static final LocalDate DAY=LocalDate.of(2026,11,4);
    static final double NOW=Planner.at(DAY,480);
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static final class CountedTasks extends JSONArray {
        int reads;
        @Override public JSONObject optJSONObject(int index){reads++;return super.optJSONObject(index);}
    }
    static JSONObject task(String id,double start)throws Exception{return new JSONObject().put("id",id).put("courseID","course").put("start",start).put("durationMinutes",1).put("completedMinutes",1).put("confirmedAt",start).put("status","completed");}
    static JSONObject record(String id,double recorded)throws Exception{return new JSONObject().put("id","record-"+id).put("taskID",id).put("courseID","course").put("minutes",1).put("recordedAt",recorded);}
    static void dateSemantics()throws Exception{
        JSONObject legacy=record("one",NOW),matching=task("one",NOW),other=task("other",NOW);
        check(DailyConsequences.effectiveDayWithTask(legacy,matching).equals(DAY),"Same-day legacy record lost attribution");
        check(DailyConsequences.effectiveDayWithTask(legacy,other)==null,"An unrelated task assigned a legacy study date");
        check(DailyConsequences.effectiveDayWithTask(legacy,null)==null,"Orphan legacy record gained a guessed date");
        check(DailyConsequences.effectiveDayWithTask(legacy,task("one",NOW-86400))==null,"Ambiguous backfill used the confirmation day");
        legacy.put("studyDate",JSONObject.NULL);
        check(DailyConsequences.effectiveDayWithTask(legacy,matching).equals(DAY),"Null legacy date differs from missing date");
        legacy.put("studyDate",Planner.at(DAY.minusDays(1),0));
        check(DailyConsequences.effectiveDayWithTask(legacy,other).equals(DAY.minusDays(1)),"Explicit actual date lost priority");
        check(DailyConsequences.effectiveDayWithTask(legacy,null).equals(DAY.minusDays(1)),"Explicit date requires live task history");
    }
    static void bulkReadCost()throws Exception{
        JSONObject state=PlannerTests.empty();CountedTasks tasks=new CountedTasks();JSONArray records=new JSONArray();
        int count=10_000;for(int i=0;i<count;i++){String id="task-"+i;tasks.put(task(id,NOW));records.put(record(id,NOW).put("studyDate",JSONObject.NULL));}
        state.put("tasks",tasks).put("completions",records);String before=SyncLedger.canonical(state);tasks.reads=0;
        check(DailyConsequences.confirmed(DAY,state)==count,"Large history lost confirmed minutes");
        check(tasks.reads<=count,"Bulk daily total repeatedly rescanned task history: "+tasks.reads);
        tasks.reads=0;check(DailyConsequences.usesLegacyDates(DAY,state),"Null legacy dates omitted the user-facing warning");
        check(tasks.reads<=count,"Legacy-date notice repeatedly rescanned task history");
        for(JSONObject r:Planner.list(records))r.put("studyDate",Planner.at(DAY,0));tasks.reads=0;
        check(DailyConsequences.confirmed(DAY,state)==count&&!DailyConsequences.usesLegacyDates(DAY,state),"Explicit records counted as legacy");
        check(tasks.reads==0,"Explicit actual dates needlessly traversed task history");
        for(JSONObject r:Planner.list(records))r.put("studyDate",JSONObject.NULL);
        check(before.equals(SyncLedger.canonical(state)),"Reading daily totals or notice mutated source records");
    }
    static void firstMatchAndAmbiguity()throws Exception{
        JSONObject state=PlannerTests.empty();JSONObject legacy=record("shared",NOW);
        state.getJSONArray("tasks").put(task("shared",NOW-86400)).put(task("shared",NOW));
        state.getJSONArray("completions").put(legacy);
        check(DailyConsequences.confirmed(DAY,state)==0&&!DailyConsequences.usesLegacyDates(DAY,state),"Index changed the existing first-match policy");
        state.getJSONArray("tasks").remove(0);
        check(DailyConsequences.confirmed(DAY,state)==1&&DailyConsequences.usesLegacyDates(DAY,state),"Matching unambiguous record stayed hidden");
        check(!DailyConsequences.usesLegacyDates(DAY.plusDays(1),state),"Legacy notice leaked into another date");
        JSONObject explicit=record("missing",NOW).put("studyDate",Planner.at(DAY.minusDays(1),0)).put("minutes",10);state.getJSONArray("completions").put(explicit);
        check(DailyConsequences.confirmed(DAY.minusDays(1),state)==10&&!DailyConsequences.usesLegacyDates(DAY.minusDays(1),state),"Dated orphan changed totals or generated a legacy warning");
    }
    public static void main(String[]args)throws Exception{dateSemantics();bulkReadCost();firstMatchAndAmbiguity();System.out.println("Daily completion dates: "+checks+" checks passed");}
}
