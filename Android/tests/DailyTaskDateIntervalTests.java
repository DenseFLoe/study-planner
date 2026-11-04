package local.studyplanner;

import org.json.*;
import java.io.*;
import java.time.*;
import java.util.*;

public final class DailyTaskDateIntervalTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject fixture(LocalDate day,int duration)throws Exception{
        JSONObject state=PlannerTests.empty(),course=PlannerTests.course("Synthetic civil day",duration,day,day,60);
        state.getJSONArray("courses").put(course);
        state.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(Planner.weekday(day),0,1440)));
        state.getJSONArray("tasks").put(Planner.task(course.getString("id"),Planner.at(day,0),duration));return state;
    }
    static JSONObject roundTrip(JSONObject state)throws Exception{
        SyncLedger ledger=new SyncLedger();ledger.capture(state);ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));return ledger.materialize();
    }
    static void historicalDayBoundaries()throws Exception{
        // Use Planner's real fixed Asia/Shanghai rules; do not substitute New York.
        check(Planner.ZONE.equals(ZoneId.of("Asia/Shanghai")),"Fixture changed production timezone");
        LocalDate shortDay=LocalDate.of(1991,4,14),ordinary=LocalDate.of(2026,11,3),longDay=LocalDate.of(1991,9,15);
        check(Planner.at(shortDay.plusDays(1),0)-Planner.at(shortDay,0)==1380*60,"Short-day fixture is not 23 hours");
        check(Planner.at(longDay.plusDays(1),0)-Planner.at(longDay,0)==1500*60,"Long-day fixture is not 25 hours");
        for(LocalDate day:new LocalDate[]{shortDay,ordinary,longDay})for(int duration:new int[]{1380,1440}){
            JSONObject state=roundTrip(fixture(day,duration));String before=state.toString();
            List<JSONObject> tasks=PlannerTests.sortedTasks(state),placed=DailyTaskOrdering.place(state,tasks,Planner.at(day,0));
            if(day.equals(shortDay)&&duration==1440)check(placed==null,"Short-day task crossed actual midnight");
            else{
                check(placed!=null&&placed.size()==1,"Physically legal daily boundary rejected");
                check(SyncLedger.equivalent(placed.get(0),tasks.get(0)),"Boundary placement changed task data");
                check(Planner.end(placed.get(0))==Planner.at(day,duration),"Planner.at elapsed-minute semantics changed");
                check(Planner.end(placed.get(0))<=Planner.at(day.plusDays(1),0),"Accepted task crosses next midnight");
            }
            check(before.equals(state.toString()),"Daily boundary reader mutated input");
        }
        JSONObject state=fixture(longDay,1441);
        check(DailyTaskOrdering.place(state,PlannerTests.sortedTasks(state),Planner.at(longDay,0))==null,"Long-day guard expanded the existing minute-index search limit");
    }
    static void shortDayFloatingMetadata()throws Exception{
        LocalDate day=LocalDate.of(1991,4,14);JSONObject state=fixture(day,60);
        state.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.id()).put("title","Floating hour")
            .put("startMinute",0).put("endMinute",1440).put("floatingDurationMinutes",60).put("startDate",Planner.at(day,0))
            .put("endDate",Planner.at(day,0)).put("weekdays",new JSONArray()).put("excludedDates",new JSONArray()).put("color","blue").put("notes",""));
        state=roundTrip(state);String before=state.toString();List<JSONObject> tasks=PlannerTests.sortedTasks(state),placed=DailyTaskOrdering.place(state,tasks,Planner.at(day,0));
        check(placed!=null&&placed.size()==1,"Short-day task with a floating window was rejected");
        JSONObject task=placed.get(0);check(task.getString("id").equals(tasks.get(0).getString("id"))&&task.getInt("durationMinutes")==60,"Floating placement changed task identity or duration");
        check(task.getDouble("floatingWindowStart")<=task.getDouble("start"),"Floating window starts after its task");
        check(task.getDouble("floatingWindowEnd")==Planner.at(day.plusDays(1),0),"Floating planning window crossed actual midnight");
        check(Planner.end(task)<=task.getDouble("floatingWindowEnd"),"Floating planning window failed to enclose task");
        check(before.equals(state.toString()),"Floating boundary reader mutated input");
    }
    static void shortDaySwapRejectsWithoutMutation()throws Exception{
        LocalDate day=LocalDate.of(1991,4,14);JSONObject input=fixture(day,1380),course=input.getJSONArray("courses").getJSONObject(0);
        input.put("tasks",new JSONArray().put(Planner.task(course.getString("id"),Planner.at(day,0),60))
            .put(Planner.task(course.getString("id"),Planner.at(day,75),1320)));
        JSONObject state=roundTrip(input);String before=state.toString();List<JSONObject> tasks=PlannerTests.sortedTasks(state);
        try{DailyTaskOrdering.swap(state,tasks.get(0).getString("id"),tasks.get(1).getString("id"),Planner.at(day,0));throw new AssertionError("Short-day swap crossed midnight");}
        catch(IllegalArgumentException expected){check(expected.getMessage().equals(DailyTaskOrdering.NO_SPACE),"Short-day swap used wrong rejection");}
        check(before.equals(state.toString()),"Rejected short-day swap mutated state");
    }
    static void savedOrderDoesNotPublishNewMidnightOverflow()throws Exception{
        LocalDate day=LocalDate.of(1991,4,14);JSONObject state=roundTrip(fixture(day,1440));List<JSONObject> tasks=PlannerTests.sortedTasks(state);
        state.getJSONObject("settings").put("dailyTaskOrders",new JSONArray().put(new JSONObject().put("day",Planner.at(day,0)).put("keys",new JSONArray(DailyTaskOrdering.keys(tasks)))));
        String before=state.toString();List<JSONObject> result=DailyTaskOrdering.apply(state,tasks,Collections.emptyList());
        check(SyncLedger.equivalent(new JSONArray(result),new JSONArray(tasks)),"Unavailable saved order rewrote original tasks");
        check(before.equals(state.toString()),"Unavailable saved order mutated state");
    }
    public static void main(String[] args)throws Exception{
        shortDaySwapRejectsWithoutMutation();historicalDayBoundaries();shortDayFloatingMetadata();savedOrderDoesNotPublishNewMidnightOverflow();
        System.out.println("Daily task Date interval checks passed: "+checks);
    }
}
