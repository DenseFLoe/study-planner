package local.studyplanner;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.util.*;

/** Exact-overlap controls for production Shanghai elapsed time and ordinary cross-platform errors. */
public final class FixedEventActualOverlapTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    public static void main(String[]args)throws Exception{
        JSONArray parity=new JSONArray();LocalDate ordinary=LocalDate.of(2026,3,8);
        for(LocalDate day:new LocalDate[]{LocalDate.of(1991,4,14),LocalDate.of(1991,9,15),ordinary}){
            for(int[] pair:new int[][]{{480,600,540,660},{480,540,540,600},{180,300,105,135},{480,600,480,600},{60,120,180,240},{60,240,90,120}}){
                JSONObject state=FixedEventDateCapacityTests.state(day),old=FixedEventDateCapacityTests.event(day,pair[0],pair[1],null),incoming=FixedEventDateCapacityTests.event(day,pair[2],pair[3],null);
                Planner.saveEvent(state,old,Planner.at(day,0));JSONObject before=new JSONObject(state.toString()),input=new JSONObject(incoming.toString());
                boolean overlaps=pair[0]<pair[3]&&pair[1]>pair[2];String explanation="",description="";
                try{
                    Planner.saveEvent(state,incoming,Planner.at(day,0));check(!overlaps,"Accepted elapsed overlap");
                    double a=Planner.at(day,pair[0]),b=Planner.at(day,pair[1]),c=Planner.at(day,pair[2]),d=Planner.at(day,pair[3]);
                    check(b<=c||d<=a,"Accepted actual overlap");check(state.getJSONArray("fixedEvents").length()==2,"Lost accepted rule");
                }catch(Planner.EventConflictException expected){
                    check(overlaps,"Rejected separate elapsed intervals");check(expected.conflicts.size()==1,"Wrong conflict count");
                    Planner.EventConflict conflict=expected.conflicts.get(0);
                    check(conflict.eventID.equals(old.getString("id"))&&conflict.date.equals(day)&&conflict.reason.equals("overlap"),"Wrong overlap metadata");
                    explanation=conflict.explanation();description=conflict.timeDescription();
                    check(SyncLedger.equivalent(before,state)&&SyncLedger.equivalent(input,incoming),"Conflict changed state/input");
                    JSONObject skipped=new JSONObject(before.toString()),draft=new JSONObject(input.toString());
                    Planner.saveEvent(skipped,draft,Planner.at(day,0),Collections.emptySet(),Collections.singleton(day));
                    check(!Planner.occurs(EventConflictTests.find(skipped,old.getString("id")),day)&&Planner.occurs(EventConflictTests.find(skipped,draft.getString("id")),day),"Local skip selected wrong rule");
                    String snapshot=skipped.toString();
                    try{Planner.setEventSkipped(skipped,old.getString("id"),day,false,Planner.at(day,0));throw new AssertionError("Restored overlap");}
                    catch(Planner.EventConflictException restored){check(snapshot.equals(skipped.toString()),"Failed restore changed exclusions");}
                }
                if(day.equals(ordinary))parity.put(new JSONObject().put("state",before).put("event",input).put("now",Planner.at(day,0)).put("succeeds",!overlaps)
                    .put("events",state.getJSONArray("fixedEvents")).put("explanation",explanation).put("description",description));
            }
        }
        Files.write(Paths.get("Android/build/tests/fixed-event-actual-overlap.json"),parity.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("Fixed event actual-overlap controls passed: "+checks+"; ordinary parity fixtures="+parity.length());
    }
}
