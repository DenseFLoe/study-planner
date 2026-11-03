package local.studyplanner;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.util.*;

/** Preserve Java's elapsed-minute model while checking shared ordinary-day swap behavior. */
public final class DailyFloatingDateTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject fixture(LocalDate day,int occupied)throws Exception{
        JSONObject state=FloatingDateCapacityTests.fixture(day),course=state.getJSONArray("courses").getJSONObject(0);
        course.put("totalMinutes",40);
        state.getJSONArray("fixedEvents").put(FloatingDateCapacityTests.event(day,60,240,occupied));
        state.put("tasks",new JSONArray().put(Planner.task(course.getString("id"),Planner.at(day,60),20).put("lessonID","first"))
            .put(Planner.task(course.getString("id"),Planner.at(day,95),20).put("lessonID","second")));
        return FloatingDateCapacityTests.roundTrip(state);
    }
    public static void main(String[]args)throws Exception{
        LocalDate ordinary=LocalDate.of(2026,3,8);JSONArray parity=new JSONArray();
        check(Planner.ZONE.equals(ZoneId.of("Asia/Shanghai")),"Changed production timezone");
        for(LocalDate day:new LocalDate[]{LocalDate.of(1991,4,14),LocalDate.of(1991,9,15),ordinary})for(int occupied:new int[]{90,160}){
            JSONObject state=fixture(day,occupied),before=new JSONObject(state.toString());
            List<JSONObject> original=PlannerTests.sortedTasks(state);String first=original.get(0).getString("id"),second=original.get(1).getString("id");
            boolean succeeds=occupied==90;
            if(succeeds){
                DailyTaskOrdering.swap(state,first,second,Planner.at(day,60));List<JSONObject> result=PlannerTests.sortedTasks(state);
                check(result.size()==2&&result.get(0).getString("id").equals(second)&&result.get(1).getString("id").equals(first),"Swap lost identity/order");
                for(JSONObject task:result){
                    check(task.getInt("durationMinutes")==20,"Swap shortened a task");
                    check(task.getDouble("start")>=Planner.at(day,60)&&Planner.end(task)<=Planner.at(day,240),"Swap left elapsed availability");
                }
                check(result.get(1).getDouble("start")-Planner.end(result.get(0))>=Planner.BREAK_SECONDS,"Swap lost rest");
                boolean[] study=new boolean[1440];Arrays.fill(study,60,240,true);List<JSONObject> events=Planner.list(state.getJSONArray("fixedEvents"));
                Map<String,Integer> witness=Planner.reserve(events,study);JSONObject event=events.get(0);int start=witness.get(event.getString("id"));
                double lower=Planner.at(day,start),upper=Planner.at(day,start+occupied);
                check(upper-lower==occupied*60.0,"Floating duration shortened");
                for(JSONObject task:result)check(Planner.end(task)<=lower||task.getDouble("start")>=upper,"Swap overlapped complete floating reservation");
                check(SyncLedger.equivalent(before.getJSONArray("fixedEvents"),state.getJSONArray("fixedEvents")),"Swap changed event rule");
            }else{
                try{DailyTaskOrdering.swap(state,first,second,Planner.at(day,60));throw new AssertionError("Impossible elapsed swap accepted");}
                catch(IllegalArgumentException expected){check(DailyTaskOrdering.NO_SPACE.equals(expected.getMessage()),"Wrong failure");}
                check(SyncLedger.equivalent(state,before),"Failed swap mutated state");
            }
            if(day.equals(ordinary))parity.put(new JSONObject().put("state",before).put("now",Planner.at(day,60)).put("succeeds",succeeds).put("tasks",state.getJSONArray("tasks")));
        }
        Files.write(Paths.get("Android/build/tests/daily-floating-date.json"),parity.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("Daily floating Date controls passed: "+checks+"; ordinary parity fixtures="+parity.length());
    }
}
