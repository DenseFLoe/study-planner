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
    static JSONObject dayEvent(String title,int a,int b,LocalDate day)throws Exception{
        return new JSONObject().put("id",Planner.id()).put("title",title).put("startMinute",a).put("endMinute",b).put("startDate",Planner.at(day,0)).put("endDate",Planner.at(day,0)).put("weekdays",new JSONArray("[1,2,3,4,5,6,7]"));
    }
    static Set<LocalDate> dates(LocalDate...days){return new HashSet<>(Arrays.asList(days));}
    static boolean excluded(JSONObject event,LocalDate day){
        JSONArray values=event.optJSONArray("excludedDates");if(values==null)return false;
        for(int i=0;i<values.length();i++)if(Planner.day(values.optDouble(i)).equals(day))return true;return false;
    }
    static JSONObject find(JSONObject s,String id){
        for(JSONObject e:Planner.list(s.getJSONArray("fixedEvents")))if(e.getString("id").equals(id))return e;return null;
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
        localConflicts();
        mixedPolicies();
        atomicFailures();
        floatingCapacitySkip();
        localHistory();
        overlappingSelections();
        System.out.println("PASS conflict details, all dates, independent exclusions, local skips, mixed policies, atomic saves, floating capacity, history and overlap precedence");
    }

    // 多冲突本地全跳过，无关事项与本地规则保留
    static void localConflicts()throws Exception{
        JSONObject s=PlannerTests.empty(),school=event("学校",480,600,2),meeting=dayEvent("会议",610,630,DAY),lunch=dayEvent("午饭",720,780,DAY),gym=dayEvent("健身",480,600,DAY.plusDays(4)),requested=event("新事项",540,660,3);
        s.getJSONArray("fixedEvents").put(school).put(meeting).put(lunch).put(gym);
        String before=s.toString();boolean blocked=false;
        try{Planner.saveEvent(s,requested,Planner.at(DAY,420),Collections.emptySet(),Collections.emptySet());}
        catch(Planner.EventConflictException e){blocked=e.conflicts.size()==4;}
        check(blocked&&s.toString().equals(before),"Local conflicts must all be reported without mutation");
        String schoolID=school.getString("id"),meetingID=meeting.getString("id"),lunchID=lunch.getString("id"),gymID=gym.getString("id");
        Planner.saveEvent(s,requested,Planner.at(DAY,420),Collections.emptySet(),dates(DAY,DAY.plusDays(1),DAY.plusDays(2)));
        JSONObject keptSchool=find(s,schoolID),keptMeeting=find(s,meetingID),keptLunch=find(s,lunchID),keptGym=find(s,gymID);
        check(keptSchool!=null&&keptMeeting!=null&&keptLunch!=null&&keptGym!=null,"Local items lost");
        check(Planner.occurs(requested,DAY)&&Planner.occurs(requested,DAY.plusDays(1))&&Planner.occurs(requested,DAY.plusDays(2))&&Planner.occurs(requested,DAY.plusDays(3)),"Skipping local items removed the new event");
        check(!Planner.occurs(keptSchool,DAY)&&!Planner.occurs(keptSchool,DAY.plusDays(1))&&!Planner.occurs(keptSchool,DAY.plusDays(2)),"Every selected local date must be skipped");
        check(!Planner.occurs(keptMeeting,DAY),"Selected local occurrence not skipped");
        check(Planner.day(keptSchool.getDouble("startDate")).equals(DAY)&&Planner.day(keptSchool.getDouble("endDate")).equals(DAY.plusDays(2)),"Local rule bounds changed");
        check(Planner.occurs(keptLunch,DAY)&&!excluded(keptLunch,DAY),"An overlap-free local item was skipped");
        check(Planner.occurs(keptGym,DAY.plusDays(4))&&!excluded(keptGym,DAY.plusDays(4)),"An unrelated local day was changed");
        check(s.getJSONArray("fixedEvents").length()==5,"Local items lost");
    }

    // 每天独立选择策略：22、24 跳本地，23 跳新事项
    static void mixedPolicies()throws Exception{
        JSONObject s=PlannerTests.empty(),school=event("学校",480,600,2),meeting=dayEvent("会议",610,630,DAY.plusDays(1)),requested=event("新事项",540,660,2);
        s.getJSONArray("fixedEvents").put(school).put(meeting);
        String schoolID=school.getString("id"),meetingID=meeting.getString("id");
        Planner.saveEvent(s,requested,Planner.at(DAY,420),dates(DAY.plusDays(1)),dates(DAY,DAY.plusDays(2)));
        JSONObject keptSchool=find(s,schoolID),keptMeeting=find(s,meetingID);
        check(keptSchool!=null&&keptMeeting!=null,"Mixed policy lost local items");
        check(Planner.occurs(requested,DAY)&&!Planner.occurs(requested,DAY.plusDays(1))&&Planner.occurs(requested,DAY.plusDays(2)),"Mixed policies mishandled the new event");
        check(!Planner.occurs(keptSchool,DAY)&&Planner.occurs(keptSchool,DAY.plusDays(1))&&!Planner.occurs(keptSchool,DAY.plusDays(2)),"Mixed policies mishandled local days");
        check(Planner.occurs(keptMeeting,DAY.plusDays(1))&&!excluded(keptMeeting,DAY.plusDays(1)),"Skipping the new event must not touch local items");
    }

    // 未解决冲突或校验错误时不留下部分修改
    static void atomicFailures()throws Exception{
        JSONObject s=PlannerTests.empty(),school=event("学校",480,600,1),requested=event("新事项",540,660,1);
        s.getJSONArray("fixedEvents").put(school);
        String before=s.toString(),input=requested.toString();boolean uncovered=false;
        try{Planner.saveEvent(s,requested,Planner.at(DAY,420),Collections.emptySet(),dates(DAY));}
        catch(Planner.EventConflictException e){uncovered=e.conflicts.size()==1&&e.conflicts.get(0).date.equals(DAY.plusDays(1));}
        check(uncovered,"An unselected local conflict must still block the save");
        check(s.toString().equals(before)&&requested.toString().equals(input),"Failed resolution mutated saved or input data");
        boolean invalid=false;
        try{Planner.saveEvent(s,new JSONObject(requested.toString()).put("endMinute",540),Planner.at(DAY,420),Collections.emptySet(),dates(DAY));}
        catch(IllegalArgumentException e){invalid=!(e instanceof Planner.EventConflictException);}
        check(invalid&&s.toString().equals(before),"Invalid edit changed the state");
    }

    // 浮动容量冲突可通过只跳过本地项解决
    static void floatingCapacitySkip()throws Exception{
        JSONObject s=PlannerTests.empty(),local=dayEvent("浮动杂务",840,960,DAY),requested=dayEvent("另一项",840,960,DAY);
        local.put("floatingDurationMinutes",90);requested.put("floatingDurationMinutes",90);
        s.getJSONArray("fixedEvents").put(local);boolean capacity=false;
        try{Planner.saveEvent(s,requested,Planner.at(DAY,420),Collections.emptySet(),Collections.emptySet());}
        catch(Planner.EventConflictException e){capacity=e.conflicts.get(0).reason.equals("capacity")&&e.conflicts.get(0).timeDescription().equals("14:00–16:00 · 浮动占用 90 分钟");}
        check(capacity,"Floating capacity conflict missing");
        String localID=local.getString("id");
        Planner.saveEvent(s,requested,Planner.at(DAY,420),Collections.emptySet(),dates(DAY));
        JSONObject kept=find(s,localID);
        check(kept!=null&&!Planner.occurs(kept,DAY)&&excluded(kept,DAY),"Local floating item not skipped");
        check(kept.getInt("floatingDurationMinutes")==90&&kept.getInt("startMinute")==840&&kept.getInt("endMinute")==960,"Local floating window changed");
        check(Planner.occurs(requested,DAY)&&s.getJSONArray("fixedEvents").length()==2,"Floating save lost items");
    }

    // 本地历史和重复规则在跳过一天后保持不变
    static void localHistory()throws Exception{
        JSONObject s=PlannerTests.empty(),school=event("学校",480,600,4),requested=dayEvent("补课",540,660,DAY);
        school.put("startDate",Planner.at(DAY.minusDays(2),0)).put("endDate",Planner.at(DAY.plusDays(2),0));
        s.getJSONArray("fixedEvents").put(school);
        String schoolID=school.getString("id");
        Planner.saveEvent(s,requested,Planner.at(DAY,420),Collections.emptySet(),dates(DAY));
        JSONObject kept=find(s,schoolID);
        check(kept!=null&&Planner.occurs(kept,DAY.minusDays(2))&&Planner.occurs(kept,DAY.plusDays(1))&&Planner.occurs(kept,DAY.plusDays(2)),"Local history or recurrence changed");
        check(!Planner.occurs(kept,DAY)&&excluded(kept,DAY),"Selected local day not skipped");
        check(Planner.day(kept.getDouble("startDate")).equals(DAY.minusDays(2))&&Planner.day(kept.getDouble("endDate")).equals(DAY.plusDays(2)),"Local rule bounds changed");
        check(Planner.occurs(requested,DAY)&&s.getJSONArray("fixedEvents").length()==2,"History save lost events");
    }

    // 同一日期同时出现在两个集合时优先跳过新事项
    static void overlappingSelections()throws Exception{
        JSONObject s=PlannerTests.empty(),local=dayEvent("学校",480,600,DAY),requested=dayEvent("新事项",540,660,DAY);
        s.getJSONArray("fixedEvents").put(local);
        String localID=local.getString("id");
        Planner.saveEvent(s,requested,Planner.at(DAY,420),dates(DAY),dates(DAY));
        JSONObject kept=find(s,localID);
        check(!Planner.occurs(requested,DAY),"Overlapping selection must skip the new event");
        check(kept!=null&&Planner.occurs(kept,DAY)&&!excluded(kept,DAY),"Overlapping selection modified the local item");
        check(s.getJSONArray("fixedEvents").length()==2,"Overlap save lost events");
    }
}
