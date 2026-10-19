package local.studyplanner;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

public final class SyncExchangeTests {
    static int checks;
    static void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    static JSONObject initial()throws Exception{return new JSONObject(new String(Files.readAllBytes(new File("Android/assets/initial-state.json").toPath()),StandardCharsets.UTF_8));}
    static SyncExchange.Result exchange(SyncLedger ledger,JSONArray changes,long cursor)throws Exception{
        JSONObject wire=new JSONObject().put("protocol",1).put("cursor",cursor).put("changes",changes).put("automatic",false).put("date","2026-10-19");
        StringWriter encoded=new StringWriter();SyncJSON.write(encoded,wire);
        return SyncExchange.apply(ledger,consumer->SyncJSON.readExchange(new StringReader(encoded.toString()),consumer),Planner.now());
    }
    public static void main(String[] args)throws Exception{
        JSONObject state=initial();String courseID=Planner.id();
        state.getJSONArray("courses").put(new JSONObject().put("id",courseID).put("name","Confirmation fixture").put("type","录播课程").put("totalMinutes",120)
            .put("initialCompletedMinutes",0).put("startDate",0).put("deadline",1000000000).put("minimumBlockMinutes",60).put("priority",2).put("color","blue").put("autoScheduleEnabled",false).put("isArchived",false).put("notes",""));
        double now=Planner.now();
        for(int i=0;i<2;i++){
            String id=Planner.stableID("duplicate-confirmation-"+i);state.getJSONArray("tasks").put(new JSONObject().put("id",id).put("courseID",courseID)
                .put("start",now-3600).put("durationMinutes",30).put("completedMinutes",10+i*10).put("confirmedAt",now-600).put("status","partial"));
        }
        SyncLedger ledger=new SyncLedger();ledger.capture(state);exchange(ledger,new JSONArray(),0);
        JSONObject merged=ledger.materialize();check(merged.getJSONArray("tasks").length()==1,"duplicate task retained");
        check(merged.getJSONArray("completions").length()==1,"duplicate completion credit retained");
        check(merged.getJSONArray("completions").getJSONObject(0).getInt("minutes")==merged.getJSONArray("tasks").getJSONObject(0).getInt("completedMinutes"),"completion differs from winning task");
        check(state.getJSONArray("tasks").length()==2&&state.getJSONArray("completions").length()==0,"capture/exchange mutated the UI state");
        long revision=ledger.sequence();exchange(ledger,new JSONArray(),0);check(ledger.sequence()==revision,"retry changed confirmations");
        SyncLedger peer=new SyncLedger(CourseTools.copy(ledger.value));peer.value.put("device","ZZZ-OFFLINE");JSONObject deleted=peer.materialize();Planner.removeCourse(deleted,courseID);peer.capture(deleted);
        exchange(ledger,peer.changes(0),0);merged=ledger.materialize();
        check(merged.getJSONArray("courses").length()==0&&merged.getJSONArray("tasks").length()==0&&merged.getJSONArray("completions").length()==0,"deletion left course history behind");
        boolean rejected=false;try{exchange(ledger,new JSONArray(),ledger.sequence()+1);}catch(Exception expected){rejected=true;}check(rejected,"future cursor accepted");
        System.out.println("PASS "+checks+" exchange checks: duplicate confirmations, retry, UI isolation, course deletion and invalid cursor");
    }
}
