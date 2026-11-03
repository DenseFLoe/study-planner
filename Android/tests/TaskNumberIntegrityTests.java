package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class TaskNumberIntegrityTests {
    static int checks;
    static final double NOW=800_000_000;
    static final Object MISSING=new Object();
    interface Action { void run()throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{
        boolean rejected=false;try{action.run();}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,message);
    }
    static JSONObject fixture(String mode)throws Exception{
        JSONObject state=SyncExchangeTests.fixture(NOW),task=state.getJSONArray("tasks").getJSONObject(0);
        if(mode.equals("canonical"))Planner.confirm(state,task.getString("id"),20,NOW);
        if(mode.equals("legacy"))task.put("confirmedAt",NOW).put("status","partial").put("completedMinutes",20);
        return state;
    }
    static JSONObject task(JSONObject state)throws Exception{return state.getJSONArray("tasks").getJSONObject(0);}
    static void set(JSONObject task,String field,Object value)throws Exception{if(value==MISSING)task.remove(field);else task.put(field,value);}
    static void replaceTask(SyncLedger ledger,JSONObject task,boolean deleted)throws Exception{
        JSONObject row=ledger.records().getJSONObject("tasks/"+task.getString("id"));row.put("deleted",deleted);payload(row,task.toString());
    }
    static void payload(JSONObject row,String json)throws Exception{row.put("payload",Base64.getEncoder().encodeToString(json.getBytes(StandardCharsets.UTF_8)));}
    static void archive(SyncLedger ledger)throws Exception{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
    }
    static Object[] badValues(String field){int normal=field.equals("durationMinutes")?60:20;return new Object[]{4294967296L+normal,normal+0.5,String.valueOf(normal),true,JSONObject.NULL,MISSING};}
    static void invalidLiveNumbers()throws Exception{
        for(String field:new String[]{"durationMinutes","completedMinutes"})for(Object value:badValues(field))for(String mode:new String[]{"unconfirmed","canonical","legacy"}){
            JSONObject state=fixture(mode);SyncLedger ledger=new SyncLedger();ledger.capture(state);String before=ledger.value.toString();set(task(state),field,value);String input=state.toString();
            rejects(()->ledger.capture(state),"capture accepted bad "+field+" in "+mode);check(before.equals(ledger.value.toString()),"task number capture mutated ledger");check(input.equals(state.toString()),"task number capture mutated input");
            rejects(()->Planner.validate(state),"backup accepted bad task number");replaceTask(ledger,task(state),false);String wireBefore=ledger.value.toString();
            rejects(()->ledger.materialize(),"reconciliation accepted bad "+field+" in "+mode);rejects(()->archive(ledger),"archive accepted bad task number");check(wireBefore.equals(ledger.value.toString()),"task number materialization mutated ledger");
        }
    }
    static void invalidReferencedTombstones()throws Exception{
        for(String field:new String[]{"durationMinutes","completedMinutes"})for(Object value:badValues(field))for(boolean confirmed:new boolean[]{false,true}){
            JSONObject state=fixture("canonical");SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject old=task(state);
            if(!confirmed){old.remove("confirmedAt");old.put("completedMinutes",0).put("status","planned");}set(old,field,value);replaceTask(ledger,old,true);String before=ledger.value.toString();
            rejects(()->ledger.materialize(),"referenced tombstone accepted bad "+field+", confirmed="+confirmed);rejects(()->archive(ledger),"archive accepted bad referenced tombstone");check(before.equals(ledger.value.toString()),"rejected tombstone changed ledger");
        }
    }
    static void validNumbers()throws Exception{
        for(String field:new String[]{"durationMinutes","completedMinutes"}){
            Object[] values=field.equals("durationMinutes")?new Object[]{1,60L,60.0,new BigDecimal("6e1"),1441}:new Object[]{0,20L,20.0,new BigDecimal("2e1"),1441,Integer.MAX_VALUE,-1,Integer.MIN_VALUE};
            for(Object value:values){JSONObject state=fixture("unconfirmed");set(task(state),field,value);Planner.validate(state);SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize();check(task(restored).getInt(field)==new BigDecimal(value.toString()).intValueExact(),"valid task number changed");archive(ledger);}
            for(String token:field.equals("durationMinutes")?new String[]{"60.0","6e1","1441.0"}:new String[]{"20.0","2e1","0.0","-1e0"}){
                JSONObject state=fixture("unconfirmed");SyncLedger ledger=new SyncLedger();ledger.capture(state);int original=task(state).getInt(field);
                String json=task(state).toString().replace("\""+field+"\":"+original,"\""+field+"\":"+token);check(!json.equals(task(state).toString()),"wire numeric fixture was not replaced");
                payload(ledger.records().getJSONObject("tasks/"+task(state).getString("id")),json);check(task(ledger.materialize()).getInt(field)==new BigDecimal(token).intValueExact(),"integer-valued task token rejected");archive(ledger);
            }
        }
    }
    static void existingConfirmationSemantics()throws Exception{
        for(String mode:new String[]{"canonical","undo","unconfirmed","deletedConfirmed"}){
            JSONObject state=fixture(mode.equals("canonical")||mode.equals("undo")||mode.equals("deletedConfirmed")?"canonical":"unconfirmed");
            task(state).put("completedMinutes",-1);SyncLedger ledger=new SyncLedger();ledger.capture(state);
            if(mode.equals("undo"))ledger.records().getJSONObject("completions/"+state.getJSONArray("completions").getJSONObject(0).getString("id")).put("deleted",true);
            if(mode.equals("deletedConfirmed")){task(state).put("durationMinutes",0);replaceTask(ledger,task(state),true);}
            JSONObject restored=ledger.materialize();
            if(mode.equals("deletedConfirmed"))check(restored.getJSONArray("tasks").length()==0&&restored.getJSONArray("completions").length()==1,"ignored typed tombstone semantics changed");
            else check(task(restored).getInt("completedMinutes")==(mode.equals("canonical")?20:mode.equals("undo")?0:-1),"typed confirmation semantics changed: "+mode);
            archive(ledger);
        }
        JSONObject negative=fixture("legacy");task(negative).put("completedMinutes",-1);SyncLedger ledger=new SyncLedger();ledger.capture(negative);rejects(()->ledger.materialize(),"negative legacy completion is no longer rejected");
        for(int duration:new int[]{0,-1}){JSONObject state=fixture("unconfirmed");task(state).put("durationMinutes",duration);rejects(()->Planner.validate(state),"existing positive duration rule changed");}
    }
    static void ignoredHistoryAndArchivedTasks()throws Exception{
        JSONObject state=fixture("unconfirmed");SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject old=CourseTools.copy(task(state)).put("id",Planner.id());old.remove("durationMinutes");old.remove("completedMinutes");
        JSONObject row=CourseTools.copy(ledger.records().getJSONObject("tasks/"+task(state).getString("id"))).put("id",old.getString("id")).put("deleted",true);payload(row,old.toString());ledger.records().put(SyncLedger.key(row),row);
        check(ledger.materialize().getJSONArray("tasks").length()==1,"unreferenced historical task was not ignored");archive(ledger);
        state.getJSONArray("courses").getJSONObject(0).put("isArchived",true);task(state).remove("durationMinutes");task(state).remove("completedMinutes");SyncLedger archived=new SyncLedger();archived.capture(state);
        check(archived.materialize().getJSONArray("tasks").length()==0,"capture checked discarded archived task");rejects(()->Planner.validate(state),"backup skipped malformed original task");
    }
    static void mergedRecovery()throws Exception{
        for(String field:new String[]{"durationMinutes","completedMinutes"}){
            JSONObject state=fixture("canonical"),old=CourseTools.copy(task(state)),second=CourseTools.copy(state.getJSONArray("courses").getJSONObject(0)).put("id",Planner.id()).put("name","Second");state.getJSONArray("courses").put(second);
            SyncLedger ledger=new SyncLedger();ledger.capture(state);CourseTools.merge(state,new HashSet<>(Arrays.asList(old.getString("courseID"),second.getString("id"))),"Merged");ledger.capture(state);
            old.put(field,field.equals("durationMinutes")?4294967356L:4294967316L);replaceTask(ledger,old,true);String before=ledger.value.toString();
            rejects(()->ledger.materialize(),"merged recovery truncated original task field");check(before.equals(ledger.value.toString()),"merged task rejection mutated ledger");
        }
    }
    public static void main(String[] args)throws Exception{invalidLiveNumbers();invalidReferencedTombstones();validNumbers();existingConfirmationSemantics();ignoredHistoryAndArchivedTasks();mergedRecovery();System.out.println("Task number integrity checks passed: "+checks);}
}
