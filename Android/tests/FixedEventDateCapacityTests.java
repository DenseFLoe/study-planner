package local.studyplanner;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.util.*;

/** Actual-duration controls retain production Shanghai's elapsed-minute mapping. */
public final class FixedEventDateCapacityTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject state(LocalDate day)throws Exception{
        JSONObject state=FloatingDateCapacityTests.fixture(day);
        state.put("courses",new JSONArray());return state;
    }
    static JSONObject event(LocalDate day,int start,int end,Integer minutes)throws Exception{
        JSONObject event=FloatingDateCapacityTests.event(day,start,end,minutes==null?1:minutes);
        if(minutes==null)event.remove("floatingDurationMinutes");return event;
    }
    static void witness(JSONObject state,LocalDate day)throws Exception{
        List<JSONObject> events=Planner.list(state.getJSONArray("fixedEvents"));
        events.removeIf(e->!Planner.occurs(e,day));
        Map<String,Integer> placements=Planner.reserve(events,new boolean[1440]);check(placements!=null,"Missing complete witness");
        List<double[]> spans=new ArrayList<>();
        for(JSONObject event:events){
            int start=Planner.floating(event)?placements.get(event.getString("id")):event.getInt("startMinute");
            double lower=Planner.at(day,start),upper=Planner.at(day,start+Planner.occupied(event));
            check(upper-lower==Planner.occupied(event)*60.0,"Actual duration changed");
            check(lower>=Planner.at(day,event.getInt("startMinute"))&&upper<=Planner.at(day,event.getInt("endMinute")),"Witness outside its own window");
            check(lower>=Planner.at(day,0)&&upper<=Planner.at(day.plusDays(1),0),"Early-window witness left civil day");spans.add(new double[]{lower,upper});
        }
        spans.sort(Comparator.comparingDouble(a->a[0]));
        for(int i=1;i<spans.size();i++)check(spans.get(i-1)[1]<=spans.get(i)[0],"Accepted control overlaps");
        FloatingDateCapacityTests.roundTrip(state);
    }
    public static void main(String[]args)throws Exception{
        JSONArray parity=new JSONArray();LocalDate ordinary=LocalDate.of(2026,3,8);
        check(Planner.ZONE.equals(ZoneId.of("Asia/Shanghai")),"Changed production timezone");
        for(LocalDate day:new LocalDate[]{LocalDate.of(1991,4,14),LocalDate.of(1991,9,15),ordinary}){
            for(String operation:new String[]{"single","combined","fragmented","restore","overflow","skipIncoming","skipExisting"}){
                JSONObject state=state(day),incoming=event(day,60,240,60);
                if(operation.equals("single"))incoming=event(day,60,180,90);
                else if(operation.equals("fragmented")){Planner.saveEvent(state,event(day,180,210,null),Planner.at(day,0));incoming=event(day,60,240,90);}
                else {
                    JSONObject existing=event(day,60,240,90);
                    if(operation.equals("restore"))existing.put("excludedDates",new JSONArray().put(Planner.at(day,0)));
                    Planner.saveEvent(state,existing,Planner.at(day,0));
                    if(operation.equals("restore")){Planner.saveEvent(state,incoming,Planner.at(day,0));incoming=existing;}
                    else if(!operation.equals("combined"))incoming=event(day,60,240,120);
                }
                JSONObject before=new JSONObject(state.toString()),input=new JSONObject(incoming.toString());boolean succeeds=!operation.equals("overflow");
                try{
                    if(operation.equals("restore"))Planner.setEventSkipped(state,incoming.getString("id"),day,false,Planner.at(day,0));
                    else if(operation.equals("skipIncoming"))Planner.saveEvent(state,incoming,Planner.at(day,0),Collections.singleton(day));
                    else if(operation.equals("skipExisting"))Planner.saveEvent(state,incoming,Planner.at(day,0),Collections.emptySet(),Collections.singleton(day));
                    else Planner.saveEvent(state,incoming,Planner.at(day,0));
                    check(succeeds,"Accepted impossible elapsed capacity");witness(state,day);
                }catch(Planner.EventConflictException expected){
                    check(!succeeds,"Rejected feasible elapsed control");
                    check(expected.conflicts.size()==1&&expected.conflicts.get(0).reason.equals("capacity"),"Wrong capacity conflict");
                    check(SyncLedger.equivalent(state,before)&&SyncLedger.equivalent(incoming,input),"Rejected operation mutated input/state");
                }
                if(day.equals(ordinary))parity.put(new JSONObject().put("state",before).put("event",input).put("operation",operation)
                    .put("now",Planner.at(day,0)).put("succeeds",succeeds).put("events",state.getJSONArray("fixedEvents")));
            }
        }
        Files.write(Paths.get("Android/build/tests/fixed-event-date-capacity.json"),parity.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("Fixed event Date capacity controls passed: "+checks+"; ordinary parity fixtures="+parity.length());
    }
}
