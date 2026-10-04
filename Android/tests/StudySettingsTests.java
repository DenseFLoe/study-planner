package local.studyplanner;

import org.json.*;
import java.time.*;
import java.util.*;

/** Day-window edits must never turn the same unfinished lessons into duplicate drafts. */
public final class StudySettingsTests {
    static final LocalDate TODAY=LocalDate.of(2026,10,3);
    static int checks;
    static void check(boolean condition,String message){checks++;if(!condition)throw new AssertionError(message);}
    static JSONObject copy(JSONObject value)throws Exception{return new JSONObject(value.toString());}
    static JSONObject state()throws Exception{
        JSONObject state=PlannerTests.empty();
        JSONObject course=PlannerTests.course("两节课程",120,TODAY.minusDays(1),TODAY,60).put("type","不定时录播课程");
        course.put("manualLessons",new JSONArray().put(new JSONObject().put("id","A").put("name","第一节").put("durationMinutes",60))
            .put(new JSONObject().put("id","B").put("name","第二节").put("durationMinutes",60)));
        state.getJSONArray("courses").put(course);
        state.getJSONObject("settings").put("availability",windows(480,1320));return state;
    }
    static JSONArray windows(int start,int end)throws Exception{
        JSONArray windows=new JSONArray();for(int weekday=1;weekday<=7;weekday++)
            windows.put(new JSONObject().put("id",Planner.id()).put("weekday",weekday).put("startMinute",start).put("endMinute",end));return windows;
    }
    static void changedWindowsAndReopen()throws Exception{
        JSONObject state=state();Planner.replan(state,Planner.at(TODAY,480));
        Set<String> previous=new HashSet<>();for(JSONObject task:Planner.list(state.getJSONArray("tasks")))previous.add(task.getString("id"));
        JSONObject settings=copy(state.getJSONObject("settings")).put("availability",windows(1140,1320));
        Planner.updateStudySettings(state,settings,Planner.at(TODAY,1140));Planner.replan(state,Planner.at(TODAY,1140));
        check(state.getJSONArray("tasks").length()==2,"Changing windows duplicated ended lessons");
        Set<String> lessonIDs=new HashSet<>();int minutes=0;
        for(JSONObject task:Planner.list(state.getJSONArray("tasks"))){
            check(!previous.contains(task.getString("id")),"An ended draft survived a window edit");
            lessonIDs.add(task.getString("lessonID"));minutes+=task.getInt("durationMinutes");
        }
        check(minutes==120&&lessonIDs.size()==2,"Window edit repeated learning amount");
        check(Planner.completed(state,state.getJSONArray("courses").getJSONObject(0))==0,"Window edit credited unfinished work");
        String snapshot=state.getJSONArray("tasks").toString();state=copy(state);
        Planner.replan(state,Planner.at(TODAY,1260));check(snapshot.equals(state.getJSONArray("tasks").toString()),"Reopening duplicated the anchored draft");
        SyncLedger ledger=new SyncLedger();ledger.capture(state);SyncLedger peer=new SyncLedger();peer.merge(ledger.changes(0));
        JSONObject synced=peer.materialize();Planner.replan(synced,Planner.at(TODAY,1260));
        check(snapshot.equals(synced.getJSONArray("tasks").toString()),"Sync lost the day anchor or changed the draft");
        check(Planner.actualStudyStart(synced,Planner.at(TODAY.plusDays(1),420))==null,"Day anchor remained active tomorrow");
    }
    static void equivalentWindowsAndStaleEditor()throws Exception{
        JSONObject state=state();JSONObject stale=copy(state.getJSONObject("settings"));
        List<JSONObject> reordered=Planner.list(windows(480,1320));Collections.reverse(reordered);
        JSONObject updated=copy(stale).put("availability",new JSONArray(reordered)).put("notificationMinute",1320);
        Planner.updateStudySettings(state,updated,Planner.at(TODAY,840));
        check(Planner.actualStudyStart(state,Planner.at(TODAY,840))==null,"New IDs or row ordering reset today's history");
        Planner.recordActualStudyStart(state,630,Planner.at(TODAY,840));
        updated=copy(stale).put("availability",windows(480,1260)).put("notificationMinute",1320);
        Planner.updateStudySettings(state,updated,Planner.at(TODAY,900));
        check(Planner.actualStudyStart(state,Planner.at(TODAY,900))==Planner.at(TODAY,630),"Stale settings overwrote the latest start");
        check(state.getJSONObject("settings").getInt("notificationMinute")==1320,"The requested setting was lost");
        updated=copy(stale).put("availability",windows(480,1200));
        Planner.updateStudySettings(state,updated,Planner.at(TODAY.plusDays(1),600));
        check(Planner.actualStudyStart(state,Planner.at(TODAY.plusDays(1),600))==Planner.at(TODAY.plusDays(1),600),"Window edit did not replace yesterday's expired anchor");
    }
    static void confirmedAndPriorDayHistory()throws Exception{
        JSONObject state=state();Planner.replan(state,Planner.at(TODAY,480));
        JSONObject done=state.getJSONArray("tasks").getJSONObject(0);
        Planner.confirm(state,done.getString("id"),30,Planner.at(TODAY,540));String confirmation=done.toString(),records=state.getJSONArray("completions").toString();
        JSONObject yesterday=Planner.task(done.getString("courseID"),Planner.at(TODAY.minusDays(1),480),60);
        state.getJSONArray("tasks").put(yesterday);String history=yesterday.toString();
        JSONObject fixed=new JSONObject().put("id",Planner.id()).put("title","晚饭").put("startMinute",1140).put("endMinute",1200)
            .put("startDate",Planner.at(TODAY,0)).put("endDate",Planner.at(TODAY,0)).put("weekdays",new JSONArray());
        state.getJSONArray("fixedEvents").put(fixed);String events=state.getJSONArray("fixedEvents").toString();
        Planner.updateStudySettings(state,copy(state.getJSONObject("settings")).put("availability",windows(1140,1320)),Planner.at(TODAY,1020));
        Planner.replan(state,Planner.at(TODAY,1020));
        check(Planner.list(state.getJSONArray("tasks")).stream().anyMatch(t->t.toString().equals(confirmation)),"Confirmed task changed");
        check(Planner.list(state.getJSONArray("tasks")).stream().anyMatch(t->t.toString().equals(history)),"Prior-day history changed");
        check(records.equals(state.getJSONArray("completions").toString()),"Completion records changed");
        check(events.equals(state.getJSONArray("fixedEvents").toString()),"Fixed appointments changed");
        check(Planner.remaining(state,state.getJSONArray("courses").getJSONObject(0))==90,"Confirmed credit changed");
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(task)&&Planner.day(task.getDouble("start")).equals(TODAY))
            check(task.getDouble("start")>=Planner.at(TODAY,1200),"New task overlaps a fixed appointment");
    }
    static void homepageInvalidation()throws Exception{
        JSONObject state=state();String course=state.getJSONArray("courses").getJSONObject(0).getString("id");
        for(int minute:new int[]{900,1020,1140})state.getJSONArray("tasks").put(Planner.task(course,Planner.at(TODAY,minute),60).put("lessonID","A"));
        Planner.recordActualStudyStart(state,1150,Planner.at(TODAY,1175));
        check(state.getJSONArray("tasks").length()==0,"Homepage start retained obsolete drafts");
        Planner.replan(state,Planner.at(TODAY,1175));check(state.getJSONArray("tasks").length()==2,"Homepage start failed to replace duplicates");
        String snapshot=state.toString();boolean rejected=false;
        try{Planner.recordActualStudyStart(state,1440,Planner.at(TODAY,1175));}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected&&snapshot.equals(state.toString()),"Invalid input modified the timetable");
    }
    public static void main(String[] args)throws Exception{
        changedWindowsAndReopen();equivalentWindowsAndStaleEditor();confirmedAndPriorDayHistory();homepageInvalidation();
        System.out.println("PASS "+checks+" study settings checks: duplicate drafts, reopen, sync, stale editors, confirmed history and appointments");
    }
}
