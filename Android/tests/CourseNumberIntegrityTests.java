package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class CourseNumberIntegrityTests {
    static int checks;
    static final double NOW=800_000_000;
    static final Object MISSING=new Object();
    interface Action { void run()throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{
        boolean rejected=false;try{action.run();}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,message);
    }
    static JSONObject fixture(Object total,boolean nested)throws Exception{
        JSONObject state=SyncExchangeTests.fixture(NOW);state.put("tasks",new JSONArray());JSONObject root=state.getJSONArray("courses").getJSONObject(0),target=root;
        if(nested){target=CourseTools.copy(root).put("id",Planner.id());root.put("type","不定时录播课程").put("mergedSources",new JSONArray().put(target));}
        if(total==MISSING)target.remove("totalMinutes");else target.put("totalMinutes",total);return state;
    }
    static SyncLedger wire(JSONObject state)throws Exception{
        SyncLedger ledger=new SyncLedger();ledger.capture(SyncExchangeTests.initial());
        for(JSONObject course:Planner.list(state.getJSONArray("courses"))){JSONObject row=new JSONObject().put("kind","courses").put("id",course.getString("id")).put("deleted",false).put("version",1).put("sequence",1).put("device","course-number-fixture");payload(row,course.toString());ledger.records().put(SyncLedger.key(row),row);}return ledger;
    }
    static void payload(JSONObject row,String json)throws Exception{row.put("payload",Base64.getEncoder().encodeToString(json.getBytes(StandardCharsets.UTF_8)));}
    static void archive(SyncLedger ledger)throws Exception{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
    }
    static void invalidNumbers()throws Exception{
        for(Object value:new Object[]{4294967416L,120.5,"120",true,JSONObject.NULL,MISSING})for(boolean nested:new boolean[]{false,true}){
            JSONObject state=fixture(value,nested),course=state.getJSONArray("courses").getJSONObject(0);SyncLedger ledger=new SyncLedger();ledger.capture(fixture(120,false));String before=ledger.value.toString(),input=state.toString();
            rejects(()->ledger.capture(state),"capture accepted invalid total, nested="+nested);check(before.equals(ledger.value.toString()),"course number rejection mutated ledger");check(input.equals(state.toString()),"course number rejection mutated state");
            rejects(()->Planner.validate(state),"backup accepted invalid total");rejects(()->Planner.validateCourseEdit(state,course,NOW),"editor truncated invalid total");
            SyncLedger imported=wire(state);String wireBefore=imported.value.toString();rejects(()->imported.materialize(),"sync accepted invalid total");rejects(()->archive(imported),"archive accepted invalid total");check(wireBefore.equals(imported.value.toString()),"materialization mutated invalid total");
        }
    }
    static void validNumbersAndExistingLimits()throws Exception{
        for(Object value:new Object[]{0,-1,Integer.MIN_VALUE,Integer.MAX_VALUE,600000,600001,120.0,new BigDecimal("1.2e2")})for(boolean nested:new boolean[]{false,true}){
            JSONObject state=fixture(value,nested),course=state.getJSONArray("courses").getJSONObject(0);int expected=new BigDecimal(value.toString()).intValueExact();
            Planner.validate(state);SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize().getJSONArray("courses").getJSONObject(0);
            JSONObject target=nested?restored.getJSONArray("mergedSources").getJSONObject(0):restored;check(target.getInt("totalMinutes")==expected,"representable total changed");archive(ledger);
            boolean accepted=true;try{Planner.validateCourseEdit(state,course,NOW);}catch(IllegalArgumentException error){accepted=false;}
            check(accepted==(nested||expected>0&&expected<=600000),"existing editor total limit changed");
        }
        for(String token:new String[]{"120.0","1.2e2","2147483647.0","0.0","-1e0"}){
            JSONObject state=fixture(120,false),course=state.getJSONArray("courses").getJSONObject(0);SyncLedger ledger=wire(state);
            String json=course.toString().replace("\"totalMinutes\":120","\"totalMinutes\":"+token);check(!json.equals(course.toString()),"wire token fixture was not replaced");
            payload(ledger.records().getJSONObject("courses/"+course.getString("id")),json);check(ledger.materialize().getJSONArray("courses").getJSONObject(0).getInt("totalMinutes")==new BigDecimal(token).intValueExact(),"integer-valued total rejected");archive(ledger);
        }
    }
    static void archivedRootsAndDeletedHistory()throws Exception{
        JSONObject state=fixture("invalid",false),archived=state.getJSONArray("courses").getJSONObject(0);archived.put("isArchived",true);SyncLedger ledger=new SyncLedger();ledger.capture(state);
        check(ledger.materialize().getJSONArray("courses").length()==0,"capture retained archived root");
        JSONObject live=CourseTools.copy(archived).put("id",Planner.id()).put("isArchived",false).put("totalMinutes",120).put("type","不定时录播课程").put("mergedSources",new JSONArray().put(CourseTools.copy(archived)));
        state.getJSONArray("courses").put(live);String before=ledger.value.toString();rejects(()->ledger.capture(state),"archived root ID incorrectly bypassed live merged child validation");check(before.equals(ledger.value.toString()),"bad merged child mutated ledger");
        JSONObject historical=fixture("invalid",false);SyncLedger old=wire(historical);old.records().getJSONObject("courses/"+historical.getJSONArray("courses").getJSONObject(0).getString("id")).put("deleted",true);
        check(old.materialize().getJSONArray("courses").length()==0,"ignored course tombstone was restored");archive(old);
    }
    public static void main(String[] args)throws Exception{invalidNumbers();validNumbersAndExistingLimits();archivedRootsAndDeletedHistory();System.out.println("Course number integrity checks passed: "+checks);}
}
