package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class DayAgendaTextTests {
    static final LocalDate DAY=LocalDate.of(2026,11,4);
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static double at(int minute){return Planner.at(DAY,minute);}
    static JSONObject fixture()throws Exception{
        JSONObject state=PlannerTests.empty();
        JSONObject course=PlannerTests.course("数学\n二",240,DAY,DAY.plusDays(1),60).put("notes","private-course-note https://private.invalid");
        state.getJSONArray("courses").put(course);
        state.getJSONArray("tasks").put(Planner.task(course.getString("id"),at(600),60).put("lessonName","第一讲\t极限"));
        state.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.id()).put("title","实验")
            .put("startMinute",540).put("endMinute",570).put("startDate",at(0)).put("endDate",at(0))
            .put("weekdays",new JSONArray()).put("excludedDates",new JSONArray()).put("notes","private-event-note"));
        return state;
    }
    static String text(JSONObject state)throws Exception{return DayAgendaText.make(state,DAY);}
    static void normalAndHistory()throws Exception{
        JSONObject state=fixture();String before=SyncLedger.canonical(state),result=text(state);
        check(result.startsWith("学习日程 · 2026-11-04 星期三\n时区：Asia/Shanghai"),"Local day or zone missing");
        check(result.contains("09:00–09:30 · 实验 · 固定事项\n• 10:00–11:00 · 数学 二 / 第一讲 极限 · 计划 60 分钟 · 未确认"),"Timeline order, task status or single-line names wrong");
        check(!result.contains("private"),"Notes or URLs exported");
        check(before.equals(SyncLedger.canonical(state)),"Formatting mutated state");
        state.getJSONArray("courses").getJSONObject(0).put("isArchived",true);
        JSONObject original=state.getJSONArray("tasks").getJSONObject(0);
        for(int minutes:new int[]{60,20,0})state.getJSONArray("tasks").put(CourseTools.copy(original).put("id",Planner.id())
            .put("status",minutes==60?"completed":minutes==0?"missed":"partial").put("confirmedAt",at(1200)).put("completedMinutes",minutes));
        result=text(state);
        check(!result.contains("未确认"),"Archived pending task exported");
        check(result.contains("已确认 60 分钟")&&result.contains("已确认 20 分钟")&&result.contains(" · 未完成"),"Recorded statuses lost");
        check(result.contains("完成记录按原计划日期列出，不代表当天实际学习总量。"),"History is ambiguous with actual study date");
        state.put("courses",new JSONArray());result=text(state);
        check(result.contains("已删除课程 / 第一讲 极限")&&!result.contains("未确认"),"Missing course history or pending visibility wrong");
    }
    static void floatingSkippedAndDates()throws Exception{
        JSONObject state=fixture(),task=state.getJSONArray("tasks").getJSONObject(0),event=state.getJSONArray("fixedEvents").getJSONObject(0);
        task.put("floatingWindowStart",at(600)).put("floatingWindowEnd",at(780));
        event.put("endMinute",600).put("floatingDurationMinutes",30);
        state.getJSONArray("fixedEvents").put(CourseTools.copy(event).put("id",Planner.id()).put("title","已跳过")
            .put("excludedDates",new JSONArray().put(at(100))));
        String result=text(state);
        check(result.contains("预估 10:00–11:00")&&result.contains("完成窗口：10:00–13:00"),"Floating task estimates confused with window");
        check(result.contains("09:00–10:00 · 实验 · 浮动窗口，需 30 分钟"),"Floating event duration confused with window");
        check(result.contains("本日已临时移除\n• 09:00–10:00 · 已跳过 · 浮动窗口，需 30 分钟 · 本日不占用时间"),"Skipped occurrence included as active");
        check(result.split("已跳过",-1).length==2,"Skipped event repeated");
        state=fixture();task=state.getJSONArray("tasks").getJSONObject(0);task.put("start",at(1410));
        state.getJSONArray("tasks").put(CourseTools.copy(task).put("id",Planner.id()).put("start",at(1440)).put("lessonName","明日课程"));
        state.getJSONArray("fixedEvents").getJSONObject(0).put("endMinute",1440);
        result=text(state);
        check(result.contains("23:30–2026-11-05 00:30"),"Cross-midnight date lost");
        check(result.contains("09:00–24:00")&&!result.contains("明日课程"),"Local midnight day boundary wrong");
        String tomorrow=DayAgendaText.make(state,DAY.plusDays(1));
        check(tomorrow.contains("明日课程")&&!tomorrow.contains("实验"),"One-off event repeated on next day");
        check(text(PlannerTests.empty()).endsWith("这一天没有待进行的安排"),"Empty day not explained");
    }
    static void orderingAndUnusualWhitespace()throws Exception{
        JSONObject state=fixture();JSONObject first=state.getJSONArray("tasks").getJSONObject(0);
        JSONObject second=CourseTools.copy(first).put("id",Planner.id()).put("lessonName","第二讲");
        state.getJSONArray("tasks").put(second);
        JSONObject later=CourseTools.copy(state.getJSONArray("fixedEvents").getJSONObject(0)).put("id",Planner.id()).put("title","下次实验")
            .put("weekdays",new JSONArray().put(5)).put("endDate",at(7*1440));state.getJSONArray("fixedEvents").put(later);
        String expected=text(state);check(!expected.contains("下次实验"),"Wrong recurring weekday exported");
        state.put("tasks",new JSONArray(Arrays.asList(second,first)));
        List<JSONObject> events=Planner.list(state.getJSONArray("fixedEvents"));Collections.reverse(events);state.put("fixedEvents",new JSONArray(events));
        check(text(state).equals(expected),"Equal-time ordering depends on storage order");
        first.put("lessonName","　第一讲\u00a0\u2028极限　");
        check(text(state).contains(" / 第一讲 极限 · "),"Unicode whitespace creates fake agenda lines");
    }
    public static void main(String[]args)throws Exception{
        normalAndHistory();floatingSkippedAndDates();orderingAndUnusualWhitespace();
        System.out.println("Day agenda text: "+checks+" checks passed");
    }
}
