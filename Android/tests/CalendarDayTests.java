package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class CalendarDayTests {
    static final LocalDate DAY=LocalDate.of(2026,11,4);
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static List<String> ids(List<JSONObject> rows){List<String> ids=new ArrayList<>();for(JSONObject row:rows)ids.add(row.optString("id"));return ids;}
    static JSONObject task(String course,int offset,String id)throws Exception{return Planner.task(course,Planner.at(DAY.plusDays(offset),600),60).put("id",id);}
    static void visibilityAndTotals()throws Exception{
        JSONObject state=PlannerTests.empty(),active=PlannerTests.course("Active",120,DAY,DAY.plusDays(7),60),archived=PlannerTests.course("Archived",120,DAY,DAY.plusDays(7),60).put("isArchived",true);
        state.getJSONArray("courses").put(active).put(archived);
        String a=active.getString("id"),b=archived.getString("id");
        state.getJSONArray("tasks").put(task(a,0,"active")).put(task(b,1,"hidden-archive")).put(task("missing",2,"hidden-orphan"))
            .put(task(b,0,"archived-history").put("status","completed").put("completedMinutes",60).put("confirmedAt",Planner.at(DAY,720)))
            .put(task("missing",3,"orphan-history").put("status","missed").put("confirmedAt",Planner.at(DAY.plusDays(3),720)));
        String before=SyncLedger.canonical(state);CalendarDay agenda=new CalendarDay(state,DAY);
        check(agenda.taskDates.equals(new HashSet<>(Arrays.asList(DAY,DAY.plusDays(3)))),"Hidden pending tasks still mark the calendar");
        check(ids(agenda.tasks).equals(Arrays.asList("active","archived-history")),"Archive removed recorded history or retained pending tasks");
        check(ids(agenda.timeline).equals(Collections.singletonList("active")),"History appears in pending timeline");
        check(agenda.plannedMinutes==60,"Recorded time counted as pending");
        check(agenda.course(a)==active&&agenda.course("missing")==null,"Course index mismatch");
        check(new CalendarDay(state,DAY.plusDays(3)).tasks.size()==1,"Orphaned history hidden");
        check(before.equals(SyncLedger.canonical(state)),"Calendar projection mutated state");
        try{agenda.tasks.clear();throw new AssertionError("Mutable tasks");}catch(UnsupportedOperationException expected){checks++;}
        try{agenda.taskDates.clear();throw new AssertionError("Mutable markers");}catch(UnsupportedOperationException expected){checks++;}
        state.put("tasks",new JSONArray().put(task(a,0,"large-a").put("durationMinutes",Integer.MAX_VALUE))
            .put(task(a,0,"large-b").put("durationMinutes",Integer.MAX_VALUE)));
        check(new CalendarDay(state,DAY).plannedMinutes==2L*Integer.MAX_VALUE,"Pending minutes overflowed 32 bits");
        check(agenda.plannedMinutes==60,"Existing projection changed after replacing state arrays");
    }
    static void fixedRulesAndOrdering()throws Exception{
        JSONObject state=DayAgendaTextTests.fixture();JSONObject task=state.getJSONArray("tasks").getJSONObject(0);task.put("start",Planner.at(DAY,540));
        JSONObject event=state.getJSONArray("fixedEvents").getJSONObject(0);
        state.getJSONArray("fixedEvents").put(CourseTools.copy(event).put("id","skipped").put("excludedDates",new JSONArray().put(Planner.at(DAY,0))));
        CalendarDay agenda=new CalendarDay(state,DAY);
        check(agenda.timeline.size()==2&&agenda.timeline.get(0)==event&&agenda.timeline.get(1)==task,"Equal-time event/task order is unstable");
        check(ids(agenda.skipped).equals(Collections.singletonList("skipped"))&&agenda.events.size()==1,"Skipped event not separated");
        check(new CalendarDay(state,DAY.plusDays(1)).events.isEmpty(),"One-off event repeated");
        event.put("floatingDurationMinutes",JSONObject.NULL);
        check(DayAgendaText.make(state,DAY).contains("实验 · 固定事项"),"JSON null floating duration blocks copy");
    }
    static void indexedCourses()throws Exception{
        JSONObject state=PlannerTests.empty();
        class CountedCourse extends JSONObject {
            int idReads;
            @Override public String getString(String key)throws JSONException{if(key.equals("id"))idReads++;return super.getString(key);}
        }
        List<CountedCourse> courses=new ArrayList<>();
        for(int i=0;i<1000;i++){
            CountedCourse course=new CountedCourse();course.put("id","course-"+i).put("name","Course "+i);courses.add(course);
            state.getJSONArray("courses").put(course);state.getJSONArray("tasks").put(task("course-"+i,0,"task-"+i));
        }
        CalendarDay agenda=new CalendarDay(state,DAY);
        check(agenda.tasks.size()==1000&&agenda.plannedMinutes==60000,"Indexed catalog lost tasks");
        for(int i=0;i<1000;i++)check(agenda.course("course-"+i)==courses.get(i)&&courses.get(i).idReads==1,"Course lookup rescanned catalog");
    }
    public static void main(String[]args)throws Exception{
        visibilityAndTotals();fixedRulesAndOrdering();indexedCourses();
        System.out.println("Calendar day: "+checks+" checks passed");
    }
}
