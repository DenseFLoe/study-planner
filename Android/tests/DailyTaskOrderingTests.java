package local.studyplanner;

import org.json.*;
import java.io.*;
import java.time.LocalDate;
import java.util.*;

public final class DailyTaskOrderingTests {
    static final LocalDate DAY = LocalDate.of(2026, 10, 5);
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }

    static JSONObject fixture(int nextMinute) throws Exception {
        JSONObject state = PlannerTests.empty();
        state.getJSONObject("settings").put("availability", new JSONArray()
            .put(PlannerTests.window(2, 1320, 1370)).put(PlannerTests.window(2, 1380, 1440))
            .put(PlannerTests.window(3, 0, 60)));
        int[] lengths = {50, 30, 30};
        for (int i = 0; i < lengths.length; i++) {
            JSONObject course = PlannerTests.course("跨日合成课" + i, lengths[i], DAY, DAY.plusDays(1), lengths[i]);
            state.getJSONArray("courses").put(course);
            double start = i == 2 ? Planner.at(DAY.plusDays(1), nextMinute) : Planner.at(DAY, 1320 + i * 60);
            state.getJSONArray("tasks").put(Planner.task(course.getString("id"), start, lengths[i]));
        }
        return state;
    }

    static JSONObject floatingFixture() throws Exception {
        JSONObject state=PlannerTests.empty();
        state.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(2,480,720));
        for(int minutes:new int[]{30,90}){
            JSONObject course=PlannerTests.course("Floating swap "+minutes,minutes,DAY,DAY,minutes);
            state.getJSONArray("courses").put(course);
            state.getJSONArray("tasks").put(Planner.task(course.getString("id"),Planner.at(DAY,minutes==30?480:570),minutes));
        }
        for(boolean floating:new boolean[]{false,true}){
            JSONObject event=new JSONObject().put("id",Planner.id()).put("title","Swap fixture")
                .put("startMinute",floating?480:540).put("endMinute",floating?720:570)
                .put("startDate",Planner.at(DAY,0)).put("endDate",Planner.at(DAY,0)).put("weekdays",new JSONArray());
            if(floating)event.put("floatingDurationMinutes",60);
            state.getJSONArray("fixedEvents").put(event);
        }
        return state;
    }

    static void jointFloatingSwap() throws Exception {
        JSONObject state=floatingFixture(),before=CourseTools.copy(state);
        List<JSONObject> original=PlannerTests.sortedTasks(state);
        DailyTaskOrdering.swap(state,original.get(0).getString("id"),original.get(1).getString("id"),Planner.at(DAY,420));
        List<JSONObject> placed=PlannerTests.sortedTasks(state);
        for(int i=0;i<2;i++){
            check(placed.get(i).getString("id").equals(original.get(1-i).getString("id")),"Joint swap changed task identity or order");
            check(placed.get(i).getInt("durationMinutes")==original.get(1-i).getInt("durationMinutes"),"Joint swap changed task duration");
            check(placed.get(i).has("floatingWindowStart"),"Joint swap lost the floating window");
        }
        check(placed.get(0).getDouble("start")==Planner.at(DAY,570)&&placed.get(1).getDouble("start")==Planner.at(DAY,675),"Feasible floating positions were not found");
        check(placed.get(1).getDouble("start")-Planner.end(placed.get(0))==900,"Joint swap shortened the break");
        check(state.getJSONArray("fixedEvents").similar(before.getJSONArray("fixedEvents")),"Swap persisted the floating witness as an event edit");
        List<JSONObject> replay=DailyTaskOrdering.apply(state,original,Collections.emptyList());
        check(new JSONArray(replay).similar(new JSONArray(placed)),"Saved order lost its joint floating placement");

        for(boolean overBudget:new boolean[]{false,true}){
            JSONObject rejected=floatingFixture();
            if(overBudget){
                // Nine same-day floating events exceed the existing bounded search scope.
                for(int i=0;i<8;i++)rejected.getJSONArray("fixedEvents").put(new JSONObject()
                    .put("id",Planner.id()).put("title","Budget fixture").put("startMinute",i*2).put("endMinute",i*2+1)
                    .put("floatingDurationMinutes",1).put("startDate",Planner.at(DAY,0)).put("endDate",Planner.at(DAY,0)).put("weekdays",new JSONArray()));
            }else rejected.getJSONObject("settings").getJSONArray("availability").getJSONObject(0).put("endMinute",704);
            String unchanged=rejected.toString();List<JSONObject> tasks=PlannerTests.sortedTasks(rejected);
            try{
                DailyTaskOrdering.swap(rejected,tasks.get(0).getString("id"),tasks.get(1).getString("id"),Planner.at(DAY,420));
                throw new AssertionError("Unavailable joint search accepted a swap");
            }catch(IllegalArgumentException expected){check(expected.getMessage().equals(DailyTaskOrdering.NO_SPACE),"Wrong joint failure");}
            check(rejected.toString().equals(unchanged),"Failed joint search mutated state");
        }
        for(int minutes:new int[]{45,46}){
            JSONObject withHistory=floatingFixture();
            List<JSONObject> moving=PlannerTests.sortedTasks(withHistory);
            moving.get(0).put("start",Planner.at(DAY,minutes==45?480:481));
            JSONObject course=PlannerTests.course("Retained history",minutes,DAY,DAY,minutes);
            withHistory.getJSONArray("courses").put(course);
            JSONObject history=Planner.task(course.getString("id"),Planner.at(DAY,420),minutes);
            withHistory.getJSONArray("tasks").put(history);
            Planner.confirm(withHistory,history.getString("id"),minutes,Planner.at(DAY,420+minutes));
            JSONObject beforeHistory=CourseTools.copy(withHistory);String originalHistory=history.toString();
            try{
                DailyTaskOrdering.swap(withHistory,moving.get(0).getString("id"),moving.get(1).getString("id"),Planner.at(DAY,470));
                check(minutes==45,"Joint witness ignored retained history rest");
                check(PlannerTests.sortedTasks(withHistory).get(0).toString().equals(originalHistory),"Joint swap changed retained history");
            }catch(IllegalArgumentException expected){
                check(minutes==46,"Exact history rest boundary was rejected");
                check(SyncLedger.equivalent(withHistory,beforeHistory),"History rejection changed state");
            }
        }
    }

    static JSONObject dailyDurationFixture(int duration,boolean floating)throws Exception {
        LocalDate day=LocalDate.of(2026,11,3);double now=Planner.at(day,480);
        JSONObject state=SyncExchangeTests.fixture(now),course=state.getJSONArray("courses").getJSONObject(0);
        state.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(Planner.weekday(day),480,floating?540:1200)));
        state.put("tasks",new JSONArray().put(Planner.task(course.getString("id"),now,60).put("lessonID","ordinary"))
            .put(Planner.task(course.getString("id"),now+4500,duration).put("lessonID","oversized")));
        if(floating)state.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.id()).put("title","Reserved hour")
            .put("startMinute",480).put("endMinute",540).put("floatingDurationMinutes",60).put("startDate",now).put("endDate",now)
            .put("weekdays",new JSONArray()).put("excludedDates",new JSONArray()).put("color","blue").put("notes",""));
        return state;
    }

    static void importedOversizedDurations()throws Exception {
        for(int duration:new int[]{1441,Integer.MAX_VALUE})for(boolean floating:new boolean[]{false,true})for(boolean reverse:new boolean[]{false,true}){
            JSONObject input=dailyDurationFixture(duration,floating);
            if(reverse){input.getJSONArray("tasks").getJSONObject(0).put("durationMinutes",duration);input.getJSONArray("tasks").getJSONObject(1).put("durationMinutes",60);}
            SyncLedger ledger=new SyncLedger();ledger.capture(input);
            JSONObject state=ledger.materialize();ByteArrayOutputStream bytes=new ByteArrayOutputStream();
            CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
            List<JSONObject> tasks=PlannerTests.sortedTasks(state);check(tasks.get(reverse?0:1).getInt("durationMinutes")==duration,"ingress changed oversized duration");
            String before=state.toString();
            try{DailyTaskOrdering.swap(state,tasks.get(0).getString("id"),tasks.get(1).getString("id"),tasks.get(0).getDouble("start"));throw new AssertionError("Oversized daily task accepted");}
            catch(IllegalArgumentException expected){check(expected.getMessage().equals(DailyTaskOrdering.NO_SPACE),"Oversized daily task used wrong failure");}
            check(before.equals(state.toString()),"Oversized swap changed tasks, history, events or saved order");
        }
    }

    static void dailyPlacementDurationBounds()throws Exception {
        LocalDate day=LocalDate.of(2026,11,3);double midnight=Planner.at(day,0);
        // Planner uses Asia/Shanghai; this fixture is a full 1440-minute day
        // without an offset transition, matching the Swift UTC boundary case.
        check(Planner.at(day.plusDays(1),0)-midnight==86400,"Full-day fixture crosses an offset transition");
        JSONObject state=SyncExchangeTests.fixture(midnight),course=state.getJSONArray("courses").getJSONObject(0);
        course.put("totalMinutes",1440);state.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(Planner.weekday(day),0,1440)));
        JSONObject fullDay=Planner.task(course.getString("id"),midnight,1440);state.put("tasks",new JSONArray().put(fullDay));String before=state.toString();
        List<JSONObject> placed=DailyTaskOrdering.place(state,Collections.singletonList(fullDay),midnight);
        check(placed!=null&&placed.size()==1&&SyncLedger.equivalent(placed.get(0),fullDay),"Full 1440-minute daily block no longer fits");
        check(Planner.end(placed.get(0))==Planner.at(day.plusDays(1),0),"Full-day placement changed end");
        check(DailyTaskOrdering.place(state,Collections.emptyList(),midnight).isEmpty(),"Empty daily placement changed");
        for(int duration:new int[]{0,-1,Integer.MIN_VALUE,1441,Integer.MAX_VALUE}){
            JSONObject invalid=new JSONObject(fullDay.toString()).put("durationMinutes",duration);
            check(DailyTaskOrdering.place(state,Collections.singletonList(invalid),midnight)==null,"Invalid daily duration accepted: "+duration);
        }
        check(before.equals(state.toString()),"Direct daily placement changed input");
    }

    static void oversizedSavedOrder()throws Exception {
        JSONObject state=dailyDurationFixture(Integer.MAX_VALUE,false);List<JSONObject> tasks=PlannerTests.sortedTasks(state);
        List<String> keys=DailyTaskOrdering.keys(tasks);Collections.reverse(keys);
        state.getJSONObject("settings").put("dailyTaskOrders",new JSONArray().put(new JSONObject()
            .put("day",Planner.at(Planner.day(tasks.get(0).getDouble("start")),0)).put("keys",new JSONArray(keys))));
        String before=state.toString();List<JSONObject> result=DailyTaskOrdering.apply(state,tasks,Collections.emptyList());
        check(SyncLedger.equivalent(new JSONArray(result),new JSONArray(tasks)),"Impossible saved order rewrote generated tasks");
        check(before.equals(state.toString()),"Impossible saved order changed input");
    }

    public static void main(String[] args) throws Exception {
        importedOversizedDurations();dailyPlacementDurationBounds();oversizedSavedOrder();
        jointFloatingSwap();
        JSONObject state = fixture(0);
        String original = state.toString();
        try {
            DailyTaskOrdering.swap(state, state.getJSONArray("tasks").getJSONObject(0).getString("id"),
                state.getJSONArray("tasks").getJSONObject(1).getString("id"), Planner.at(DAY, 1260));
            throw new AssertionError("Swap shortened the midnight break to ten minutes");
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().equals(DailyTaskOrdering.NO_SPACE), "Wrong rejection");
            check(state.toString().equals(original), "Rejected swap mutated state");
        }
        state = fixture(5);
        JSONObject nextDay = new JSONObject(state.getJSONArray("tasks").getJSONObject(2).toString());
        DailyTaskOrdering.swap(state, state.getJSONArray("tasks").getJSONObject(0).getString("id"),
            state.getJSONArray("tasks").getJSONObject(1).getString("id"), Planner.at(DAY, 1260));
        List<JSONObject> tasks = PlannerTests.sortedTasks(state);
        check(nextDay.similar(tasks.get(2)), "Swap changed next day's task");
        check(nextDay.getDouble("start") - Planner.end(tasks.get(1)) == 900, "Exact 15-minute boundary rejected");
        for (boolean storedDrafts : new boolean[]{false, true}) {
            state = fixture(0);
            List<JSONObject> generated = PlannerTests.sortedTasks(state);
            List<String> keys = DailyTaskOrdering.keys(generated.subList(0, 2));
            Collections.reverse(keys);
            state.getJSONObject("settings").put("dailyTaskOrders", new JSONArray().put(new JSONObject()
                .put("day", Planner.at(DAY, 0)).put("keys", new JSONArray(keys))));
            if (!storedDrafts) state.put("tasks", new JSONArray());
            List<JSONObject> result = DailyTaskOrdering.apply(state, generated, Collections.emptyList());
            check(new JSONArray(result).similar(new JSONArray(generated)), "Saved order ignored next day's generated work");
        }
        System.out.println("DailyTaskOrderingTests: " + checks + " checks passed");
    }
}
