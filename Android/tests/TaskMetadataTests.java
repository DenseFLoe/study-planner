package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Accepted task payloads must remain readable across Android, server and Swift Codable. */
public final class TaskMetadataTests {
    static int checks;
    interface Action {void run()throws Exception;}
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{
        try{action.run();throw new AssertionError(message);}catch(IllegalArgumentException expected){checks++;}
    }
    static final class Sample {
        final String key;final Object value;
        Sample(String key,Object value){this.key=key;this.value=value;}
    }
    static List<Sample> invalid(){
        List<Sample> values=new ArrayList<>();
        for(String key:new String[]{"start","confirmedAt","floatingWindowStart","floatingWindowEnd"})
            for(Object value:new Object[]{"815414400",true,new JSONObject(),new JSONArray(),new BigDecimal("1e400")})values.add(new Sample(key,value));
        values.add(new Sample("start",JSONObject.NULL));
        for(String key:new String[]{"lessonID","lessonName"})
            for(Object value:new Object[]{1,true,new JSONObject(),new JSONArray()})values.add(new Sample(key,value));
        for(Object value:new Object[]{"true",1,new JSONObject(),new JSONArray()})values.add(new Sample("replacesConfirmedBlock",value));
        return values;
    }
    static JSONObject fixture()throws Exception{return OptionalTaskFieldsTests.fixture();}
    static JSONObject task(JSONObject state)throws Exception{return OptionalTaskFieldsTests.first(state);}
    static void captureAndBackup()throws Exception{
        for(Sample sample:invalid()){
            JSONObject state=fixture();SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);String before=SyncLedger.canonical(ledger.value);
            task(state).put(sample.key,sample.value);String input=SyncLedger.canonical(state);
            rejects(()->Planner.validate(state),"Validation accepted malformed "+sample.key);
            rejects(()->ledger.capture(state,2000),"Capture accepted malformed "+sample.key);
            check(before.equals(SyncLedger.canonical(ledger.value)),"Rejected capture changed ledger");
            check(input.equals(SyncLedger.canonical(state)),"Rejected task validation changed source");
            byte[] encoded=state.toString().getBytes(StandardCharsets.UTF_8);
            rejects(()->PlannerBackupFile.read(new ByteArrayInputStream(encoded)),"Backup accepted malformed "+sample.key);
        }
    }
    static void liveAndRecoveredWire()throws Exception{
        for(boolean deleted:new boolean[]{false,true})for(Sample sample:invalid()){
            JSONObject state=fixture();String id=task(state).getString("id");
            if(deleted)Planner.confirm(state,id,20,OptionalTaskFieldsTests.NOW);
            SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);JSONObject original=task(state);
            if(deleted){original.remove("confirmedAt");original.put("completedMinutes",0).put("status","planned");}
            original.put(sample.key,sample.value);
            ledger.records().getJSONObject("tasks/"+id).put("deleted",deleted).put("payload",Base64.getEncoder().encodeToString(original.toString().getBytes(StandardCharsets.UTF_8)));
            String before=SyncLedger.canonical(ledger.value);
            rejects(()->ledger.materialize(),"Materialization accepted malformed "+sample.key+", tombstone="+deleted);
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
            rejects(()->CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray())),"Cloud archive accepted malformed task");
            check(before.equals(SyncLedger.canonical(ledger.value)),"Rejected wire payload changed ledger");
        }
    }
    static void optionalCompatibility()throws Exception{
        for(Object flag:new Object[]{JSONObject.NULL,false,true}){
            JSONObject state=fixture();Planner.replan(state,OptionalTaskFieldsTests.NOW);Set<String> ids=new HashSet<>();
            for(JSONObject task:Planner.list(state.getJSONArray("tasks"))){ids.add(task.getString("id"));task.put("replacesConfirmedBlock",flag).put("lessonID",JSONObject.NULL).put("lessonName",JSONObject.NULL);}
            Planner.validate(state);SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);JSONObject restored=ledger.materialize();
            Planner.replan(restored,OptionalTaskFieldsTests.NOW);Set<String> after=new HashSet<>();
            for(JSONObject task:Planner.list(restored.getJSONArray("tasks"))){after.add(task.getString("id"));
                check(flag==JSONObject.NULL?!task.optBoolean("replacesConfirmedBlock"):Boolean.valueOf(task.getBoolean("replacesConfirmedBlock")).equals(flag),"Valid replacement semantics changed");}
            check(ids.equals(after),"Optional flag caused task identity churn");
            check(restored.getJSONArray("completions").length()==0,"Optional metadata invented progress");
        }
        JSONObject state=fixture();JSONObject task=task(state);task.put("confirmedAt",0.0).put("status","missed").put("lessonID","").put("lessonName","");
        Planner.validate(state);SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);JSONObject restored=ledger.materialize();
        check(task(restored).getDouble("confirmedAt")==0&&task(restored).getString("lessonID").isEmpty(),"Zero timestamp or empty legacy strings were rejected");
        JSONObject ignored=fixture();ledger=new SyncLedger();ledger.capture(ignored,1000);
        JSONObject row=ledger.records().getJSONObject("tasks/"+task(ignored).getString("id"));row.put("deleted",true).put("payload",Base64.getEncoder().encodeToString("{}".getBytes(StandardCharsets.UTF_8)));
        check(ledger.materialize().getJSONArray("tasks").length()==0,"Unreferenced historical tombstone is no longer ignorable");
    }
    public static void main(String[]args)throws Exception{captureAndBackup();liveAndRecoveredWire();optionalCompatibility();System.out.println("Task metadata: "+checks+" checks passed");}
}
