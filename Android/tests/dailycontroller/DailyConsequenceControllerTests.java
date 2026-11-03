package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** Real controller + repository lifecycle against small UI doubles; no Android device required. */
public final class DailyConsequenceControllerTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void calculate(DailyConsequenceController controller,JSONObject state,double now){
        controller.app.state=state;int token=++controller.generation;
        controller.calculate(state,now,480,token,controller.today==null?null:controller.today.optString("id"));
    }
    static void cleanup(Path folder)throws Exception{try(java.util.stream.Stream<Path> paths=Files.walk(folder)){for(Path p:(Iterable<Path>)paths.sorted(Comparator.reverseOrder())::iterator)Files.delete(p);}}
    static void lifecycle()throws Exception{
        Path folder=Files.createTempDirectory("daily-controller-");MainActivity app=new MainActivity(folder.toFile());DailyConsequenceController controller=new DailyConsequenceController(app);
        try{
            JSONObject valid=DailyConsequenceSumTests.state(30);double now=DailyConsequenceSumTests.NOW;
            calculate(controller,valid,now);check(controller.today!=null&&controller.confirmed==30&&controller.todayError==null&&!controller.calculating,"Valid initial report unavailable");
            Path file=controller.repository.file.toPath();byte[] saved=Files.readAllBytes(file);String journal=DailyConsequences.canonical(controller.journal),state=DailyConsequences.canonical(valid);
            JSONObject overflow=DailyConsequenceSumTests.accepted(DailyConsequenceSumTests.state(Integer.MAX_VALUE,1));
            int toasts=android.widget.Toast.shown;calculate(controller,overflow,now);
            check(controller.today==null&&controller.todayError!=null&&controller.celebrations.isEmpty()&&!controller.calculating,"Overflow retained a stale success or spinner");
            check(controller.yesterdayError==null,"Today's overflow falsely reported a yesterday failure");
            check(Arrays.equals(saved,Files.readAllBytes(file))&&journal.equals(DailyConsequences.canonical(controller.journal)),"Overflow changed disk or in-memory journal");
            check(android.widget.Toast.shown==toasts,"Overflow celebrated progress");
            check(state.equals(DailyConsequences.canonical(valid)),"Lifecycle changed input state");
            calculate(controller,valid,now);check(controller.today!=null&&controller.confirmed==30&&controller.todayError==null,"Valid recovery kept unavailable state");
            DailyConsequenceRepository reopened=new DailyConsequenceRepository(file.toFile());check(reopened.load().getJSONArray("days").length()==1,"Recovery lost persisted day");
            // Credited total fits, but freshly planned work makes the daily goal unrepresentable.
            JSONObject overGoal=DailyConsequenceSumTests.state(Integer.MAX_VALUE);
            LocalDate date=DailyConsequenceSumTests.DAY;
            overGoal.getJSONArray("courses").put(PlannerTests.course("Pending",60,date,date,60));
            overGoal.getJSONObject("settings").getJSONArray("availability").put(PlannerTests.window(Planner.weekday(date),480,540));
            byte[] beforeGoal=Files.readAllBytes(file);String journalBeforeGoal=DailyConsequences.canonical(controller.journal);
            calculate(controller,overGoal,now);
            check(controller.today==null&&controller.todayError!=null,"Overflowing credited plus planned goal was published");
            check(Arrays.equals(beforeGoal,Files.readAllBytes(file))&&journalBeforeGoal.equals(DailyConsequences.canonical(controller.journal)),"Failed goal calculation replaced journal");
            calculate(controller,valid,now);
            // Old UI callbacks must not overwrite a newer failure or recovery.
            app.queueCallbacks=true;calculate(controller,valid,now);int oldGeneration=controller.generation;
            calculate(controller,overflow,now);check(controller.generation>oldGeneration,"Missing lifecycle generation");app.drain();
            check(controller.today==null&&controller.todayError!=null,"Old successful callback overwrote failure");
            calculate(controller,overflow,now);calculate(controller,valid,now);app.drain();
            check(controller.today!=null&&controller.todayError==null&&controller.confirmed==30,"Old error callback overwrote recovery");
            app.queueCallbacks=false;
        }finally{controller.close();cleanup(folder);}
    }
    static void yesterdayAndReview()throws Exception{
        Path folder=Files.createTempDirectory("daily-controller-yesterday-");MainActivity app=new MainActivity(folder.toFile());DailyConsequenceController controller=new DailyConsequenceController(app);
        try{
            // The review action uses the production clock, so fixtures follow its local calendar day.
            LocalDate today=Planner.day(Planner.now()),yesterday=today.minusDays(1);double now=Planner.at(today,480),oldNow=Planner.at(yesterday,480);
            JSONObject state=DailyConsequenceSumTests.state(30);
            state.getJSONArray("completions").getJSONObject(0).put("recordedAt",oldNow).put("studyDate",Planner.at(yesterday,0));
            JSONObject entry=DailyConsequences.capture(state,state,oldNow,480);JSONObject journal=DailyConsequenceRepository.empty();journal.getJSONArray("days").put(entry);controller.repository.save(journal);
            calculate(controller,state,now);check(controller.today!=null&&controller.yesterday!=null&&controller.yesterdayError==null,"Normal yesterday not reported");
            JSONObject bad=DailyConsequenceSumTests.state(Integer.MAX_VALUE,1);for(JSONObject r:Planner.list(bad.getJSONArray("completions")))r.put("studyDate",Planner.at(yesterday,0)).put("recordedAt",oldNow);
            String input=DailyConsequences.canonical(bad);calculate(controller,bad,now);
            check(controller.today!=null&&controller.todayError==null&&controller.confirmed==0,"Yesterday overflow hid valid today");
            check(controller.yesterday==null&&controller.yesterdayError!=null&&!controller.calculating,"Yesterday overflow retained stale successful review");
            String preserved=DailyConsequences.canonical(controller.find(yesterday));byte[] bytes=Files.readAllBytes(controller.repository.file.toPath());
            controller.calculating=true;controller.markYesterdayReviewed();controller.task.get(10,TimeUnit.SECONDS);
            check(!controller.calculating,"Rejected review left a cancelled forecast spinner");
            check(preserved.equals(DailyConsequences.canonical(controller.find(yesterday)))&&!controller.find(yesterday).has("reviewedAt"),"Failed review changed retained entry");
            check(Arrays.equals(bytes,Files.readAllBytes(controller.repository.file.toPath())),"Failed review wrote journal");
            check(input.equals(DailyConsequences.canonical(bad)),"Failed review changed shared progress");
            calculate(controller,state,now);check(controller.yesterday!=null&&controller.yesterdayError==null,"Yesterday did not recover");
            // Today's failure must not prevent an independent valid yesterday result.
            JSONObject todayBad=CourseTools.copy(state),extra=DailyConsequenceSumTests.state(Integer.MAX_VALUE,1);
            for(JSONObject c:Planner.list(extra.getJSONArray("courses")))todayBad.getJSONArray("courses").put(c);
            for(JSONObject r:Planner.list(extra.getJSONArray("completions")))todayBad.getJSONArray("completions").put(r.put("studyDate",Planner.at(today,0)));
            calculate(controller,todayBad,now);check(controller.today==null&&controller.todayError!=null&&controller.yesterday!=null&&controller.yesterdayError==null,"Today failure suppressed valid yesterday");
        }finally{controller.close();cleanup(folder);}
    }
    static void workerRefreshRecovery()throws Exception{
        Path folder=Files.createTempDirectory("daily-controller-worker-");MainActivity app=new MainActivity(folder.toFile());DailyConsequenceController controller=new DailyConsequenceController(app);
        try{
            LocalDate day=Planner.day(Planner.now());JSONObject valid=DailyConsequenceSumTests.state(30),bad=DailyConsequenceSumTests.state(Integer.MAX_VALUE,1);
            for(JSONObject input:Arrays.asList(valid,bad))for(JSONObject record:Planner.list(input.getJSONArray("completions")))record.put("studyDate",Planner.at(day,0));
            app.state=valid;controller.refresh(valid);controller.task.get(10,TimeUnit.SECONDS);
            check(controller.today!=null&&controller.confirmed==30,"Worker refresh initial success missing");
            byte[] bytes=Files.readAllBytes(controller.repository.file.toPath());
            app.state=bad;controller.refresh(bad);controller.task.get(10,TimeUnit.SECONDS);
            check(controller.today==null&&controller.todayError!=null&&!controller.calculating,"Worker refresh retained stale success");
            check(Arrays.equals(bytes,Files.readAllBytes(controller.repository.file.toPath())),"Worker failure changed persisted history");
            app.state=valid;controller.refresh(valid);controller.task.get(10,TimeUnit.SECONDS);
            check(controller.today!=null&&controller.confirmed==30&&controller.todayError==null,"Worker recovery blocked by refresh cache");
        }finally{controller.close();cleanup(folder);}
    }
    public static void main(String[] args)throws Exception{lifecycle();yesterdayAndReview();workerRefreshRecovery();System.out.println("PASS "+checks+" real-controller lifecycle, independent-day, stale-callback and unchanged-disk checks (UI doubles)");}
}
