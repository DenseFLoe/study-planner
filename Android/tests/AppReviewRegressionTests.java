package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.time.*;
import java.util.*;

public final class AppReviewRegressionTests {
    static int checks;
    static final LocalDate TODAY=LocalDate.of(2026,10,3);
    static void check(boolean condition,String message){checks++;if(!condition)throw new AssertionError(message);}
    static JSONObject state()throws Exception{return PlannerTests.empty();}
    static JSONObject course(String name,int minutes)throws Exception{return PlannerTests.course(name,minutes,TODAY,TODAY.plusDays(1),60);}
    static JSONObject lesson(String id,String name,int minutes)throws Exception{return new JSONObject().put("id",id).put("name",name).put("durationMinutes",minutes);}

    static void orderedLessons()throws Exception {
        for(int end:new int[]{720,735}){
            JSONObject state=state(),course=course("两节课",120).put("deadline",Planner.at(TODAY,0));
            course.put("type","不定时录播课程").put("manualLessons",new JSONArray().put(lesson("first","第一节",90)).put(lesson("second","第二节",30)));
            state.getJSONArray("courses").put(course);
            for(int[] window:new int[][]{{480,540},{600,end}})state.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",7).put("startMinute",window[0]).put("endMinute",window[1]));
            List<String> warnings=Planner.replan(state,Planner.at(TODAY,420));
            JSONArray tasks=state.getJSONArray("tasks");check(tasks.getJSONObject(0).getString("lessonID").equals("first"),"Short lesson filled a gap before its predecessor");
            check(tasks.length()==(end==735?2:1),"Lesson capacity should include the intervening break");
            if(end==735)check(tasks.getJSONObject(1).getDouble("start")==Planner.at(TODAY,705),"Second lesson must start after the first and a break");
            else check(!warnings.isEmpty(),"A lesson that cannot follow its predecessor must report missing work");
        }
    }

