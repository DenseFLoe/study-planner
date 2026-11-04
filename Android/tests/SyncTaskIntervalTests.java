package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class SyncTaskIntervalTests {
    static int checks;
    static final double NOW=800_000_000;
    interface Action { void run()throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{
        boolean rejected=false;try{action.run();}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,message);
    }
    static JSONObject fixture()throws Exception{
        JSONObject state=SyncExchangeTests.fixture(NOW),task=state.getJSONArray("tasks").getJSONObject(0);
        task.put("start",NOW-3600);Planner.confirm(state,task.getString("id"),20,NOW);return state;
    }
    static void invert(JSONObject task,String kind)throws Exception{
        if(!kind.equals("endOnly"))task.put("floatingWindowStart",NOW+(kind.equals("startOnly")?60:-1800));
        if(!kind.equals("startOnly"))task.put("floatingWindowEnd",NOW+(kind.equals("endOnly")?-3660:-2400));
    }
    static void replaceTask(SyncLedger ledger,JSONObject task,boolean deleted)throws Exception{
        ledger.records().getJSONObject("tasks/"+task.getString("id")).put("deleted",deleted)
            .put("payload",Base64.getEncoder().encodeToString(task.toString().getBytes(StandardCharsets.UTF_8)));
    }
    static void archive(SyncLedger ledger)throws Exception{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
        CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
    }
    static void liveAndRecovered()throws Exception{
        for(String kind:new String[]{"both","startOnly","endOnly"})for(boolean recovered:new boolean[]{false,true}){
            JSONObject state=fixture(),task=state.getJSONArray("tasks").getJSONObject(0);SyncLedger ledger=new SyncLedger();ledger.capture(state);
            invert(task,kind);if(recovered){task.remove("confirmedAt");task.put("completedMinutes",0).put("status","planned");}
            replaceTask(ledger,task,recovered);String before=ledger.value.toString();
            rejects(()->ledger.materialize(),"materialize accepted inverted "+kind+", recovered="+recovered);
            rejects(()->archive(ledger),"archive accepted inverted task interval");
            check(before.equals(ledger.value.toString()),"interval validation mutated ledger");
        }
    }
    static void captureAndBackup()throws Exception{
        for(String kind:new String[]{"both","startOnly","endOnly"}){
            JSONObject state=fixture();SyncLedger ledger=new SyncLedger();ledger.capture(state);String before=ledger.value.toString();
            invert(state.getJSONArray("tasks").getJSONObject(0),kind);String input=state.toString();
            rejects(()->ledger.capture(state),"capture accepted inverted task interval");
            check(before.equals(ledger.value.toString()),"rejected capture mutated ledger");
            check(input.equals(state.toString()),"rejected capture mutated input");
            JSONObject backup=new JSONObject(input);rejects(()->Planner.validate(backup),"backup accepted inverted task interval");
        }
        JSONObject state=fixture();state.getJSONArray("courses").getJSONObject(0).put("isArchived",true);
        invert(state.getJSONArray("tasks").getJSONObject(0),"both");SyncLedger ledger=new SyncLedger();ledger.capture(state);
        check(ledger.materialize().getJSONArray("tasks").length()==0,"capture retained archived task");
        rejects(()->Planner.validate(state),"backup ignored malformed archived task");
    }
    static void compatibleWindows()throws Exception{
        for(String kind:new String[]{"none","startOnly","endOnly","both","equal","early"}){
            JSONObject state=fixture(),task=state.getJSONArray("tasks").getJSONObject(0);
            if(Arrays.asList("startOnly","both","early").contains(kind))task.put("floatingWindowStart",NOW-5400);
            if(Arrays.asList("endOnly","both","early").contains(kind))task.put("floatingWindowEnd",NOW+1800);
            if(kind.equals("equal"))task.put("floatingWindowStart",NOW-1800).put("floatingWindowEnd",NOW-1800);
            if(kind.equals("early")){task.put("confirmedAt",NOW-7200);state.getJSONArray("completions").getJSONObject(0).put("recordedAt",NOW-7200);}
            Planner.validate(state);SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize();
            check(SyncLedger.equivalent(restored.getJSONArray("tasks"),state.getJSONArray("tasks")),"compatible task changed: "+kind);
            check(Planner.completed(restored,restored.getJSONArray("courses").getJSONObject(0))==20,"compatible interval lost progress");
            archive(ledger);Planner.refreshDiagnostics(restored,NOW);
        }
    }
    static void ignoredTombstones()throws Exception{
        for(boolean referenced:new boolean[]{false,true}){
            JSONObject state=fixture(),task=state.getJSONArray("tasks").getJSONObject(0);SyncLedger ledger=new SyncLedger();ledger.capture(state);
            invert(task,"both");replaceTask(ledger,task,true);
            if(!referenced)ledger.records().getJSONObject("completions/"+state.getJSONArray("completions").getJSONObject(0).getString("id")).put("deleted",true);
            JSONObject restored=ledger.materialize();check(restored.getJSONArray("tasks").length()==0,"historical tombstone was restored");
            check(restored.getJSONArray("completions").length()==(referenced?1:0),"historical progress changed");archive(ledger);
        }
    }
    static void mergedTombstones()throws Exception{
        for(boolean inverted:new boolean[]{false,true}){
            JSONObject state=fixture(),original=CourseTools.copy(state.getJSONArray("tasks").getJSONObject(0));
            JSONObject second=CourseTools.copy(state.getJSONArray("courses").getJSONObject(0)).put("id",Planner.id()).put("name","Second");state.getJSONArray("courses").put(second);
            SyncLedger ledger=new SyncLedger();ledger.capture(state);
            JSONObject merged=CourseTools.merge(state,new HashSet<>(Arrays.asList(original.getString("courseID"),second.getString("id"))),"Merged");ledger.capture(state);
            if(inverted)invert(original,"both");else original.put("floatingWindowStart",NOW-5400);
            replaceTask(ledger,original,true);
            if(inverted){rejects(()->ledger.materialize(),"merged recovery accepted inverted confirmed tombstone");rejects(()->archive(ledger),"merged archive accepted inverted recovered task");}
            else{
                JSONObject restored=ledger.materialize();check(restored.getJSONArray("tasks").getJSONObject(0).getString("courseID").equals(merged.getString("id")),"merged task was not restored");
                check(Planner.completed(restored,Planner.course(restored,merged.getString("id")))==20,"merged task lost progress");
            }
        }
    }
    public static void main(String[] args)throws Exception{
        liveAndRecovered();captureAndBackup();compatibleWindows();ignoredTombstones();mergedTombstones();
        System.out.println("Sync task interval checks passed: "+checks);
    }
}
