package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;

/** Local journal identity controls shared by topology, not by a cross-platform journal wire format. */
public final class DailyJournalIdentityTests {
    static final LocalDate DAY=LocalDate.of(2026,11,3);
    static final String A="00000000-0000-0000-0000-000000000001",B="00000000-0000-0000-0000-000000000002";
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject scenario(String name,boolean accepted,String[]... days)throws Exception {
        JSONArray rows=new JSONArray();for(String[] ids:days)rows.put(new JSONArray(ids));
        return new JSONObject().put("name",name).put("accepted",accepted).put("days",rows).put("goal",60);
    }
    static JSONObject journal(JSONObject scenario)throws Exception {
        JSONObject journal=DailyConsequenceRepository.empty();JSONArray days=scenario.getJSONArray("days");
        for(int i=0;i<days.length();i++){
            LocalDate date=DAY.plusDays(i);JSONObject empty=PlannerTests.empty();
            JSONObject entry=DailyConsequences.capture(empty,empty,Planner.at(date,480),480);JSONArray courses=entry.getJSONObject("baseline").getJSONArray("courses"),ids=days.getJSONArray(i);
            for(int j=0;j<ids.length();j++)courses.put(PlannerTests.course("Synthetic local course",60,date,date,30).put("id",ids.getString(j)).put("type","录播课程"));
            entry.put("goalMinutes",scenario.getInt("goal"));journal.getJSONArray("days").put(entry);
        }
        return journal;
    }
    static void verify(JSONObject scenario)throws Exception {
        JSONObject journal=journal(scenario);String before=DailyConsequences.canonical(journal);boolean accepted=scenario.getBoolean("accepted");String name=scenario.getString("name");
        Path directory=Files.createTempDirectory("daily-journal-identities-");Path file=directory.resolve("journal.json");byte[] bytes=journal.toString().getBytes(StandardCharsets.UTF_8);
        try{
            Files.write(file,bytes);DailyConsequenceRepository repository=new DailyConsequenceRepository(file.toFile());
            try{
                JSONObject loaded=repository.load();check(accepted,name+" unexpectedly loaded");
                check(before.equals(DailyConsequences.canonical(loaded)),name+" changed loaded data");
            }catch(IllegalArgumentException expected){check(!accepted,name+" unexpectedly rejected");}
            check(Arrays.equals(bytes,Files.readAllBytes(file)),name+" changed bytes during load");
            if(!accepted){
                check(repository.writeDisabled,name+" did not disable writes");
                try{repository.save(DailyConsequenceRepository.empty());throw new AssertionError(name+" overwrote the rejected file");}catch(java.io.IOException expected){checks++;}
                check(Arrays.equals(bytes,Files.readAllBytes(file)),name+" changed rejected file bytes");
                DailyConsequenceRepository reopened=new DailyConsequenceRepository(file.toFile());
                try{reopened.load();throw new AssertionError(name+" lost rejection after restart");}catch(IllegalArgumentException expected){checks++;}
            }
            check(before.equals(DailyConsequences.canonical(journal)),name+" changed original fixture");
        }finally{Files.deleteIfExists(file);Files.deleteIfExists(directory);}
    }
    public static void main(String[] args)throws Exception {
        JSONArray cases=new JSONArray();
        cases.put(scenario("ordinary",true,new String[]{A}));
        cases.put(scenario("distinct-roots",true,new String[]{A,B}));
        cases.put(scenario("duplicate-roots",false,new String[]{A,A}));
        cases.put(scenario("nonadjacent-duplicate",false,new String[]{A,B,A}));
        cases.put(scenario("same-course-across-days",true,new String[]{A},new String[]{A}));
        cases.put(scenario("duplicate-in-later-day",false,new String[]{A},new String[]{A,A}));
        cases.put(scenario("empty-baseline",true,new String[]{}));
        cases.put(scenario("large-goal",true,new String[]{A}).put("goal",Integer.MAX_VALUE));
        String[][] repeated=new String[31][];for(int i=0;i<31;i++)repeated[i]=new String[]{A};
        cases.put(scenario("same-course-through-load-limit",true,repeated));
        for(int i=0;i<cases.length();i++)verify(cases.getJSONObject(i));
        Path output=Paths.get("Android/build/tests/daily-journal-identities.json");Files.createDirectories(output.getParent());Files.writeString(output,new JSONObject().put("cases",cases).toString());
        System.out.println("PASS "+checks+" local journal identity/read-only failure controls; shared topology cases="+cases.length());
    }
}
