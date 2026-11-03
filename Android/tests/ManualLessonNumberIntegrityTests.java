package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class ManualLessonNumberIntegrityTests {
    static int checks;
    static final double NOW=800_000_000;
    static final Object MISSING=new Object();
    static final String[] MODES={"active","recorded","web","mergedParent","nested"};
    interface Action { void run()throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{
        boolean rejected=false;try{action.run();}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,message);
    }
    static final class Fixture {
        final JSONObject state,root,target;
        Fixture(JSONObject state,JSONObject root,JSONObject target){this.state=state;this.root=root;this.target=target;}
    }
    static JSONObject manualCourse()throws Exception{
        JSONObject course=SyncExchangeTests.fixture(NOW).getJSONArray("courses").getJSONObject(0);
        JSONArray lessons=new JSONArray();for(int i=0;i<2;i++)lessons.put(new JSONObject().put("id","manual-"+i).put("name","Lesson "+i).put("durationMinutes",60));
        return course.put("type","不定时录播课程").put("manualLessons",lessons);
    }
    static JSONObject website()throws Exception{
        JSONArray lessons=new JSONArray();for(int i=0;i<2;i++)lessons.put(new JSONObject().put("id","web-"+i).put("name","Web "+i)
            .put("subject","").put("stage","").put("chapter","").put("kind","video").put("published",true)
            .put("durationSeconds",3600).put("watchedPercent",0).put("markedFinished",false).put("requiresDuration",true));
        return new JSONObject().put("packageID","synthetic").put("name","Web lessons").put("sourceURL","https://example.com/course")
            .put("fetchedAt",NOW).put("expectedOutlines",1).put("fetchedOutlines",1).put("issues",new JSONArray()).put("lessons",lessons);
    }
    static Fixture fixture(String mode)throws Exception{
        JSONObject root=manualCourse(),target=root;
        if(mode.equals("recorded"))root.put("type","录播课程");
        if(mode.equals("web"))root.put("webCourse",website());
        if(mode.equals("mergedParent"))root.put("mergedSources",new JSONArray().put(manualCourse()));
        if(mode.equals("nested")){
            JSONObject branch=manualCourse();target=manualCourse();
            branch.put("mergedSources",new JSONArray().put(target));root.put("mergedSources",new JSONArray().put(branch));
        }
        return new Fixture(SyncExchangeTests.initial().put("courses",new JSONArray().put(root)),root,target);
    }
    static JSONObject target(JSONObject state,String mode)throws Exception{
        JSONObject root=state.getJSONArray("courses").getJSONObject(0);
        return mode.equals("nested")?root.getJSONArray("mergedSources").getJSONObject(0).getJSONArray("mergedSources").getJSONObject(0):root;
    }
    static void number(Fixture fixture,Object value)throws Exception{
        JSONObject lesson=fixture.target.getJSONArray("manualLessons").getJSONObject(0);
        if(value==MISSING)lesson.remove("durationMinutes");else lesson.put("durationMinutes",value);
    }
    static void payload(JSONObject row,String json)throws Exception{row.put("payload",Base64.getEncoder().encodeToString(json.getBytes(StandardCharsets.UTF_8)));}
    static SyncLedger wire(JSONObject state)throws Exception{
        SyncLedger ledger=new SyncLedger();ledger.capture(SyncExchangeTests.initial());
        for(JSONObject course:Planner.list(state.getJSONArray("courses"))){
            JSONObject row=new JSONObject().put("kind","courses").put("id",course.getString("id")).put("deleted",false)
                .put("version",1).put("sequence",1).put("device","manual-number-fixture");
            payload(row,course.toString());ledger.records().put(SyncLedger.key(row),row);
        }
        return ledger;
    }
    static void archive(SyncLedger ledger)throws Exception{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
        CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
    }
    static void rejectedAtBoundaries(Fixture fixture,String label)throws Exception{
        SyncLedger ledger=new SyncLedger();ledger.capture(fixture("active").state);
        String before=ledger.value.toString(),input=fixture.state.toString();
        rejects(()->ledger.capture(fixture.state),"capture accepted "+label);
        check(before.equals(ledger.value.toString()),"rejected capture changed ledger: "+label);
        rejects(()->Planner.validate(fixture.state),"backup accepted "+label);
        rejects(()->Planner.validateCourseEdit(fixture.state,fixture.root,NOW),"editor accepted "+label);
        SyncLedger imported=wire(fixture.state);String wireBefore=imported.value.toString();
        rejects(()->imported.materialize(),"materialize accepted "+label);
        rejects(()->archive(imported),"archive accepted "+label);
        check(wireBefore.equals(imported.value.toString()),"rejected read changed ledger: "+label);
        check(input.equals(fixture.state.toString()),"validation changed input: "+label);
    }
    static void invalidNumbers()throws Exception{
        for(String mode:MODES)for(Object value:new Object[]{4294967356L,2147483648L,60.5,"60",true,JSONObject.NULL,MISSING}){
            Fixture fixture=fixture(mode);number(fixture,value);rejectedAtBoundaries(fixture,"manual duration in "+mode);
        }
    }
    static void invalidShapes()throws Exception{
        for(String mode:MODES)for(Object value:new Object[]{new JSONObject(),"[]",true,60,
                new JSONArray().put(JSONObject.NULL),new JSONArray().put(60),new JSONArray().put("lesson"),new JSONArray().put(new JSONArray())}){
            Fixture fixture=fixture(mode);fixture.target.put("manualLessons",value);rejectedAtBoundaries(fixture,"manual container/element in "+mode);
        }
    }
    static void validNumbersAndExistingRanges()throws Exception{
        for(String mode:MODES)for(Object value:new Object[]{0,-1,Integer.MIN_VALUE,Integer.MAX_VALUE,1441,600001,60L,60.0,new BigDecimal("6e1")}){
            Fixture fixture=fixture(mode);number(fixture,value);String input=fixture.state.toString();
            Planner.validate(fixture.state);Planner.validateCourseEdit(fixture.state,fixture.root,NOW);
            SyncLedger ledger=new SyncLedger();ledger.capture(fixture.state);String before=ledger.value.toString();JSONObject restored=ledger.materialize();
            int expected=new BigDecimal(value.toString()).intValueExact();
            check(target(restored,mode).getJSONArray("manualLessons").getJSONObject(0).getInt("durationMinutes")==expected,"exact manual duration changed: "+mode);
            archive(ledger);check(before.equals(ledger.value.toString()),"valid read changed ledger");check(input.equals(fixture.state.toString()),"valid numeric checks changed input");
        }
        for(int total:new int[]{600000,600001}){
            Fixture fixture=fixture("active");fixture.root.put("totalMinutes",total);
            boolean accepted=true;try{Planner.validateCourseEdit(fixture.state,fixture.root,NOW);}catch(IllegalArgumentException expected){accepted=false;}
            check(accepted==(total==600000),"manual numeric validation changed editor course-total limit");
        }
    }
    static void wireIntegerTokens()throws Exception{
        for(String mode:new String[]{"active","nested"})for(String token:new String[]{"60.0","6e1","2147483647.0","0.0","-1e0","-2147483648.0"}){
            Fixture fixture=fixture(mode);number(fixture,61);SyncLedger ledger=wire(fixture.state);
            String original=fixture.root.toString(),json=original.replace("\"durationMinutes\":61","\"durationMinutes\":"+token);
            check(!original.equals(json),"numeric wire fixture was not replaced");
            payload(ledger.records().getJSONObject("courses/"+fixture.root.getString("id")),json);
            JSONObject restored=ledger.materialize();check(target(restored,mode).getJSONArray("manualLessons").getJSONObject(0).getInt("durationMinutes")==new BigDecimal(token).intValueExact(),"integer-valued manual token rejected");archive(ledger);
        }
    }
    static void optionalManualTables()throws Exception{
        for(String mode:MODES)for(Object value:new Object[]{MISSING,JSONObject.NULL,new JSONArray()}){
            Fixture fixture=fixture(mode);if(value==MISSING)fixture.target.remove("manualLessons");else fixture.target.put("manualLessons",value);
            String input=fixture.state.toString();Planner.validate(fixture.state);Planner.validateCourseEdit(fixture.state,fixture.root,NOW);
            SyncLedger ledger=new SyncLedger();ledger.capture(fixture.state);JSONObject restored=target(ledger.materialize(),mode);
            if(value==MISSING)check(!restored.has("manualLessons"),"missing optional manual table changed");
            else if(value==JSONObject.NULL)check(restored.has("manualLessons")&&restored.isNull("manualLessons"),"null optional manual table changed");
            else check(restored.getJSONArray("manualLessons").length()==0,"empty optional manual table changed");
            archive(ledger);check(input.equals(fixture.state.toString()),"optional manual validation changed input");
        }
    }
    static void archivedRootsAndDeletedHistory()throws Exception{
        Fixture archived=fixture("active");number(archived,"60");archived.root.put("isArchived",true);
        String input=archived.state.toString();SyncLedger ledger=new SyncLedger();ledger.capture(archived.state);
        check(ledger.materialize().getJSONArray("courses").length()==0,"capture retained invalid archived root");archive(ledger);
        check(input.equals(archived.state.toString()),"discarding archived root changed input");
        rejects(()->Planner.validate(archived.state),"direct backup ignored invalid archived course number");
        SyncLedger liveArchived=wire(archived.state);String wireBefore=liveArchived.value.toString();
        rejects(()->liveArchived.materialize(),"live archived row skipped required field decoding");rejects(()->archive(liveArchived),"archive skipped live archived number");
        check(wireBefore.equals(liveArchived.value.toString()),"rejected archived row changed ledger");

        JSONObject live=manualCourse().put("mergedSources",new JSONArray().put(CourseTools.copy(archived.root)));
        archived.state.getJSONArray("courses").put(live);String before=ledger.value.toString();
        rejects(()->ledger.capture(archived.state),"archived root ID bypassed live merged child number validation");
        check(before.equals(ledger.value.toString()),"rejected embedded archived child changed ledger");

        Fixture historical=fixture("active");number(historical,"60");SyncLedger tombstone=wire(historical.state);
        tombstone.records().getJSONObject("courses/"+historical.root.getString("id")).put("deleted",true);
        check(tombstone.materialize().getJSONArray("courses").length()==0,"unrelated course tombstone payload was decoded");archive(tombstone);
        JSONObject validChild=CourseTools.copy(historical.root);validChild.getJSONArray("manualLessons").getJSONObject(0).put("durationMinutes",60);
        JSONObject parent=manualCourse().put("mergedSources",new JSONArray().put(validChild));historical.state.getJSONArray("courses").put(parent);
        SyncLedger linked=wire(historical.state);linked.records().getJSONObject("courses/"+historical.root.getString("id")).put("deleted",true);
        JSONObject restored=linked.materialize();check(restored.getJSONArray("courses").length()==1,"source tombstone changed live parent");
        check(restored.getJSONArray("courses").getJSONObject(0).getJSONArray("mergedSources").getJSONObject(0).getJSONArray("manualLessons").getJSONObject(0).getInt("durationMinutes")==60,"valid embedded source was replaced by invalid tombstone payload");archive(linked);
    }
    public static void main(String[] args)throws Exception{
        invalidNumbers();invalidShapes();validNumbersAndExistingRanges();wireIntegerTokens();optionalManualTables();archivedRootsAndDeletedHistory();
        System.out.println("Manual lesson number integrity checks passed: "+checks);
    }
}
