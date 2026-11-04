package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class CompletionNumberIntegrityTests {
    static int checks;
    static final double NOW=800_000_000;
    interface Action { void run()throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{
        boolean rejected=false;try{action.run();}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,message);
    }
    static JSONObject fixture(boolean linked)throws Exception{
        JSONObject state=SyncExchangeTests.fixture(NOW);
        Planner.confirm(state,state.getJSONArray("tasks").getJSONObject(0).getString("id"),20,NOW);
        if(!linked)state.put("tasks",new JSONArray());return state;
    }
    static JSONObject completion(JSONObject state)throws Exception{return state.getJSONArray("completions").getJSONObject(0);}
    static void payload(JSONObject row,String json)throws Exception{
        row.put("payload",Base64.getEncoder().encodeToString(json.getBytes(StandardCharsets.UTF_8)));
    }
    static void archive(SyncLedger ledger)throws Exception{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
        CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
    }
    static void invalidNumbers()throws Exception{
        Map<String,Object> invalid=new LinkedHashMap<>();
        invalid.put("negative",-1);invalid.put("fractional",1.5);invalid.put("numeric string","2");
        invalid.put("boolean",true);invalid.put("null",JSONObject.NULL);
        invalid.put("int overflow",2147483648L);invalid.put("wrapped positive long",4294967297L);
        invalid.put("long maximum",Long.MAX_VALUE);invalid.put("big integer",new BigInteger("18446744073709551617"));
        for(Map.Entry<String,Object> sample:invalid.entrySet())for(boolean linked:new boolean[]{false,true}){
            JSONObject state=fixture(linked);SyncLedger ledger=new SyncLedger();ledger.capture(state);
            completion(state).put("minutes",sample.getValue());String input=state.toString(),before=ledger.value.toString();
            rejects(()->ledger.capture(state),"capture accepted "+sample.getKey()+", linked="+linked);
            check(before.equals(ledger.value.toString()),"rejected number capture mutated ledger");
            check(input.equals(state.toString()),"rejected number capture mutated state");
            rejects(()->Planner.validate(new JSONObject(input)),"backup accepted "+sample.getKey());
            payload(ledger.records().getJSONObject("completions/"+completion(state).getString("id")),completion(state).toString());
            String wireBefore=ledger.value.toString();
            rejects(()->ledger.materialize(),"materialize accepted "+sample.getKey()+", linked="+linked);
            rejects(()->archive(ledger),"archive accepted "+sample.getKey());
            check(wireBefore.equals(ledger.value.toString()),"rejected number materialization mutated ledger");
        }
    }
    static void validNumbers()throws Exception{
        for(Object number:new Object[]{0,1,1L,1.0,new BigDecimal("1e0"),1441,Integer.MAX_VALUE})for(boolean linked:new boolean[]{false,true}){
            int minutes=new BigDecimal(number.toString()).intValueExact();if(linked&&minutes>60)continue;
            JSONObject state=fixture(linked);completion(state).put("minutes",number);Planner.validate(state);
            SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize();
            check(completion(restored).getInt("minutes")==minutes,"exact supported minutes changed");
            check(Planner.completed(restored,restored.getJSONArray("courses").getJSONObject(0))==Math.min(120,minutes),"exact supported progress changed");
            if(linked)check(restored.getJSONArray("tasks").getJSONObject(0).getInt("completedMinutes")==minutes,"exact linked confirmation changed");
            archive(ledger);
        }
        // Preserve the exact JSON spellings accepted by Swift Int decoding.
        for(String token:new String[]{"1.0","1e0","2147483647.0"}){
            JSONObject state=fixture(false);SyncLedger ledger=new SyncLedger();ledger.capture(state);
            String json=completion(state).toString().replace("\"minutes\":20","\"minutes\":"+token);
            check(!json.equals(completion(state).toString()),"numeric wire fixture did not replace the token");
            payload(ledger.records().getJSONObject("completions/"+completion(state).getString("id")),json);
            int expected=new BigDecimal(token).intValueExact();check(completion(ledger.materialize()).getInt("minutes")==expected,"integer-valued wire number rejected");archive(ledger);
        }
    }
    static void ignoredDeletedRows()throws Exception{
        JSONObject state=fixture(true);SyncLedger ledger=new SyncLedger();ledger.capture(state);
        JSONObject old=CourseTools.copy(completion(state)).put("id",Planner.id()).put("taskID",Planner.id()).put("minutes","not a number");
        JSONObject row=CourseTools.copy(ledger.records().getJSONObject("completions/"+completion(state).getString("id"))).put("id",old.getString("id")).put("deleted",true);
        payload(row,old.toString());ledger.records().put(SyncLedger.key(row),row);
        check(Planner.completed(ledger.materialize(),state.getJSONArray("courses").getJSONObject(0))==20,"ignored historical row changed progress");archive(ledger);
        JSONObject archived=fixture(true);archived.getJSONArray("courses").getJSONObject(0).put("isArchived",true);completion(archived).put("minutes","not a number");
        SyncLedger discarded=new SyncLedger();discarded.capture(archived);
        check(discarded.materialize().getJSONArray("completions").length()==0,"capture retained archived completion");
        rejects(()->Planner.validate(archived),"backup skipped malformed original archived completion");
    }
    static void rejectBeforeMergedTaskReconciliation()throws Exception{
        JSONObject state=fixture(true),original=CourseTools.copy(completion(state));
        JSONObject second=CourseTools.copy(state.getJSONArray("courses").getJSONObject(0)).put("id",Planner.id()).put("name","Second");state.getJSONArray("courses").put(second);
        SyncLedger ledger=new SyncLedger();ledger.capture(state);
        CourseTools.merge(state,new HashSet<>(Arrays.asList(original.getString("courseID"),second.getString("id"))),"Merged");ledger.capture(state);
        original.put("minutes",4294967297L);payload(ledger.records().getJSONObject("completions/"+original.getString("id")),original.toString());
        String before=ledger.value.toString();rejects(()->ledger.materialize(),"merged reconciliation truncated completion minutes");
        check(before.equals(ledger.value.toString()),"rejected merged completion mutated ledger");
    }
    public static void main(String[] args)throws Exception{
        invalidNumbers();validNumbers();ignoredDeletedRows();rejectBeforeMergedTaskReconciliation();
        System.out.println("Completion number integrity checks passed: "+checks);
    }
}
