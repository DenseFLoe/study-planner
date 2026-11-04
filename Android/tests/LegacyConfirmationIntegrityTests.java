package local.studyplanner;

import org.json.*;
import java.io.*;

public final class LegacyConfirmationIntegrityTests {
    static int checks;
    static final double NOW=800_000_000;
    interface Action { void run()throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{boolean rejected=false;try{action.run();}catch(IllegalArgumentException expected){rejected=true;}check(rejected,message);}
    static JSONObject fixture(int minutes,Integer canonical)throws Exception{
        JSONObject state=SyncExchangeTests.fixture(NOW),task=state.getJSONArray("tasks").getJSONObject(0);
        task.put("confirmedAt",NOW).put("completedMinutes",minutes).put("status",minutes==0?"missed":minutes==60?"completed":"partial");
        if(canonical!=null)state.getJSONArray("completions").put(new JSONObject().put("id",Planner.stableID("completion|"+task.getString("id"))).put("taskID",task.getString("id"))
            .put("courseID",task.getString("courseID")).put("minutes",canonical).put("recordedAt",NOW));return state;
    }
    static JSONObject archive(SyncLedger ledger)throws Exception{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));return CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray())).ledger.materialize();
    }
    static void invalidCredit()throws Exception{
        for(int minutes:new int[]{61,-1}){SyncLedger ledger=new SyncLedger();ledger.capture(fixture(minutes,null));String before=ledger.value.toString();
            rejects(()->ledger.materialize(),"legacy backfill accepted out-of-range credit");rejects(()->archive(ledger),"archive accepted invalid legacy credit");check(before.equals(ledger.value.toString()),"rejected legacy credit mutated ledger");}
    }
    static void stableValidCredit()throws Exception{
        for(int minutes:new int[]{0,20,60}){
            SyncLedger ledger=new SyncLedger();ledger.capture(fixture(minutes,null));JSONObject first=ledger.materialize();
            check(first.getJSONArray("completions").length()==1,"legacy completion was not backfilled exactly once");check(first.getJSONArray("completions").getJSONObject(0).getInt("minutes")==minutes,"legacy completion minutes changed");
            check(Planner.completed(first,first.getJSONArray("courses").getJSONObject(0))==minutes,"legacy progress changed");check(SyncLedger.equivalent(first,archive(ledger)),"legacy archive changed state");
            ledger.capture(first);JSONObject second=ledger.materialize();check(SyncLedger.equivalent(first,second),"normalized legacy state failed second materialization");check(SyncLedger.equivalent(first,archive(ledger)),"normalized legacy archive changed state");
            long sequence=ledger.sequence();ledger.capture(second);check(ledger.sequence()==sequence,"stable legacy roundtrip created another edit");
        }
    }
    static void canonicalAndUndo()throws Exception{
        for(int oldMinutes:new int[]{61,-1}){
            JSONObject state=fixture(oldMinutes,20);SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject confirmed=ledger.materialize();
            check(confirmed.getJSONArray("tasks").getJSONObject(0).getInt("completedMinutes")==20,"canonical completion did not override old credit");check(Planner.completed(confirmed,confirmed.getJSONArray("courses").getJSONObject(0))==20,"canonical progress changed");archive(ledger);
            ledger.records().getJSONObject("completions/"+state.getJSONArray("completions").getJSONObject(0).getString("id")).put("deleted",true);JSONObject undone=ledger.materialize(),task=undone.getJSONArray("tasks").getJSONObject(0);
            check(!task.has("confirmedAt")&&task.getInt("completedMinutes")==0,"undo did not clear legacy confirmation");check(undone.getJSONArray("completions").length()==0,"undo backfilled a new completion");check(SyncLedger.equivalent(undone,archive(ledger)),"undo archive changed state");
        }
    }
    static void removedHistory()throws Exception{
        for(boolean referenced:new boolean[]{false,true}){
            JSONObject state=fixture(61,referenced?20:null);SyncLedger ledger=new SyncLedger();ledger.capture(state);
            ledger.records().getJSONObject("tasks/"+state.getJSONArray("tasks").getJSONObject(0).getString("id")).put("deleted",true);JSONObject restored=ledger.materialize();
            check(restored.getJSONArray("tasks").length()==0,"removed confirmed task was restored");check(restored.getJSONArray("completions").length()==(referenced?1:0),"removed task backfilled historical credit");
            check(Planner.completed(restored,restored.getJSONArray("courses").getJSONObject(0))==(referenced?20:0),"removed task changed recorded progress");check(SyncLedger.equivalent(restored,archive(ledger)),"removed task archive changed state");
        }
    }
    public static void main(String[] args)throws Exception{invalidCredit();stableValidCredit();canonicalAndUndo();removedHistory();System.out.println("Legacy confirmation integrity checks passed: "+checks);}
}
