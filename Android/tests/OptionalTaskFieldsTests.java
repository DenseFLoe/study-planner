package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.*;

public final class OptionalTaskFieldsTests {
    static final LocalDate DAY=LocalDate.of(2026,11,4);
    static final double NOW=Planner.at(DAY,480);
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject fixture()throws Exception{
        JSONObject state=PlannerTests.empty(),course=PlannerTests.course("Optional fields",120,DAY,DAY.plusDays(3),60);
        state.getJSONArray("courses").put(course);
        for(int weekday=1;weekday<=7;weekday++)state.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(weekday,480,1080));
        state.getJSONArray("tasks").put(Planner.task(course.getString("id"),NOW+3600,60)
            .put("confirmedAt",JSONObject.NULL).put("floatingWindowStart",JSONObject.NULL).put("floatingWindowEnd",JSONObject.NULL));
        return state;
    }
    static JSONObject first(JSONObject state)throws Exception{return state.getJSONArray("tasks").getJSONObject(0);}
    static void optionalSemantics()throws Exception{
        JSONObject state=fixture(),task=first(state);String before=SyncLedger.canonical(state);
        Planner.validate(state);
        check(Planner.pending(task)&&!Planner.hasConfirmationTime(task),"Null confirmation time became a confirmation");
        check(!Planner.floatingTask(task),"Null windows became floating");
        check(Planner.planningStart(task)==task.getDouble("start")&&Planner.planningEnd(task)==Planner.end(task),"Null window fallback changed");
        check(DayAgendaText.make(state,DAY).contains("未确认")&&!DayAgendaText.make(state,DAY).contains("预估"),"Copied agenda mislabels null optional values");
        check(TaskSearch.find(state,"Optional",TaskSearch.Scope.UPCOMING,NOW).count()==1,"Null confirmation hid upcoming task");
        check(ConfirmationDraft.Undo.captureRecorded(state,Planner.list(state.getJSONArray("tasks"))).isEmpty(),"Null confirmation produced undo action");
        try{Planner.undoConfirmation(state,task.getString("id"),NOW);throw new AssertionError("Null confirmation could be undone");}catch(IllegalArgumentException expected){checks++;}
        check(before.equals(SyncLedger.canonical(state)),"Read or rejected undo mutated task");
        task.put("floatingWindowStart",NOW);check(!Planner.floatingTask(task)&&Planner.planningStart(task)==NOW,"One-sided window semantics changed");
        task.put("floatingWindowEnd",NOW+7200);check(Planner.floatingTask(task),"Valid floating window not recognized");
        task.put("confirmedAt",0);check(Planner.hasConfirmationTime(task)&&!Planner.pending(task),"Zero reference timestamp mistaken for null");
    }
    static void backupAndReplan()throws Exception{
        JSONObject state=fixture();String raw=SyncLedger.canonical(state);
        PlannerBackupFile backup=PlannerBackupFile.read(new ByteArrayInputStream(state.toString().getBytes(StandardCharsets.UTF_8)));
        check(raw.equals(SyncLedger.canonical(backup.state())),"Backup read normalized or removed unrelated optional values");
        JSONObject opened=backup.state();Planner.prepareForOpen(opened,NOW);
        check(opened.getJSONArray("completions").length()==0,"Opening null fields invented progress");
        check(Planner.remaining(opened,opened.getJSONArray("courses").getJSONObject(0))==120,"Opening lost remaining work");
        check(!Planner.list(opened.getJSONArray("tasks")).isEmpty()&&Planner.list(opened.getJSONArray("tasks")).stream().allMatch(Planner::pending),"Null fields block valid replanning");
    }
    static void confirmationAndLedgerRecovery()throws Exception{
        JSONObject state=fixture();String id=first(state).getString("id");
        SyncLedger base=new SyncLedger();base.capture(state,1000);JSONObject opened=base.materialize();
        check(opened.getJSONArray("completions").length()==0&&Planner.pending(first(opened)),"Ledger invented a null confirmation");
        check(first(opened).has("confirmedAt")&&first(opened).isNull("confirmedAt"),"Ledger unnecessarily rewrote null payload");
        ConfirmationDraft draft=new ConfirmationDraft(Collections.singletonList(first(opened)));
        draft.apply(opened,Collections.singletonMap(id,20),Collections.singletonMap(id,DAY),NOW+1800);
        check(Planner.hasConfirmationTime(first(opened))&&opened.getJSONArray("completions").getJSONObject(0).getInt("minutes")==20,"Real confirmation not applied");
        JSONObject completion=opened.getJSONArray("completions").getJSONObject(0);completion.put("studyDate",JSONObject.NULL);
        check(DailyConsequences.effectiveDay(completion,opened).equals(DAY),"Null study date lost same-day legacy attribution");
        SyncLedger confirmed=new SyncLedger(CourseTools.copy(base.value));confirmed.capture(opened,3000);
        SyncLedger deleted=new SyncLedger(CourseTools.copy(base.value));JSONObject removed=deleted.materialize();removed.put("tasks",new JSONArray());deleted.capture(removed,2000);
        deleted.merge(confirmed.changes(0));JSONObject merged=deleted.materialize();
        check(merged.getJSONArray("completions").length()==1&&merged.getJSONArray("completions").getJSONObject(0).getInt("minutes")==20,"Late real confirmation was lost after null draft deletion");
        check(Planner.remaining(merged,merged.getJSONArray("courses").getJSONObject(0))==100,"Merge changed credited minutes");
        ConfirmationDraft.Undo undo=new ConfirmationDraft.Undo(merged,first(merged));undo.apply(merged,NOW+3600);
        check(Planner.pending(first(merged))&&merged.getJSONArray("completions").length()==0,"Real confirmation could not be undone");
    }
    static void nullLessonSyncAndRecovery()throws Exception{
        JSONObject state=fixture(),task=first(state);task.put("lessonID",JSONObject.NULL).put("lessonName",JSONObject.NULL);
        String before=SyncLedger.canonical(state);
        check(!Planner.hasLessonID(task),"Null lesson ID became a real lesson");
        check(!SyncExchange.invalidPending(state,NOW),"Valid whole-course null lesson task needs replanning");
        check(before.equals(SyncLedger.canonical(state)),"Sync validation mutated null fields");
        SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);
        JSONObject restored=SyncExchange.repairMergedSchedule(ledger,NOW);
        check(first(restored).getString("id").equals(task.getString("id"))&&first(restored).isNull("lessonID"),"Cloud repair rewrote a valid null lesson task");
        JSONObject absent=CourseTools.copy(task);absent.remove("lessonID");absent.remove("lessonName");
        check(SyncExchange.taskSlot(task).equals(SyncExchange.taskSlot(absent)),"Null and absent lesson IDs create different sync slots");
        JSONObject real=CourseTools.copy(task).put("lessonID","whole");
        check(Planner.hasLessonID(real)&&!SyncExchange.taskSlot(task).equals(SyncExchange.taskSlot(real)),"Real lesson ID lost its identity");

        JSONObject course=state.getJSONArray("courses").getJSONObject(0);String courseID=course.getString("id");
        state.put("tasks",new JSONArray());
        for(int offset:new int[]{-7200,-3600})state.getJSONArray("tasks").put(Planner.task(courseID,NOW+offset,60)
            .put("lessonID",JSONObject.NULL).put("confirmedAt",NOW).put("status","missed"));
        state.getJSONArray("tasks").put(Planner.task(courseID,NOW+3600,120));
        JSONObject nullResult=ScheduleHealth.assess(state,NOW,120);
        check(nullResult.getJSONArray("recovery").getJSONObject(0).getInt("plannedMinutes")==120,"Null IDs collapsed two missed whole-course blocks into one");
        for(JSONObject item:Planner.list(state.getJSONArray("tasks")))item.remove("lessonID");
        check(SyncLedger.equivalent(nullResult,ScheduleHealth.assess(state,NOW,120)),"Null and absent lesson IDs produce different recovery forecasts");
    }
    public static void main(String[]args)throws Exception{
        optionalSemantics();backupAndReplan();confirmationAndLedgerRecovery();nullLessonSyncAndRecovery();
        System.out.println("Optional task fields: "+checks+" checks passed");
    }
}
