package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;

/** Symbolic integer boundaries shared by local journal validation, not journal wire format. */
public final class DailyJournalProgressTests {
    static final LocalDate DAY=LocalDate.of(2026,11,3);
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static int number(String value){
        switch(value){case "MAX":return Integer.MAX_VALUE;case "MAX_MINUS_ONE":return Integer.MAX_VALUE-1;case "MIN":return Integer.MIN_VALUE;default:return Integer.parseInt(value);}
    }
    static JSONObject scenario(String name,boolean accepted,String[] initials,String[]... records)throws Exception{
        JSONArray groups=new JSONArray();for(String[] values:records)groups.put(new JSONArray(values));
        return new JSONObject().put("name",name).put("accepted",accepted).put("initials",new JSONArray(initials)).put("records",groups);
    }
    static JSONObject merged(String name,boolean accepted,String initial,String association)throws Exception{
        return scenario(name,accepted,new String[]{"0"},new String[]{"1"}).put("merged",new JSONObject().put("initial",initial).put("association",association));
    }
    static JSONObject journal(JSONObject scenario)throws Exception{
        JSONObject empty=PlannerTests.empty();double now=Planner.at(DAY,480);
        JSONObject entry=DailyConsequences.capture(empty,empty,now,480),baseline=entry.getJSONObject("baseline");
        JSONArray initials=scenario.getJSONArray("initials"),groups=scenario.getJSONArray("records");
        JSONArray courses=baseline.getJSONArray("courses"),records=baseline.getJSONArray("completions");
        for(int i=0;i<initials.length();i++){
            JSONObject course=PlannerTests.course("Synthetic progress "+i,120,DAY,DAY,30).put("initialCompletedMinutes",number(initials.getString(i)));
            courses.put(course);JSONArray values=groups.getJSONArray(i);
            for(int j=0;j<values.length();j++)records.put(new JSONObject().put("id",Planner.id()).put("courseID",course.getString("id"))
                .put("taskID",Planner.id()).put("minutes",number(values.getString(j))).put("recordedAt",now).put("studyDate",Planner.at(DAY,0)));
        }
        if(scenario.has("merged")){
            JSONObject config=scenario.getJSONObject("merged"),root=courses.getJSONObject(0);
            JSONObject leaf=PlannerTests.course("Synthetic leaf",120,DAY,DAY,30).put("initialCompletedMinutes",number(config.getString("initial")));
            JSONObject branch=PlannerTests.course("Synthetic branch",120,DAY,DAY,30).put("type","不定时录播课程").put("mergedSources",new JSONArray().put(leaf));
            root.put("type","不定时录播课程").put("mergedSources",new JSONArray().put(branch));
            String association=config.getString("association");
            if(!association.equals("orphan")){
                JSONObject record=records.getJSONObject(0);
                String prefix=association.equals("matching")?branch.getString("id")+"/"+leaf.getString("id")+"/whole":"unrelated/whole";
                baseline.getJSONArray("tasks").put(Planner.task(root.getString("id"),now,1).put("id",record.getString("taskID")).put("lessonID",prefix));
            }
        }
        JSONObject journal=DailyConsequenceRepository.empty();journal.getJSONArray("days").put(entry);return journal;
    }
    static void verify(JSONObject scenario)throws Exception{
        JSONObject journal=journal(scenario);String original=DailyConsequences.canonical(journal),name=scenario.getString("name");boolean accepted=scenario.getBoolean("accepted");
        Path directory=Files.createTempDirectory("daily-journal-progress-");Path file=directory.resolve("journal.json");byte[] bytes=journal.toString().getBytes(StandardCharsets.UTF_8);
        try{
            Files.write(file,bytes);
            for(int attempt=0;attempt<2;attempt++){
                DailyConsequenceRepository repository=new DailyConsequenceRepository(file.toFile());
                try{JSONObject loaded=repository.load();check(accepted,name+" accepted invalid progress");check(original.equals(DailyConsequences.canonical(loaded)),name+" changed data");}
                catch(IllegalArgumentException expected){check(!accepted,name+" rejected representable progress");}
                if(!accepted){
                    check(repository.writeDisabled,name+" did not disable writes");
                    try{repository.save(DailyConsequenceRepository.empty());throw new AssertionError(name+" overwrote rejected progress");}catch(java.io.IOException expected){checks++;}
                }
                check(Arrays.equals(bytes,Files.readAllBytes(file)),name+" changed original bytes");
            }
            check(original.equals(DailyConsequences.canonical(journal)),name+" mutated source");
        }finally{Files.deleteIfExists(file);Files.deleteIfExists(directory);}
    }
    public static void main(String[] args)throws Exception{
        JSONArray cases=new JSONArray();
        cases.put(scenario("empty",true,new String[]{"0"},new String[]{}));
        cases.put(scenario("single-max",true,new String[]{"0"},new String[]{"MAX"}));
        cases.put(scenario("sum-at-max",true,new String[]{"0"},new String[]{"MAX_MINUS_ONE","1"}));
        cases.put(scenario("record-overflow",false,new String[]{"0"},new String[]{"MAX","1"}));
        cases.put(scenario("initial-at-max",true,new String[]{"MAX_MINUS_ONE"},new String[]{"1"}));
        cases.put(scenario("initial-overflow",false,new String[]{"MAX"},new String[]{"1"}));
        cases.put(scenario("negative-initial",true,new String[]{"MIN"},new String[]{"MAX"}));
        cases.put(scenario("separate-courses",true,new String[]{"0","0"},new String[]{"MAX"},new String[]{"MAX"}));
        cases.put(merged("merged-at-max",true,"MAX_MINUS_ONE","matching"));
        cases.put(merged("merged-overflow",false,"MAX","matching"));
        cases.put(merged("merged-unmatched",true,"MAX","unmatched"));
        cases.put(merged("merged-orphan",true,"MAX","orphan"));
        for(int i=0;i<cases.length();i++)verify(cases.getJSONObject(i));
        Path output=Paths.get("Android/build/tests/daily-journal-progress.json");Files.createDirectories(output.getParent());Files.writeString(output,new JSONObject().put("cases",cases).toString());
        System.out.println("PASS "+checks+" actual journal progress checks; symbolic boundary cases="+cases.length());
    }
}
