package local.studyplanner;
import org.json.*;
import java.time.*;
import java.util.*;

public class FloatingEventTests {
    static void check(boolean b,String reason){if(!b)throw new AssertionError(reason);}
    static final LocalDate DAY=LocalDate.of(2026,9,22);
    static JSONObject event(int a,int b,Integer n)throws Exception{
        JSONObject e=new JSONObject().put("id",Planner.id()).put("title","浮动").put("startMinute",a).put("endMinute",b).put("startDate",Planner.at(DAY,0)).put("endDate",Planner.at(DAY,0)).put("weekdays",new JSONArray());
        if(n!=null)e.put("floatingDurationMinutes",n);return e;
    }
    static JSONObject state()throws Exception{
        JSONObject s=PlannerTests.empty();
        s.getJSONObject("settings").put("notificationMinute",0).getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",Planner.weekday(DAY)).put("startMinute",840).put("endMinute",1080));
        s.getJSONArray("courses").put(PlannerTests.course("数学",240,DAY,DAY,60));
        s.getJSONArray("fixedEvents").put(event(840,1080,60));return s;
    }
    static int minutes(JSONObject s)throws Exception{int n=0;for(JSONObject t:Planner.list(s.getJSONArray("tasks")))n+=t.getInt("durationMinutes");return n;}
    static JSONObject studyHour()throws Exception{
        JSONObject s=state();s.getJSONObject("settings").put("availability",new JSONArray().put(new JSONObject().put("id",Planner.id()).put("weekday",Planner.weekday(DAY)).put("startMinute",600).put("endMinute",660)));
        s.getJSONArray("courses").getJSONObject(0).put("totalMinutes",60);return s;
    }
    public static void main(String[] args)throws Exception{
        JSONObject s=state();Planner.replan(s,Planner.at(DAY,780));check(minutes(s)==120,"Floating capacity must include lesson breaks");
        for(JSONObject t:Planner.list(s.getJSONArray("tasks")))check(Planner.planningStart(t)==Planner.at(DAY,840)&&Planner.planningEnd(t)==Planner.at(DAY,1080),"Floating task window lost");
        String tasks=s.getJSONArray("tasks").toString();Planner.replan(s,Planner.at(DAY,930));check(!tasks.equals(s.getJSONArray("tasks").toString()),"Started window must replan");check(s.getJSONArray("tasks").length()==1&&s.getJSONArray("tasks").getJSONObject(0).getDouble("start")==Planner.at(DAY,930),"Must replan from now");
        check(Planner.review(s,Planner.at(DAY,930)).isEmpty(),"Premature review");check(Planner.review(s,Planner.at(DAY,1080)).size()==1,"Missing end-of-window review");
        s=state();Planner.saveEvent(s,event(900,1080,90),Planner.at(DAY,780));Planner.replan(s,Planner.at(DAY,780));check(minutes(s)==60,"Overlapping quotas not additive");
        boolean rejected=false;try{Planner.saveEvent(s,event(840,1080,120),Planner.at(DAY,780));}catch(IllegalArgumentException e){rejected=true;}check(rejected,"Overbooked floating windows accepted");
        s=state();Planner.saveEvent(s,event(900,960,null),Planner.at(DAY,780));Planner.replan(s,Planner.at(DAY,780));check(minutes(s)==120,"Exact appointment capacity incorrect");
        for(int n:new int[]{0,-1,241}){rejected=false;try{Planner.saveEvent(state(),event(840,1080,n),Planner.at(DAY,780));}catch(IllegalArgumentException e){rejected=true;}check(rejected,"Invalid duration accepted");}
        s=state();s.put("fixedEvents",new JSONArray().put(event(1080,1200,60)));Planner.replan(s,Planner.at(DAY,780));check(minutes(s)==180,"Disjoint event should leave capacity for three lessons with breaks");
        for(int[] bounds:new int[][]{{540,660},{600,720}}){
            s=studyHour();s.put("fixedEvents",new JSONArray().put(event(bounds[0],bounds[1],60)));
            List<String> warnings=Planner.replan(s,Planner.at(DAY,480));check(minutes(s)==60&&warnings.isEmpty(),"Float must use time outside study availability");
            check(s.getJSONArray("tasks").getJSONObject(0).getDouble("start")==Planner.at(DAY,600),"Study hour moved");
        }
        s=studyHour();s.put("fixedEvents",new JSONArray().put(event(540,720,60)).put(event(540,780,120)));
        check(Planner.replan(s,Planner.at(DAY,480)).isEmpty()&&minutes(s)==60,"Placements must optimize events jointly");
        s=studyHour();s.getJSONArray("courses").getJSONObject(0).put("minimumBlockMinutes",30);
        s.put("fixedEvents",new JSONArray().put(event(570,660,60)));Planner.replan(s,Planner.at(DAY,480));
        check(minutes(s)==30,"Deduct only unavoidable overlap");
        s=studyHour();s.put("fixedEvents",new JSONArray().put(event(540,660,60)).put(event(540,600,null)));
        Planner.replan(s,Planner.at(DAY,480));check(minutes(s)==0,"Fixed appointments are not spare time");
        System.out.println("PASS floating event capacity, overlapping windows, exact appointments, validation, replanned active windows and review timing");
    }
}
