package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.*;

/** Read-only text for the selected calendar day, without notes or source metadata. */
final class DayAgendaText {
    private static final class Row {
        final double start; final String id, text;
        Row(double start, String id, String text) { this.start=start; this.id=id; this.text=text; }
    }
    private static String oneLine(String value) {
        return value.replaceAll("[\\p{javaWhitespace}\\p{Z}]+", " ").trim();
    }
    private static String clock(double instant, LocalDate day) {
        return (Planner.day(instant).equals(day)?"":Planner.date(instant)+" ")+Planner.clock(instant);
    }
    private static String range(double start, double end, LocalDate day) {
        return clock(start,day)+"–"+clock(end,day);
    }
    private static void append(List<String> lines, String heading, List<Row> rows) {
        if(rows.isEmpty())return;
        rows.sort(Comparator.comparingDouble((Row row)->row.start).thenComparing(row->row.id));
        lines.add("");lines.add(heading);
        for(Row row:rows)lines.add("• "+row.text);
    }
    static String make(JSONObject state, LocalDate day) throws Exception {
        Map<String,JSONObject> courses=new HashMap<>();
        for(JSONObject course:Planner.list(state.getJSONArray("courses")))courses.putIfAbsent(course.getString("id"),course);
        List<Row> planned=new ArrayList<>(),history=new ArrayList<>(),skipped=new ArrayList<>();
        for(JSONObject task:Planner.list(state.getJSONArray("tasks"))){
            double start=task.getDouble("start");if(!Planner.day(start).equals(day))continue;
            JSONObject course=courses.get(task.getString("courseID"));boolean pending=Planner.pending(task);
            if(pending&&(course==null||course.optBoolean("isArchived")))continue;
            String title=oneLine(course==null?"已删除课程":course.getString("name")),lesson=oneLine(task.optString("lessonName"));
            if(!lesson.isEmpty())title+=" / "+lesson;
            String text=(Planner.floatingTask(task)?"预估 ":"")+range(start,Planner.end(task),day)+" · "+title+
                " · 计划 "+task.getInt("durationMinutes")+" 分钟";
            if(Planner.floatingTask(task))text+=" · 完成窗口："+range(Planner.planningStart(task),Planner.planningEnd(task),day);
            text+=pending?" · 未确认":task.optInt("completedMinutes")==0?" · 未完成":" · 已确认 "+task.getInt("completedMinutes")+" 分钟";
            Row row=new Row(start,"task-"+task.getString("id"),text);(pending?planned:history).add(row);
        }
        for(JSONObject event:Planner.list(state.getJSONArray("fixedEvents"))){
            if(!Planner.occurs(event,day,true))continue;
            boolean excluded=!Planner.occurs(event,day);
            String text=Planner.time(event.getInt("startMinute"))+"–"+Planner.time(event.getInt("endMinute"))+" · "+oneLine(event.getString("title"));
            text+=event.has("floatingDurationMinutes")?" · 浮动窗口，需 "+event.getInt("floatingDurationMinutes")+" 分钟":" · 固定事项";
            if(excluded)text+=" · 本日不占用时间";
            (excluded?skipped:planned).add(new Row(Planner.at(day,event.getInt("startMinute")),"event-"+event.getString("id"),text));
        }
        List<String> lines=new ArrayList<>();
        lines.add("学习日程 · "+day.format(DateTimeFormatter.ofPattern("yyyy-MM-dd EEEE",Locale.CHINA)));
        lines.add("时区："+Planner.ZONE.getId());
        if(planned.isEmpty()){lines.add("");lines.add("这一天没有待进行的安排");}else append(lines,"待进行的安排",planned);
        append(lines,"原计划对应的完成记录",history);
        if(!history.isEmpty())lines.add("完成记录按原计划日期列出，不代表当天实际学习总量。");
        append(lines,"本日已临时移除",skipped);
        return String.join("\n",lines);
    }
}
