package local.studyplanner;
import org.json.*;
import java.time.*;
import java.util.*;

public class FixedOccurrenceTests {
    static final LocalDate DAY=LocalDate.of(2026,9,14);
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    static JSONObject event()throws Exception{
        return new JSONObject().put("id",Planner.id()).put("title","学校").put("startMinute",480).put("endMinute",600)
            .put("startDate",Planner.at(DAY.minusDays(1),0)).put("endDate",Planner.at(DAY.plusDays(3),0))
            .put("weekdays",new JSONArray("[1,2,3,4,5,6,7]"));
    }
    static JSONObject state(int minutes,int unit)throws Exception{
        JSONObject s=PlannerTests.empty();
        s.getJSONArray("courses").put(PlannerTests.course("数学",minutes,DAY,DAY.plusDays(1),unit));
        for(int w=1;w<=7;w++)s.getJSONObject("settings").getJSONArray("availability")
            .put(new JSONObject().put("id",Planner.id()).put("weekday",w).put("startMinute",480).put("endMinute",600));
        return s;
    }
    static void startedToday()throws Exception{
        JSONObject s=state(60,60),e=event();s.getJSONArray("fixedEvents").put(e);
        double now=Planner.at(DAY,510);
        Planner.setEventSkipped(s,e.getString("id"),DAY,true,now);
        check(!Planner.occurs(e,DAY)&&Planner.occurs(e,DAY.minusDays(1))&&Planner.occurs(e,DAY.plusDays(1)),"Skip changed other dates");
        check(s.getJSONArray("fixedEvents").length()==1&&Planner.day(e.getDouble("startDate")).equals(DAY.minusDays(1)),"Skip split rule");
        Planner.replan(s,now);
        check(s.getJSONArray("tasks").getJSONObject(0).getDouble("start")==now,"Started occurrence did not free today");
        PlannerTests.invariant(s,now);
    }
    static void futureAndHistory()throws Exception{
        JSONObject s=state(180,60),e=event(),c=s.getJSONArray("courses").getJSONObject(0);
        s.getJSONArray("fixedEvents").put(e);
        JSONObject history=Planner.task(c.getString("id"),Planner.at(DAY.minusDays(1),480),60),done=Planner.task(c.getString("id"),Planner.at(DAY,360),60);
        s.getJSONArray("tasks").put(history).put(done);Planner.confirm(s,done.getString("id"),60,Planner.at(DAY,420));
        String confirmed=done.toString(),records=s.getJSONArray("completions").toString();
        Planner.replan(s,Planner.at(DAY,420));
        Planner.setEventSkipped(s,e.getString("id"),DAY.plusDays(1),true,Planner.at(DAY,420));
        Planner.replan(s,Planner.at(DAY,420));
        boolean keptHistory=false,keptDone=false,planned=false;
        for(JSONObject t:Planner.list(s.getJSONArray("tasks"))){
            if(t.getString("id").equals(history.getString("id")))keptHistory=true;
            if(t.getString("id").equals(done.getString("id")))keptDone=t.toString().equals(confirmed);
            if(Planner.pending(t)&&Planner.day(t.getDouble("start")).equals(DAY.plusDays(1)))planned=true;
        }
        check(keptHistory&&keptDone&&planned,"History or future replan incorrect");
        check(s.getJSONArray("completions").toString().equals(records),"Progress changed");
        PlannerTests.invariant(s,Planner.at(DAY,420));
    }
    static void moveBackAndRestore()throws Exception{
        JSONObject s=state(60,60),e=event();e.put("startDate",Planner.at(DAY,0)).put("endDate",Planner.at(DAY,0)).put("weekdays",new JSONArray());
        s.getJSONArray("fixedEvents").put(e);double now=Planner.at(DAY,420);
        Planner.replan(s,now);check(Planner.day(s.getJSONArray("tasks").getJSONObject(0).getDouble("start")).equals(DAY.plusDays(1)),"Fixture should use tomorrow");
        Planner.setEventSkipped(s,e.getString("id"),DAY,true,now);Planner.replan(s,now);
        check(s.getJSONArray("tasks").length()==1&&s.getJSONArray("tasks").getJSONObject(0).getDouble("start")==Planner.at(DAY,480),"Future task not replaced by today");
        Planner.setEventSkipped(s,e.getString("id"),DAY,false,now);Planner.replan(s,now);
        check(Planner.occurs(e,DAY)&&Planner.day(s.getJSONArray("tasks").getJSONObject(0).getDouble("start")).equals(DAY.plusDays(1)),"Restore did not replan");
    }
    static void floating()throws Exception{
        JSONObject s=state(120,120),e=event().put("floatingDurationMinutes",60);
        s.getJSONArray("courses").getJSONObject(0).put("deadline",Planner.at(DAY,0));s.getJSONArray("fixedEvents").put(e);
        double now=Planner.at(DAY,420);Planner.replan(s,now);check(s.getJSONArray("tasks").length()==0,"Fixture should not fit");
        Planner.setEventSkipped(s,e.getString("id"),DAY,true,now);Planner.replan(s,now);
        JSONObject t=s.getJSONArray("tasks").getJSONObject(0);
        check(t.getInt("durationMinutes")==120&&!Planner.floatingTask(t),"Floating skip did not free capacity and uncertainty");
    }
    static void invalidAndIdempotent()throws Exception{
        JSONObject s=PlannerTests.empty(),e=event().put("weekdays",new JSONArray("[2]"));s.getJSONArray("fixedEvents").put(e);String original=s.toString();
        for(LocalDate date:Arrays.asList(DAY.minusDays(1),DAY.plusDays(1),DAY.plusDays(4))){
            try{Planner.setEventSkipped(s,e.getString("id"),date,true,Planner.at(DAY,420));throw new AssertionError("Invalid date accepted");}
            catch(IllegalArgumentException expected){}check(s.toString().equals(original),"Invalid skip mutated state");
        }
        try{Planner.setEventSkipped(s,Planner.id(),DAY,true,Planner.at(DAY,420));throw new AssertionError("Unknown ID accepted");}catch(IllegalArgumentException expected){}
        Planner.setEventSkipped(s,e.getString("id"),DAY,true,Planner.at(DAY,420));String skipped=s.toString();
        Planner.setEventSkipped(s,e.getString("id"),DAY,true,Planner.at(DAY,600));check(s.toString().equals(skipped),"Repeated skip not idempotent");
        try{Planner.setEventSkipped(s,e.getString("id"),DAY,false,Planner.at(DAY.plusDays(1),420));throw new AssertionError("Historical restoration accepted");}catch(IllegalArgumentException expected){}
        check(s.toString().equals(skipped),"Historical restoration mutated state");
        JSONObject reopened=new JSONObject(s.toString());check(!Planner.occurs(reopened.getJSONArray("fixedEvents").getJSONObject(0),DAY),"Skip lost on reopen");
    }
    static void restoreConflicts()throws Exception{
        for(boolean floating:new boolean[]{false,true}){
            JSONObject s=PlannerTests.empty(),e=event();if(floating)e.put("floatingDurationMinutes",90);s.getJSONArray("fixedEvents").put(e);
            Planner.setEventSkipped(s,e.getString("id"),DAY,true,Planner.at(DAY,510));
            JSONObject other=new JSONObject(e.toString()).put("id",Planner.id()).put("startDate",Planner.at(DAY,0)).put("endDate",Planner.at(DAY,0)).put("excludedDates",new JSONArray());
            Planner.saveEvent(s,other,Planner.at(DAY,510));String before=s.toString();
            try{Planner.setEventSkipped(s,e.getString("id"),DAY,false,Planner.at(DAY,510));throw new AssertionError("Conflicting restore accepted");}
            catch(Planner.EventConflictException expected){check(expected.conflicts.get(0).date.equals(DAY),"Wrong conflict date");}
            check(s.toString().equals(before),"Conflicting restore mutated state");
            s.getJSONArray("fixedEvents").remove(1);
            other.put("startDate",Planner.at(DAY.plusDays(1),0)).put("endDate",Planner.at(DAY.plusDays(1),0));s.getJSONArray("fixedEvents").put(other);
            Planner.setEventSkipped(s,e.getString("id"),DAY,false,Planner.at(DAY,510));check(Planner.occurs(e,DAY),"Unrelated tomorrow conflict blocked restoration");
        }
    }
    public static void main(String[] args)throws Exception{
        startedToday();futureAndHistory();moveBackAndRestore();floating();invalidAndIdempotent();restoreConflicts();
        System.out.println("PASS per-day removal and restore, started today, future redistribution, history, floating capacity and atomic conflicts");
    }
}
