package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.util.*;

/** Controls use production Shanghai elapsed-minute mapping, not a New York timezone substitute. */
public final class FloatingDateCapacityTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject event(LocalDate day,int start,int end,int duration)throws Exception{
        return new JSONObject().put("id",Planner.id()).put("title","Synthetic elapsed floating event")
            .put("startMinute",start).put("endMinute",end).put("floatingDurationMinutes",duration)
            .put("startDate",Planner.at(day,0)).put("endDate",Planner.at(day,0)).put("weekdays",new JSONArray())
            .put("excludedDates",new JSONArray()).put("color","blue").put("notes","");
    }
    static JSONObject fixture(LocalDate day)throws Exception{
        JSONObject state=PlannerTests.empty();
        state.getJSONArray("courses").put(PlannerTests.course("Synthetic elapsed calendar",60,day,day,60)
            .put("type","录播课程").put("color","blue").put("notes",""));
        state.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(Planner.weekday(day),60,240)));
        return state;
    }
    static JSONObject roundTrip(JSONObject state)throws Exception{
        SyncLedger ledger=new SyncLedger();ledger.capture(state);ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
        return ledger.materialize();
    }
    public static void main(String[] args)throws Exception{
        JSONArray parity=new JSONArray();LocalDate ordinary=LocalDate.of(2026,3,8);
        check(Planner.ZONE.equals(ZoneId.of("Asia/Shanghai")),"Changed production timezone");
        for(LocalDate day:new LocalDate[]{LocalDate.of(1991,4,14),LocalDate.of(1991,9,15),ordinary}){
            double expectedDay=day.getYear()==2026?1440:day.getMonthValue()==4?1380:1500;
            check((Planner.at(day.plusDays(1),0)-Planner.at(day,0))/60==expectedDay,"Civil-day control has wrong length");
            for(int[] window:new int[][]{{60,240,90},{120,180,60}}){
                JSONObject state=fixture(day),event=event(day,window[0],window[1],window[2]);
                Planner.saveEvent(state,event,Planner.at(day,0));state=roundTrip(state);
                String before=state.toString();boolean[] study=new boolean[1440];Arrays.fill(study,60,240,true);
                Map<String,Integer> witness=Planner.reserve(Planner.list(state.getJSONArray("fixedEvents")),study);
                check(witness!=null,"Valid elapsed witness rejected");int start=witness.get(event.getString("id"));
                double lower=Planner.at(day,start),upper=Planner.at(day,start+window[2]);
                check(upper-lower==window[2]*60.0,"Witness lost actual occupied duration");
                check(lower>=Planner.at(day,window[0])&&upper<=Planner.at(day,window[1]),"Witness outside elapsed window");
                check(before.equals(state.toString()),"Witness search mutated source");
                JSONObject planned=new JSONObject(state.toString());Planner.replan(planned,Planner.at(day,0));
                check(FloatingEventTests.minutes(planned)==60,"Feasible elapsed calendar lost course work");
                check(planned.getJSONArray("androidRisks").length()==0&&planned.getJSONArray("androidWarnings").length()==0,"Feasible elapsed control reported failure");
                for(JSONObject task:Planner.list(planned.getJSONArray("tasks"))){
                    check(task.getDouble("start")>=Planner.at(day,60)&&Planner.end(task)<=Planner.at(day,240),"Task outside elapsed availability");
                    check(Planner.end(task)<=lower||task.getDouble("start")>=upper,"Task overlaps complete floating witness");
                }
                check(SyncLedger.equivalent(planned.getJSONArray("fixedEvents"),state.getJSONArray("fixedEvents")),"Replan changed floating rule");
                if(day.equals(ordinary))parity.put(new JSONObject().put("state",state).put("now",Planner.at(day,0)).put("tasks",planned.getJSONArray("tasks")));
            }
        }
        Files.write(Paths.get("Android/build/tests/floating-date-capacity.json"),parity.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("Floating Date capacity controls passed: "+checks+"; ordinary cross-platform fixtures="+parity.length());
    }
}
