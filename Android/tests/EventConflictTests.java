package local.studyplanner;
import org.json.*;
import java.time.*;
import java.util.*;

public class EventConflictTests {
    static void check(boolean b,String message){if(!b)throw new AssertionError(message);}
    static final LocalDate DAY=LocalDate.of(2026,9,22);
    static JSONObject event(String title,int a,int b,int days)throws Exception{
        return new JSONObject().put("id",Planner.id()).put("title",title).put("startMinute",a).put("endMinute",b).put("startDate",Planner.at(DAY,0)).put("endDate",Planner.at(DAY.plusDays(days),0)).put("weekdays",new JSONArray("[1,2,3,4,5,6,7]"));
    }
    public static void main(String[] args)throws Exception{
        JSONObject s=PlannerTests.empty(),old=event("学校",480,600,2),other=event("会议",610,630,0),requested=event("新事项",540,660,3);
        s.getJSONArray("fixedEvents").put(old).put(other);String original=s.toString(),input=requested.toString();
        try{Planner.saveEvent(s,requested,Planner.at(DAY,420));throw new AssertionError("Conflict missing");}
        catch(Planner.EventConflictException e){check(e.conflicts.size()==4,"Not all conflicts reported");check(e.conflicts.get(0).timeDescription().equals("08:00–10:00"),"Missing time");check(e.conflicts.get(0).explanation().equals("重叠 09:00–10:00（60 分钟）"),"Missing overlap");}
        check(s.toString().equals(original)&&requested.toString().equals(input),"Failed save mutated input");
        try{Planner.saveEvent(s,requested,Planner.at(DAY,420),Collections.singleton(DAY));throw new AssertionError("Unconfirmed dates accepted");}
        catch(Planner.EventConflictException e){check(e.conflicts.size()==2,"Partial skip did not remove only selected day");}
        check(s.toString().equals(original),"Partial save mutated database");
        Planner.saveEvent(s,requested,Planner.at(DAY,420),new HashSet<>(Arrays.asList(DAY,DAY.plusDays(1),DAY.plusDays(2))));
        check(!Planner.occurs(requested,DAY)&&Planner.occurs(requested,DAY.plusDays(3)),"Incorrect exclusions");
        s=PlannerTests.empty();JSONObject course=PlannerTests.course("数学学习",60,DAY,DAY,60);s.getJSONArray("courses").put(course);s.getJSONArray("tasks").put(Planner.task(course.getString("id"),Planner.at(DAY,480),60));
        requested=event("临时会议",510,570,1);
        Planner.saveEvent(s,requested,Planner.at(DAY,495));
        s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("weekday",Planner.weekday(DAY)).put("startMinute",480).put("endMinute",780));
        Planner.replan(s,Planner.at(DAY,495));check(s.getJSONArray("tasks").length()==1,"Old active task retained");check(s.getJSONArray("tasks").getJSONObject(0).getDouble("start")==Planner.at(DAY,570),"Task did not move after meeting");
        System.out.println("PASS conflict details, all dates, independent exclusions, active learning and atomic saves");
    }
}
