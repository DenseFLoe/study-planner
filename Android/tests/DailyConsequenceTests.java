package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;

public final class DailyConsequenceTests {
    static int checks;static final LocalDate DAY=LocalDate.of(2026,9,14);static final double NOW=Planner.at(DAY,480);
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject state(int... minutes)throws Exception{
        JSONObject state=PlannerTests.empty(),course=PlannerTests.course("模拟课程",Arrays.stream(minutes).sum(),DAY,DAY,60).put("type","不定时录播课程").put("color","blue").put("notes","");
        JSONArray lessons=new JSONArray();for(int i=0;i<minutes.length;i++)lessons.put(new JSONObject().put("id","lesson"+i).put("name","第"+i+"节").put("durationMinutes",minutes[i]));
        course.put("manualLessons",lessons);state.getJSONArray("courses").put(course);state.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(2,480,780));return state;
    }
    static JSONObject fixture()throws Exception{
        JSONObject state=state(60,60,60,60);state.getJSONArray("courses").getJSONObject(0).put("deadline",Planner.at(DAY.plusDays(2),0));
        JSONArray windows=new JSONArray();for(int w=1;w<=7;w++)windows.put(PlannerTests.window(w,480,615));state.getJSONObject("settings").put("availability",windows);Planner.replan(state,NOW);return state;
    }
    static JSONObject entry(JSONObject state)throws Exception{return DailyConsequences.capture(state,state,NOW,120);}
    static void health()throws Exception{
        JSONObject state=state(120,90);state.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.id()).put("title","浮动事项").put("startMinute",540).put("endMinute",720).put("floatingDurationMinutes",60).put("startDate",Planner.at(DAY,0)).put("endDate",Planner.at(DAY,0)).put("weekdays",new JSONArray()));
        Planner.replan(state,NOW);List<JSONObject> tasks=PlannerTests.sortedTasks(state);
        check(tasks.size()==2&&tasks.get(0).getInt("durationMinutes")==120&&tasks.get(1).getInt("durationMinutes")==90,"Joint floating placement lost whole lessons");
        check(tasks.get(1).getDouble("start")==Planner.at(DAY,660),"Joint search did not move floating placement");
        check(state.getJSONArray("androidConflicts").length()==0&&state.getJSONArray("androidRisks").length()==0,"Feasible floating plan was called a shortage");
        check(state.getJSONArray("androidAdjustments").length()>0,"Joint search adjustment missing");
        check(ScheduleHealth.assess(state,NOW,180).getString("kind").equals("heavy"),"Heavy day not distinguished");
        check(ScheduleHealth.assess(state,NOW,240).getString("kind").equals("scheduled"),"Display threshold did not change health");
        JSONObject pending=state(60,60);pending.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(2,480,600)));Planner.replan(pending,NOW);
        check(ScheduleHealth.assess(pending,NOW,480).getString("kind").equals("pending"),"Unplaced block falsely proved impossible");
        check(pending.getJSONArray("androidConflicts").length()==0,"Break-only failure falsely became proof");
        JSONObject shortage=state(90,90);shortage.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(2,480,600)));Planner.replan(shortage,NOW);
        check(ScheduleHealth.outcome(shortage,NOW,480).getInt("provenDeficit")==60,"Conservative deficit incorrect");
        JSONObject continuous=state(90);continuous.getJSONObject("settings").put("availability",new JSONArray().put(PlannerTests.window(2,480,540)).put(PlannerTests.window(2,600,660)));Planner.replan(continuous,NOW);
        JSONObject proof=ScheduleHealth.outcome(continuous,NOW,480);check(proof.getInt("minimumContinuousMinutes")==90&&!proof.has("provenDeficit"),"Continuous proof invented a minute deficit");
        JSONObject future=state(180);future.getJSONArray("courses").getJSONObject(0).put("startDate",Planner.at(DAY.plusDays(1),0)).put("deadline",Planner.at(DAY.plusDays(1),0));future.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(3,480,540));Planner.replan(future,NOW);
        check(ScheduleHealth.outcome(future,NOW,480).getInt("provenDeficit")==120,"Future release hid behind earlier free time");
        JSONObject paused=state(60);paused.getJSONArray("courses").getJSONObject(0).put("autoScheduleEnabled",false);Planner.replan(paused,NOW);JSONObject h=ScheduleHealth.assess(paused,NOW,480);
        check(h.getString("kind").equals("pending")&&h.getInt("pausedMinutes")==60,"Paused course falsely called impossible");
        JSONObject recovery=state(120,90);Planner.replan(recovery,NOW);String id=recovery.getJSONArray("tasks").getJSONObject(0).getString("id");Planner.confirm(recovery,id,45,Planner.at(DAY,540));Planner.replan(recovery,Planner.at(DAY,540));h=ScheduleHealth.assess(recovery,Planner.at(DAY,540),480);
        int n=0;for(JSONObject day:Planner.list(h.getJSONArray("recovery")))n+=day.getInt("plannedMinutes");check(n==75&&h.getInt("creditedMinutes")==45&&h.getInt("reviewedMinutes")==120,"Partial debt/credited minutes incorrect");
        JSONObject repeat=state(60);for(int i=0;i<2;i++){Planner.replan(repeat,NOW);Planner.confirm(repeat,repeat.getJSONArray("tasks").getJSONObject(i).getString("id"),0,NOW);}Planner.replan(repeat,NOW);
        n=0;for(JSONObject day:Planner.list(ScheduleHealth.assess(repeat,NOW,480).getJSONArray("recovery")))n+=day.getInt("plannedMinutes");check(n==60,"Repeated misses doubled recovery debt");
        List<ScheduleFeasibilitySearch.Queue> queues=Collections.singletonList(new ScheduleFeasibilitySearch.Queue(state.getJSONArray("courses").getJSONObject(0),Arrays.asList(new Planner.Work(120,"a","A"),new Planner.Work(90,"b","B"))));
        List<ScheduleFeasibilitySearch.Window> windows=Collections.singletonList(new ScheduleFeasibilitySearch.Window(480,780));check(ScheduleFeasibilitySearch.find(queues,windows,windows,Collections.emptyList(),480,0,0)==null,"Exhausted search returned a proof");
        String shared=state.getJSONArray("tasks").toString();Planner.refreshDiagnostics(state,NOW);check(shared.equals(state.getJSONArray("tasks").toString()),"Diagnostics replaced shared tasks");
    }
    static void forecasts()throws Exception{
        JSONObject state=fixture(),entry=entry(state);String before=DailyConsequences.canonical(state);
        check(entry.getInt("goalMinutes")==120&&DailyConsequences.fractions(entry).equals(Arrays.asList(0,250,500,750,1000)),"Daily target or bands incorrect");
        check(!DailyConsequences.achieved(entry,250,30)&&DailyConsequences.achieved(entry,250,31),"Equal threshold incorrectly passed");
        check(!DailyConsequences.achieved(entry,0,0)&&DailyConsequences.achieved(entry,0,1)&&DailyConsequences.achieved(entry,1000,120),"Milestone thresholds incorrect");
        check(DailyConsequences.fractions(CourseTools.copy(entry).put("goalMinutes",1)).equals(Arrays.asList(0,1000)),"Tiny goal bands not deduplicated");
        JSONObject zero=DailyConsequences.forecast(entry,0,10),full=DailyConsequences.forecast(entry,1000,10);
        check(zero.getJSONObject("firstDay").getString("kind").equals("scheduled")&&zero.getInt("provenLimitAfterDays")==2&&!zero.has("uncertainFromDay"),"Zero-study forecast differs from desktop");
        check(!full.has("provenLimitAfterDays")&&full.getJSONObject("firstDay").getString("kind").equals("scheduled"),"Full completion invented a hard limit");
        check(before.equals(DailyConsequences.canonical(state)),"Forecast changed real state");
        for(int f:DailyConsequences.fractions(entry))check(DailyConsequences.forecast(entry,f,10).getInt("fraction")==f,"A simultaneous band is missing");
        JSONObject task=state.getJSONArray("tasks").getJSONObject(0);Planner.confirm(state,task.getString("id"),31,Planner.at(DAY,540));Planner.replan(state,Planner.at(DAY,540));
        check(entry.getInt("goalMinutes")==120&&DailyConsequences.confirmed(DAY,state)==31,"Progress moved goal or lost actual minutes");
        check(DailyConsequences.revision(state,120).equals(entry.getString("revision"))&&DailyConsequences.valid(entry,state),"Real confirmation invalidated baseline");
        check(!DailyConsequences.forecast(DailyConsequences.capture(state,state,Planner.at(DAY,540),120),0,10).has("firstDay"),"Forecast withdrew prior confirmed work");
        JSONObject external=fixture(),baseline=entry(external);external.getJSONArray("courses").getJSONObject(0).put("initialCompletedMinutes",20);check(!DailyConsequences.valid(baseline,external),"External progress did not invalidate baseline");
        JSONObject undone=DailyConsequences.capture(state,state,Planner.at(DAY,540),120);Planner.undoConfirmation(state,task.getString("id"),Planner.at(DAY,550));check(!DailyConsequences.valid(undone,state),"Undo kept invalid forecast evidence");
        JSONObject changed=fixture(),snapshot=entry(changed);String revision=DailyConsequences.revision(changed,120);JSONArray availability=changed.getJSONObject("settings").getJSONArray("availability"),reversed=new JSONArray();for(int i=availability.length()-1;i>=0;i--)reversed.put(availability.get(i));changed.getJSONObject("settings").put("availability",reversed);
        check(revision.equals(DailyConsequences.revision(changed,120)),"Revision depends on collection order");
        check(!revision.equals(DailyConsequences.revision(changed,180)),"Warning preference did not invalidate scenarios");
        changed.getJSONArray("courses").getJSONObject(0).put("deadline",Planner.at(DAY.plusDays(3),0));check(!revision.equals(DailyConsequences.revision(changed,120)),"Deadline did not invalidate scenarios");
        check(!DailyConsequences.reality(snapshot,changed).has("outcome"),"Stale yesterday evidence produced an outcome");
    }
    static void dates()throws Exception{
        JSONObject state=fixture(),entry=entry(state);check(!DailyConsequences.reality(entry,state).getBoolean("isReviewed"),"Unreviewed day declared zero study");
        List<JSONObject> tasks=Planner.list(entry.getJSONArray("plannedToday"));for(int i=0;i<tasks.size();i++)Planner.confirm(state,tasks.get(i).getString("id"),i==0?30:0,Planner.at(DAY.plusDays(1),480),DAY);
        JSONObject reality=DailyConsequences.reality(entry,state);
        check(reality.getBoolean("isReviewed")&&reality.getInt("confirmedMinutes")==30&&reality.has("outcome"),"Next-day backfill was not reviewed correctly");
        check(DailyConsequences.confirmed(DAY.plusDays(1),state)==0,"Yesterday backfill became today's achievement");
        check(!DailyConsequences.valid(DailyConsequences.capture(fixture(),fixture(),Planner.at(DAY.plusDays(1),480),120),state),"Synthetic mismatched evidence was accepted");
        JSONObject legacy=CourseTools.copy(state);for(JSONObject record:Planner.list(legacy.getJSONArray("completions")))record.remove("studyDate");reality=DailyConsequences.reality(entry,legacy);
        check(reality.getInt("ambiguousRecords")==tasks.size()&&!reality.getBoolean("isReviewed"),"Ambiguous legacy backfill silently counted");
        JSONObject sameDay=fixture();Planner.confirm(sameDay,sameDay.getJSONArray("tasks").getJSONObject(0).getString("id"),30,NOW);JSONObject record=sameDay.getJSONArray("completions").getJSONObject(0);record.remove("studyDate");check(DailyConsequences.effectiveDay(record,sameDay).equals(DAY),"Unambiguous legacy same-day record lost");
        String before=state.toString();try{Planner.confirm(state,tasks.get(0).getString("id"),1,NOW,DAY.plusDays(1));throw new AssertionError("Future date accepted");}catch(IllegalArgumentException expected){check(before.equals(state.toString()),"Rejected future date mutated state");}
        JSONObject orphan=fixture(),captured=entry(orphan);orphan.getJSONArray("completions").put(new JSONObject().put("id",Planner.id()).put("courseID",orphan.getJSONArray("courses").getJSONObject(0).getString("id")).put("taskID",Planner.id()).put("minutes",120).put("recordedAt",Planner.at(DAY.plusDays(1),480)).put("studyDate",Planner.at(DAY,0)));
        check(DailyConsequences.reality(captured,orphan).getJSONObject("outcome").getString("kind").equals("scheduled"),"Dated orphan progress was ignored");
        JSONObject missed=Planner.task(Planner.id(),NOW,60).put("confirmedAt",NOW).put("status","missed"),partial=CourseTools.copy(missed).put("completedMinutes",30).put("status","partial"),completed=CourseTools.copy(missed).put("completedMinutes",60).put("status","completed");
        check(Planner.completionDescription(missed).contains("未完成")&&Planner.completionDescription(partial).contains("30")&&Planner.completionDescription(completed).contains("已完成"),"Search lost actual completion outcome");
        SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject synced=ledger.materialize();check(synced.getJSONArray("completions").getJSONObject(0).has("studyDate"),"Sync discarded study dates");
        Files.createDirectories(Paths.get("Android/build/tests"));Files.write(Paths.get("Android/build/tests/daily-consequence-parity.json"),synced.toString().getBytes(StandardCharsets.UTF_8));
    }
    static void refreshLifecycle()throws Exception{
        JSONObject state=fixture(),journal=DailyConsequenceRepository.empty();
        DailyConsequences.Update first=DailyConsequences.refresh(journal,state,NOW,120,null);
        int goal=first.entry.getInt("goalMinutes");String entryID=first.entry.getString("id");
        check(first.celebrations.isEmpty()&&goal==120,"First capture celebrated existing progress");
        JSONObject task=state.getJSONArray("tasks").getJSONObject(0);Planner.confirm(state,task.getString("id"),31,Planner.at(DAY,540));Planner.replan(state,Planner.at(DAY,540));
        DailyConsequences.Update update=DailyConsequences.refresh(journal,state,Planner.at(DAY,540),120,entryID);
        check(update.entry.getInt("goalMinutes")==goal&&update.celebrations.equals(new HashSet<>(Arrays.asList(0,250))),"Live progress lowered goal or missed celebrations");
        JSONObject restarted=new JSONObject(journal.toString());
        check(DailyConsequences.refresh(restarted,state,Planner.at(DAY,540),120,null).celebrations.isEmpty(),"Restart repeated celebration");
        update=DailyConsequences.refresh(journal,state,Planner.at(DAY,540),180,entryID);
        check(update.entry.getInt("goalMinutes")==goal&&update.celebrations.isEmpty()&&!update.entry.getString("id").equals(entryID),"Display threshold moved goal or replayed celebrations");
        entryID=update.entry.getString("id");Planner.undoConfirmation(state,task.getString("id"),Planner.at(DAY,550));Planner.replan(state,Planner.at(DAY,550));
        update=DailyConsequences.refresh(journal,state,Planner.at(DAY,550),180,entryID);
        check(update.entry.getInt("goalMinutes")==goal&&update.confirmed==0&&!DailyConsequences.achieved(update.entry,250,update.confirmed),"Undo retained achievement or moved goal");
        JSONObject next=PlannerTests.sortedTasks(state).get(0);for(JSONObject t:PlannerTests.sortedTasks(state))if(Planner.pending(t)){next=t;break;}
        Planner.confirm(state,next.getString("id"),Math.min(31,next.getInt("durationMinutes")),Planner.at(DAY,560));Planner.replan(state,Planner.at(DAY,560));
        update=DailyConsequences.refresh(journal,state,Planner.at(DAY,560),180,update.entry.getString("id"));check(update.celebrations.isEmpty(),"Undo and re-confirm replayed celebration");
        JSONObject raw=fixture();raw.getJSONArray("courses").getJSONObject(0).put("notes","private-source-note").put("netdisk",new JSONObject().put("sourceURL","private-source-reference"));
        check(!DailyConsequences.baseline(raw,NOW).toString().contains("private-source"),"Minimal simulation copied source metadata");
    }
    static void storage()throws Exception{
        Path folder=Files.createTempDirectory("study-consequence-tests");try{
            Path file=folder.resolve("journal.json");DailyConsequenceRepository repository=new DailyConsequenceRepository(file.toFile());JSONObject journal=repository.load();check(journal.getJSONArray("days").length()==0,"Fresh journal not empty");
            JSONObject entry=entry(fixture());entry.getJSONArray("celebrated").put(250);entry.getJSONArray("forecasts").put(DailyConsequences.forecast(entry,250,5));journal.getJSONArray("days").put(entry);repository.save(journal);
            JSONObject loaded=new DailyConsequenceRepository(file.toFile()).load();check(DailyConsequences.canonical(journal).equals(DailyConsequences.canonical(loaded)),"Restart lost forecasts or celebrations");
            String serialized=loaded.toString();check(!serialized.contains("webCourse")&&!serialized.contains("netdisk")&&!serialized.contains("secret"),"Journal copied source credentials");
            JSONArray days=new JSONArray();for(int i=0;i<18;i++)days.put(CourseTools.copy(entry).put("id",Planner.id()).put("date",Planner.at(DAY.plusDays(i),0)));journal.put("days",days);repository.save(journal);check(repository.load().getJSONArray("days").length()==14,"Journal retention unbounded");
            Files.write(file,"corrupt".getBytes(StandardCharsets.UTF_8));try{repository.load();throw new AssertionError("Corrupt history accepted");}catch(JSONException expected){}
            try{repository.save(journal);throw new AssertionError("Corrupt history overwritten");}catch(java.io.IOException expected){check(new String(Files.readAllBytes(file),StandardCharsets.UTF_8).equals("corrupt"),"Original corrupt history lost");}
        }finally{try(java.util.stream.Stream<Path> paths=Files.walk(folder)){paths.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.delete(p);}catch(Exception e){throw new RuntimeException(e);}});}}
    }
    public static void main(String[] args)throws Exception{health();forecasts();dates();refreshLifecycle();storage();System.out.println("PASS "+checks+" daily consequence, schedule health, backfill, sync and journal checks");}
}
