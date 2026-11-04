package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Read-only projection shared by the calendar and copied agenda. */
final class CalendarDay {
    final List<JSONObject> tasks, events, skipped, timeline;
    final Set<LocalDate> taskDates;
    final long plannedMinutes;
    private final Map<String,JSONObject> courses=new HashMap<>();
    JSONObject course(String id){return courses.get(id);}

    CalendarDay(JSONObject state,LocalDate day)throws Exception{
        for(JSONObject course:Planner.list(state.getJSONArray("courses")))courses.putIfAbsent(course.getString("id"),course);
        List<JSONObject> tasks=new ArrayList<>(),events=new ArrayList<>(),skipped=new ArrayList<>();
        Set<LocalDate> dates=new HashSet<>();long planned=0;
        for(JSONObject task:Planner.list(state.getJSONArray("tasks"))){
            JSONObject owner=course(task.getString("courseID"));boolean pending=Planner.pending(task);
            if(pending&&(owner==null||owner.optBoolean("isArchived")))continue;
            LocalDate date=Planner.day(task.getDouble("start"));dates.add(date);
            if(!date.equals(day))continue;
            tasks.add(task);if(pending)planned+=task.getInt("durationMinutes");
        }
        for(JSONObject event:Planner.list(state.getJSONArray("fixedEvents")))
            if(Planner.occurs(event,day,true))(Planner.occurs(event,day)?events:skipped).add(event);
        tasks.sort(Comparator.comparingDouble((JSONObject task)->task.optDouble("start")).thenComparing(task->task.optString("id")));
        Comparator<JSONObject> eventOrder=Comparator.comparingInt((JSONObject event)->event.optInt("startMinute")).thenComparing(event->event.optString("id"));
        events.sort(eventOrder);skipped.sort(eventOrder);
        List<JSONObject> timeline=new ArrayList<>(events);
        for(JSONObject task:tasks)if(Planner.pending(task))timeline.add(task);
        timeline.sort(Comparator.comparingDouble((JSONObject item)->item.has("courseID")?item.optDouble("start"):Planner.at(day,item.optInt("startMinute")))
            .thenComparing(item->(item.has("courseID")?"task-":"event-")+item.optString("id")));
        this.tasks=Collections.unmodifiableList(tasks);this.events=Collections.unmodifiableList(events);
        this.skipped=Collections.unmodifiableList(skipped);this.timeline=Collections.unmodifiableList(timeline);
        taskDates=Collections.unmodifiableSet(dates);plannedMinutes=planned;
    }
}
