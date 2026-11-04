package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Date primitives must survive Swift decoding; malformed progress must not replace saved data. */
public final class CompletionDateIntegrityTests {
    static int checks;
    interface Action {void run()throws Exception;}
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{try{action.run();throw new AssertionError(message);}catch(IllegalArgumentException expected){checks++;}}
    static JSONObject fixture(boolean linked)throws Exception{return CompletionNumberIntegrityTests.fixture(linked);}
    static JSONObject record(JSONObject state)throws Exception{return state.getJSONArray("completions").getJSONObject(0);}
    static void invalidDates()throws Exception{
        for(String key:new String[]{"recordedAt","studyDate"})for(boolean linked:new boolean[]{false,true}){
            List<Object> values=new ArrayList<>(Arrays.asList("800000000","not a date",true,new JSONObject(),new JSONArray(),new BigDecimal("1e400")));
            if(key.equals("recordedAt"))values.add(JSONObject.NULL);
            for(Object value:values){
                JSONObject state=fixture(linked);SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);String before=SyncLedger.canonical(ledger.value);
                record(state).put(key,value);String input=SyncLedger.canonical(state);
                rejects(()->Planner.validate(state),"Validation accepted malformed "+key);
                rejects(()->ledger.capture(state,2000),"Capture accepted malformed "+key);
                check(before.equals(SyncLedger.canonical(ledger.value)),"Rejected date capture changed ledger");
                check(input.equals(SyncLedger.canonical(state)),"Rejected date validation changed progress");
                byte[] raw=state.toString().getBytes(StandardCharsets.UTF_8);
                rejects(()->PlannerBackupFile.read(new ByteArrayInputStream(raw)),"Backup accepted malformed "+key);
                CompletionNumberIntegrityTests.payload(ledger.records().getJSONObject("completions/"+record(state).getString("id")),record(state).toString());
                String wire=SyncLedger.canonical(ledger.value);
                rejects(()->ledger.materialize(),"Materialization accepted malformed "+key+", linked="+linked);
                rejects(()->CompletionNumberIntegrityTests.archive(ledger),"Cloud archive accepted malformed "+key);
                check(wire.equals(SyncLedger.canonical(ledger.value)),"Rejected date wire changed ledger");
            }
        }
        JSONObject missing=fixture(false);record(missing).remove("recordedAt");
        rejects(()->Planner.validate(missing),"Missing required recordedAt was accepted");
        rejects(()->new SyncLedger().capture(missing),"Missing recordedAt was captured");
    }
    static void validDates()throws Exception{
        for(Object value:new Object[]{0,-1,1L,1.25,-1.25,new BigDecimal("1e0"),800_000_000.125}){
            JSONObject state=fixture(false);record(state).put("recordedAt",value).put("studyDate",value);String before=SyncLedger.canonical(state);
            Planner.validate(state);SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);JSONObject restored=ledger.materialize();
            check(record(restored).getDouble("recordedAt")==((Number)value).doubleValue(),"Valid timestamp changed");
            check(record(restored).getDouble("studyDate")==((Number)value).doubleValue(),"Valid study date changed");
            check(before.equals(SyncLedger.canonical(state)),"Valid date validation rewrote raw fields");
            CompletionNumberIntegrityTests.archive(ledger);
        }
        for(boolean nullDate:new boolean[]{false,true}){
            JSONObject state=fixture(true);if(nullDate)record(state).put("studyDate",JSONObject.NULL);else record(state).remove("studyDate");
            Planner.validate(state);SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);JSONObject restored=ledger.materialize();
            check(Planner.completed(restored,restored.getJSONArray("courses").getJSONObject(0))==20,"Legacy date lost credited progress");
            check(DailyConsequences.effectiveDay(record(restored),restored)!=null,"Same-day legacy record lost date attribution");
        }
    }
    static void ignoredHistory()throws Exception{
        JSONObject archived=fixture(true);archived.getJSONArray("courses").getJSONObject(0).put("isArchived",true);record(archived).put("recordedAt","invalid");
        SyncLedger ledger=new SyncLedger();ledger.capture(archived,1000);
        check(ledger.materialize().getJSONArray("completions").length()==0,"Archived progress was retained");
        rejects(()->Planner.validate(archived),"Backup ignored malformed archived progress");
        JSONObject state=fixture(true);ledger=new SyncLedger();ledger.capture(state,1000);JSONObject row=ledger.records().getJSONObject("completions/"+record(state).getString("id"));
        JSONObject payload=CourseTools.copy(record(state)).put("recordedAt","invalid");CompletionNumberIntegrityTests.payload(row,payload.toString());row.put("deleted",true);
        check(ledger.materialize().getJSONArray("completions").length()==0,"Deleted invalid record was restored");
        CompletionNumberIntegrityTests.archive(ledger);
    }
    public static void main(String[]args)throws Exception{invalidDates();validDates();ignoredHistory();System.out.println("Completion dates: "+checks+" checks passed");}
}
