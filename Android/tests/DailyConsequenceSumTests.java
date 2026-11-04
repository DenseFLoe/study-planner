package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.time.*;
import java.util.*;

/** Synthetic accepted legacy progress; daily totals must fail before any journal mutation. */
public final class DailyConsequenceSumTests {
    static final LocalDate DAY=LocalDate.of(2026,11,3);
    static final double NOW=Planner.at(DAY,480);
    static int checks;
    interface Operation { void run() throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void overflow(Operation operation)throws Exception{
        try{operation.run();throw new AssertionError("Unrepresentable daily total was accepted");}
        catch(ArithmeticException expected){checks++;}
    }
    static JSONObject state(int... values)throws Exception{
        JSONObject state=PlannerTests.empty();
        for(int value:values){
            JSONObject course=PlannerTests.course("Synthetic course",120,DAY,DAY,60);
            state.getJSONArray("courses").put(course);
            state.getJSONArray("completions").put(new JSONObject().put("id",Planner.id()).put("courseID",course.getString("id"))
                .put("taskID",Planner.id()).put("minutes",value).put("recordedAt",NOW).put("studyDate",Planner.at(DAY,0)));
        }
        return state;
    }
    static JSONObject accepted(JSONObject state)throws Exception{
        SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize();
        java.io.ByteArrayOutputStream bytes=new java.io.ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
        JSONObject decoded=CloudSnapshot.read(new java.io.ByteArrayInputStream(bytes.toByteArray())).ledger.materialize();
        check(canonical(restored).equals(canonical(decoded)),"Sync archive changed materialized source");return decoded;
    }
    static JSONObject entry(JSONObject state)throws Exception{return DailyConsequences.capture(state,state,NOW,480);}
    static void sums()throws Exception{
        JSONObject state=accepted(state(Integer.MAX_VALUE,1));String source=DailyConsequences.canonical(state);
        overflow(()->DailyConsequences.confirmed(DAY,state));overflow(()->entry(state));
        check(source.equals(DailyConsequences.canonical(state)),"Rejected sum changed accepted progress");
        JSONObject exact=accepted(state(Integer.MAX_VALUE-1,1));
        check(DailyConsequences.confirmed(DAY,exact)==Integer.MAX_VALUE,"Exact maximum sum rejected");
        check(entry(exact).getInt("goalMinutes")==Integer.MAX_VALUE,"Exact maximum goal changed");
        for(JSONObject record:Planner.list(state.getJSONArray("completions")))if(record.getInt("minutes")==1)record.put("studyDate",Planner.at(DAY.plusDays(1),0));
        check(DailyConsequences.confirmed(DAY,state)==Integer.MAX_VALUE&&DailyConsequences.confirmed(DAY.plusDays(1),state)==1,"Separate days gained a global cap");
        check(entry(state).getInt("goalMinutes")==Integer.MAX_VALUE,"Separate-day capture failed");
        JSONObject dated=state(40,50,60);JSONArray records=dated.getJSONArray("completions");
        JSONObject legacy=records.getJSONObject(1);legacy.remove("studyDate");
        dated.getJSONArray("tasks").put(new JSONObject().put("id",legacy.getString("taskID")).put("courseID",legacy.getString("courseID"))
            .put("start",NOW).put("durationMinutes",60).put("status","completed").put("completedMinutes",50).put("confirmedAt",NOW+3600));
        records.getJSONObject(2).remove("studyDate");
        check(DailyConsequences.confirmed(DAY,dated)==90,"Dated orphan, matching legacy or ambiguous date semantics changed");
    }
    static void goalAndJournal()throws Exception{
        JSONObject state=accepted(state(Integer.MAX_VALUE));JSONObject planned=CourseTools.copy(state);
        JSONObject task=new JSONObject().put("id",Planner.id()).put("courseID",state.getJSONArray("courses").getJSONObject(0).getString("id"))
            .put("start",NOW).put("durationMinutes",1).put("status","planned");planned.getJSONArray("tasks").put(task);
        String before=DailyConsequences.canonical(planned);overflow(()->DailyConsequences.capture(state,planned,NOW,480));
        check(before.equals(DailyConsequences.canonical(planned)),"Failed credited plus planned total changed plan");
        JSONObject normal=state(30),journal=DailyConsequenceRepository.empty();JSONObject saved=entry(normal);journal.getJSONArray("days").put(saved);
        JSONObject bad=CourseTools.copy(normal);JSONObject other=state(Integer.MAX_VALUE);
        bad.getJSONArray("courses").put(other.getJSONArray("courses").getJSONObject(0));bad.getJSONArray("completions").put(other.getJSONArray("completions").getJSONObject(0));
        Path folder=Files.createTempDirectory("daily-sum-");Path file=folder.resolve("journal.json");
        try{
            DailyConsequenceRepository repository=new DailyConsequenceRepository(file.toFile());repository.save(journal);byte[] bytes=Files.readAllBytes(file);
            String original=DailyConsequences.canonical(journal),input=DailyConsequences.canonical(bad);
            overflow(()->DailyConsequences.refresh(journal,bad,NOW,480,saved.getString("id")));
            overflow(()->DailyConsequences.reality(saved,bad));
            check(original.equals(DailyConsequences.canonical(journal)),"Failure replaced, pruned, celebrated or reviewed the journal");
            check(input.equals(DailyConsequences.canonical(bad)),"Failure changed source records");
            check(Arrays.equals(bytes,Files.readAllBytes(file)),"Failure touched persisted bytes");
            check(original.equals(DailyConsequences.canonical(new DailyConsequenceRepository(file.toFile()).load())),"Reopen changed preserved journal");
            DailyConsequences.Update recovery=DailyConsequences.refresh(journal,normal,NOW,480,saved.getString("id"));
            check(recovery.confirmed==30&&recovery.entry.getString("id").equals(saved.getString("id")),"Valid recovery lost saved day");
            // Same revision, unchanged captured rows: the preexisting-entry fast path also must reject before mutation.
            JSONObject same=state(0,1);JSONObject existing=entry(same);JSONObject unchanged=DailyConsequenceRepository.empty();unchanged.getJSONArray("days").put(existing);
            JSONObject extra=new JSONObject().put("id",Planner.id()).put("taskID",Planner.id()).put("courseID",same.getJSONArray("courses").getJSONObject(0).getString("id"))
                .put("minutes",Integer.MAX_VALUE).put("recordedAt",NOW).put("studyDate",Planner.at(DAY,0));same.getJSONArray("completions").put(extra);
            check(DailyConsequences.revision(same,480).equals(existing.getString("revision"))&&DailyConsequences.valid(existing,same),"Fast-path fixture changed revision or evidence");
            String snapshot=DailyConsequences.canonical(unchanged);overflow(()->DailyConsequences.refresh(unchanged,same,NOW,480,existing.getString("id")));
            check(snapshot.equals(DailyConsequences.canonical(unchanged)),"Existing entry mutated before failure");
        }finally{Files.deleteIfExists(file);Files.deleteIfExists(folder);}
    }
    static void damagedProjectionBoundaries()throws Exception{
        JSONObject state=state(0),entry=entry(state);String owner=state.getJSONArray("courses").getJSONObject(0).getString("id");
        JSONObject invalid=CourseTools.copy(entry).put("goalMinutes",Integer.MAX_VALUE).put("confirmedAtCapture",Integer.MIN_VALUE);
        String before=canonical(invalid);overflow(()->DailyConsequences.forecast(invalid,1000,1));
        check(before.equals(canonical(invalid)),"Invalid requested difference changed journal input");
        JSONObject targets=CourseTools.copy(entry);JSONArray tasks=targets.getJSONArray("plannedToday");
        for(int value:new int[]{Integer.MAX_VALUE,1})tasks.put(new JSONObject().put("id",Planner.id()).put("courseID",owner).put("start",NOW).put("durationMinutes",value).put("status","planned"));
        String original=canonical(targets);overflow(()->DailyConsequences.reality(targets,state));
        check(original.equals(canonical(targets)),"Overflowing planned targets changed retained entry");
        JSONObject reviewed=CourseTools.copy(state);
        for(int value:new int[]{Integer.MAX_VALUE,1}){
            String id=Planner.id();reviewed.getJSONArray("tasks").put(new JSONObject().put("id",id).put("courseID",owner).put("start",NOW).put("durationMinutes",value).put("status","completed"));
            reviewed.getJSONArray("completions").put(new JSONObject().put("id",Planner.id()).put("taskID",id).put("courseID",owner).put("minutes",0).put("studyDate",Planner.at(DAY,0)).put("recordedAt",NOW));
        }
        String source=canonical(reviewed);overflow(()->DailyConsequences.reality(entry,reviewed));
        check(source.equals(canonical(reviewed)),"Overflowing reviewed durations changed source");
    }
    static void sharedBoundaries()throws Exception{
        Random random=new Random(202611032030L);JSONArray cases=new JSONArray();
        for(int index=0;index<256;index++){
            int count=1+random.nextInt(12);int[] values=new int[count];int[] days=new int[count];long[] sums={0,0};
            for(int i=0;i<count;i++){days[i]=random.nextInt(2);int remaining=(int)(Integer.MAX_VALUE-sums[days[i]]);values[i]=remaining==0?0:random.nextInt(remaining);sums[days[i]]+=values[i];}
            JSONObject state=state(values);for(int i=0;i<count;i++)state.getJSONArray("completions").getJSONObject(i).put("studyDate",Planner.at(DAY.plusDays(days[i]),0));
            String before=canonical(state);int first=DailyConsequences.confirmed(DAY,state),second=DailyConsequences.confirmed(DAY.plusDays(1),state);
            check(first==sums[0]&&second==sums[1],"Seeded date grouping differs from long oracle at "+index);
            check(before.equals(canonical(state)),"Seeded grouping changed source at "+index);
            cases.put(new JSONObject().put("values",new JSONArray(values)).put("days",new JSONArray(days)).put("day0",first).put("day1",second));
        }
        Path file=Paths.get("Android/build/tests/daily-consequence-sums.json");Files.createDirectories(file.getParent());
        Files.writeString(file,new JSONObject().put("seed",202611032030L).put("cases",cases).toString());
    }
    static String canonical(JSONObject value)throws Exception{return DailyConsequences.canonical(value);}
    public static void main(String[] args)throws Exception{sums();goalAndJournal();damagedProjectionBoundaries();sharedBoundaries();System.out.println("PASS "+checks+" daily sum, date, exact-limit, atomic journal and recovery checks");}
}