    static void manualIdentity()throws Exception {
        JSONObject course=course("手动课程",120).put("type","不定时录播课程");
        course.put("manualLessons",new JSONArray().put(lesson("A","第一节",60)).put(lesson("B","第二节",60)));
        JSONArray inserted=Planner.parseManualLessons("新课:60\n第一节:60\n第二节:60",course);
        check(!inserted.getJSONObject(0).getString("id").equals("A"),"Inserted lesson reused confirmed identity");
        check(inserted.getJSONObject(1).getString("id").equals("A"),"Original lesson identity changed on insert");
        JSONArray reordered=Planner.parseManualLessons("第二节:60\n第一节:60",course);
        check(reordered.getJSONObject(0).getString("id").equals("B"),"Reordering reassigned identities");
        JSONArray deleted=Planner.parseManualLessons("第二节:60",course);
        check(deleted.getJSONObject(0).getString("id").equals("B"),"Deleting a preceding row reassigned identity");
        JSONArray renamed=Planner.parseManualLessons("新名称:60\n第二节:60",course);
        check(renamed.getJSONObject(0).getString("id").equals("A"),"Single rename must preserve progress identity");
        JSONArray duration=Planner.parseManualLessons("第一节:75\n第二节:60",course);
        check(duration.getJSONObject(0).getString("id").equals("A"),"Duration edit changed identity");
        boolean refused=false;try{Planner.parseManualLessons("甲:60\n乙:60",course);}catch(IllegalArgumentException expected){refused=true;}
        check(refused,"Ambiguous simultaneous renames must not silently move progress");
        JSONObject state=state();state.getJSONArray("courses").put(course);
        JSONObject task=Planner.task(course.getString("id"),Planner.at(TODAY,480),60).put("lessonID","A");state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),60,Planner.at(TODAY,540));
        Planner.updateManualLessons(course,inserted);
        Map<String,Integer> remaining=new HashMap<>();for(Planner.Work work:Planner.lessonWork(state,course))remaining.put(work.lessonName,work.minutes);
        check(remaining.get("新课")==60&&!remaining.containsKey("第一节"),"Completion moved to the inserted lesson");
        JSONObject baseline=course("基础进度",120).put("type","不定时录播课程").put("initialCompletedMinutes",60)
            .put("manualLessons",new JSONArray().put(lesson("A","第一节",60)).put(lesson("B","第二节",60))).put("lessonOrder",new JSONArray().put("B").put("A"));
        Planner.updateManualLessons(baseline,Planner.parseManualLessons("更名第一节:60\n第二节:60",baseline));
        check(baseline.getJSONArray("lessonOrder").getString(0).equals("B"),"Editing metadata reset custom lesson order");
        JSONObject baselineState=state();baselineState.getJSONArray("courses").put(baseline);
        check(Planner.lessonWork(baselineState,baseline).get(0).lessonID.equals("B"),"Editing moved baseline progress onto a different lesson");
        Planner.updateManualLessons(baseline,Planner.parseManualLessons("第二节:60\n更名第一节:60",baseline));
        check(baseline.getJSONArray("manualLessons").getJSONObject(0).getString("id").equals("A"),"Text reordering moved baseline source identity");
    }

    static void mergedEditorAndValidation()throws Exception {
        JSONObject merged=course("合并课程",120).put("type","不定时录播课程").put("mergedSources",new JSONArray().put(course("A",60)).put(course("B",60)));
        check(!Planner.isManualLessonCourse(merged,merged.getString("type")),"Merged course must not require manual lesson input");
        JSONObject state=state();state.getJSONArray("courses").put(merged);merged.put("name","新名称").put("deadline",Planner.at(TODAY.plusDays(2),0));Planner.validateCourseEdit(state,merged,Planner.at(TODAY,420));
        check(merged.getInt("totalMinutes")==120&&merged.getJSONArray("mergedSources").length()==2,"Metadata edits damaged merge sources");
        boolean refused=false;try{Planner.validateCourseEdit(state,new JSONObject(merged.toString()).put("deadline",Planner.at(TODAY.plusYears(11),0)),Planner.at(TODAY,420));}catch(IllegalArgumentException expected){refused=true;}
        check(refused,"Android accepted a deadline beyond the Mac supported horizon");
        refused=false;try{Planner.validateCourseEdit(state,new JSONObject(merged.toString()).put("totalMinutes",600001),Planner.at(TODAY,420));}catch(IllegalArgumentException expected){refused=true;}
        check(refused,"Android accepted unsupported total learning minutes");
    }

    static void websiteProgress()throws Exception {
        JSONObject state=state(),course=course("网站与本地进度",120).put("type","不定时录播课程").put("initialCompletedMinutes",30);
        double fetched=Planner.at(TODAY,540);
        JSONArray lessons=new JSONArray();
        for(String id:new String[]{"first","second"})lessons.put(new JSONObject().put("id",id).put("name",id)
            .put("published",true).put("requiresDuration",true).put("durationSeconds",3600).put("watchedPercent",id.equals("first")?50:0));
        course.put("webCourse",new JSONObject().put("fetchedAt",fetched).put("lessons",lessons));
        state.getJSONArray("courses").put(course);
        JSONObject task=Planner.task(course.getString("id"),Planner.at(TODAY,480),60).put("lessonID","second");
        state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),60,fetched-1);
        SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize();
        JSONObject saved=restored.getJSONArray("courses").getJSONObject(0);
        List<Planner.Work> work=Planner.lessonWork(restored,saved);
        check(Planner.completed(restored,saved)==90,"Sync lost independent website and local progress");
        check(work.size()==1&&work.get(0).lessonID.equals("first")&&work.get(0).minutes==30,"Android scheduled a locally completed lesson again");
        state=state();course=course("已有基础进度",120).put("type","不定时录播课程").put("initialCompletedMinutes",30)
            .put("webCompletionOverlaps",new JSONObject().put("second",0));
        lessons.getJSONObject(0).put("watchedPercent",0);lessons.getJSONObject(1).put("watchedPercent",50);
        course.put("webCourse",new JSONObject().put("fetchedAt",fetched).put("lessons",lessons));state.getJSONArray("courses").put(course);
        task=Planner.task(course.getString("id"),Planner.at(TODAY,480),30).put("lessonID","second");state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),30,fetched-1);
        ledger=new SyncLedger();ledger.capture(state);restored=ledger.materialize();saved=restored.getJSONArray("courses").getJSONObject(0);
        work=Planner.lessonWork(restored,saved);
        check(work.size()==1&&work.get(0).lessonID.equals("first")&&work.get(0).minutes==60,"Local progress beyond the website baseline moved onto another lesson");
        Planner.undoConfirmation(restored,task.getString("id"),fetched+1);
        check(Planner.completed(restored,saved)==30,"Undo erased verified website progress");
        saved.put("initialCompletedMinutes",0).put("webCompletionOverlaps",new JSONObject().put("second",30));
        Planner.confirm(restored,task.getString("id"),30,fetched-1);
        Planner.undoConfirmation(restored,task.getString("id"),fetched+1);
        check(Planner.completed(restored,saved)==30,"Undo failed to restore the website baseline after removing overlapping local credit");
    }

    static void coldStart()throws Exception {
        JSONObject state=state(),course=PlannerTests.course("隔夜任务",120,TODAY.minusDays(1),TODAY.plusDays(1),60);state.getJSONArray("courses").put(course);
        for(LocalDate day:new LocalDate[]{TODAY.minusDays(1),TODAY})state.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",Planner.weekday(day)).put("startMinute",480).put("endMinute",720));
        JSONObject completed=Planner.task(course.getString("id"),Planner.at(TODAY.minusDays(1),480),60);
        state.getJSONArray("tasks").put(completed).put(Planner.task(course.getString("id"),Planner.at(TODAY.minusDays(1),575),60));
        Planner.confirm(state,completed.getString("id"),60,Planner.at(TODAY.minusDays(1),540));String snapshot=completed.toString();
        Planner.prepareForOpen(state,Planner.at(TODAY,420));
        check(Planner.completed(state,course)==60,"Startup changed confirmed progress");
        check(Planner.list(state.getJSONArray("tasks")).stream().anyMatch(t->t.optString("id").equals(completed.optString("id"))&&t.toString().equals(snapshot)),"Startup changed confirmed history");
        check(Planner.list(state.getJSONArray("tasks")).stream().anyMatch(t->Planner.pending(t)&&Planner.day(t.optDouble("start")).equals(TODAY)),"Cold start did not redistribute unfinished work into today");
    }

    static void mergeSync()throws Exception {
        for(boolean macWins:new boolean[]{false,true})for(boolean deleteDraft:new boolean[]{false,true}){
            JSONObject base=state(),a=course("A",60),b=course("B",60);base.getJSONArray("courses").put(a).put(b);
            JSONObject task=Planner.task(a.getString("id"),Planner.at(TODAY,480),60);base.getJSONArray("tasks").put(task);
            SyncLedger mac=new SyncLedger(),phone=new SyncLedger();mac.value.put("device",macWins?"Z-MAC":"A-MAC");phone.value.put("device",macWins?"A-ANDROID":"Z-ANDROID");mac.capture(base);phone.merge(mac.changes(0));
            JSONObject mergedState=new JSONObject(base.toString()),merged=course("合并",120).put("type","不定时录播课程").put("mergedSources",new JSONArray().put(a).put(b));
            mergedState.put("courses",new JSONArray().put(merged));JSONObject moved=mergedState.getJSONArray("tasks").getJSONObject(0);moved.put("courseID",merged.getString("id")).put("lessonID",a.getString("id")+"/whole");
            if(deleteDraft)Planner.replan(mergedState,Planner.at(TODAY,420));mac.capture(mergedState);
            JSONObject confirmed=phone.materialize();Planner.confirm(confirmed,task.getString("id"),60,Planner.at(TODAY,540));phone.capture(confirmed);
            JSONArray m=mac.changes(0),p=phone.changes(0);mac.merge(p);phone.merge(m);
            JSONObject result=mac.materialize();check(SyncLedger.canonical(result).equals(SyncLedger.canonical(phone.materialize())),"Merge/confirmation failed to converge");
            check(Planner.completed(result,merged)==60,"Merge erased offline progress");
            check(Planner.list(result.getJSONArray("tasks")).stream().anyMatch(t->t.optString("id").equals(task.optString("id"))&&t.has("confirmedAt")&&t.optInt("completedMinutes")==60),"Merge did not recover confirmed task history");
            mac.capture(result);long sequence=mac.sequence();mac.capture(mac.materialize());check(sequence==mac.sequence(),"Repeated merge capture changed progress");
        }
        if(Files.exists(Paths.get("/tmp/study-merge-regression-swift.json"))){
            SyncLedger swift=new SyncLedger(new JSONObject(new String(Files.readAllBytes(Paths.get("/tmp/study-merge-regression-swift.json")),"UTF-8")));
            JSONObject state=swift.materialize(),merged=state.getJSONArray("courses").getJSONObject(0);
            check(Planner.completed(state,merged)==60,"Java could not preserve the Swift merged confirmation");
            swift.capture(state);Files.write(Paths.get("/tmp/study-merge-regression-java.json"),swift.value.toString().getBytes("UTF-8"));
        }
    }

    public static void main(String[] args)throws Exception {
        orderedLessons();manualIdentity();mergedEditorAndValidation();websiteProgress();coldStart();mergeSync();
        System.out.println("PASS "+checks+" app review regression checks");
    }
}
