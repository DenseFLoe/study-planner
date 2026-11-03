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
    static JSONObject fixture(double now)throws Exception{
        JSONObject state=initial();String id=Planner.id();
        state.getJSONArray("courses").put(new JSONObject().put("id",id).put("name","Offline confirmation").put("type","录播课程").put("totalMinutes",120)
            .put("initialCompletedMinutes",0).put("startDate",now-86400).put("deadline",now+86400).put("minimumBlockMinutes",60).put("priority",2)
            .put("color","blue").put("autoScheduleEnabled",false).put("isArchived",false).put("notes",""));
        state.getJSONArray("tasks").put(Planner.task(id,now-7200,60));return state;
    }
    static void duplicateCompletionIntegrity()throws Exception{
        double now=Planner.now();JSONObject state=fixture(now);
        Planner.confirm(state,state.getJSONArray("tasks").getJSONObject(0).getString("id"),20,now);
        SyncLedger ledger=new SyncLedger();ledger.capture(state);String before=ledger.value.toString();
        JSONObject duplicate=CourseTools.copy(state.getJSONArray("completions").getJSONObject(0)).put("id",Planner.id()).put("minutes",30);
        state.getJSONArray("completions").put(duplicate);
        boolean rejected=false;try{ledger.capture(state);}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,"capture silently overwrote duplicate task confirmations");
        check(before.equals(ledger.value.toString()),"rejected capture changed ledger");
        JSONObject row=new JSONObject().put("kind","completions").put("id",duplicate.getString("id"))
            .put("payload",java.util.Base64.getEncoder().encodeToString(duplicate.toString().getBytes(StandardCharsets.UTF_8)))
            .put("deleted",false).put("version",1).put("device","integrity-peer").put("sequence",1);
        ledger.merge(new JSONArray().put(row));before=ledger.value.toString();
        rejected=false;try{ledger.materialize();}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,"wire duplicate task confirmations were accepted");
        check(before.equals(ledger.value.toString()),"rejected materialization changed ledger");
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
        rejected=false;try{CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,"cloud archive accepted duplicate task confirmations");
        row.put("deleted",true).put("version",2);ledger.merge(new JSONArray().put(row));
        check(ledger.materialize().getJSONArray("completions").length()==1,"deleted legacy confirmation counted as a duplicate");

        // Preserve compatibility with a single old, non-canonical completion ID.
        ledger=new SyncLedger();state.getJSONArray("completions").remove(1);ledger.capture(state);
        String key="completions/"+state.getJSONArray("completions").getJSONObject(0).getString("id");
        row=CourseTools.copy(ledger.records().getJSONObject(key));ledger.records().remove(key);
        JSONObject legacy=SyncLedger.payload(row).put("id",Planner.id());row.put("id",legacy.getString("id"))
            .put("payload",java.util.Base64.getEncoder().encodeToString(legacy.toString().getBytes(StandardCharsets.UTF_8)));
        ledger.merge(new JSONArray().put(row));JSONObject restored=ledger.materialize();
        check(restored.getJSONArray("completions").getJSONObject(0).getString("id").equals(legacy.getString("id")),"single legacy completion rejected");
        check(restored.getJSONArray("tasks").getJSONObject(0).getInt("completedMinutes")==20,"legacy completion progress changed");
    }
    static SyncLedger mismatchedTaskTombstoneFixture()throws Exception{
        double now=Planner.now();JSONObject state=fixture(now),task=state.getJSONArray("tasks").getJSONObject(0);
        JSONObject other=CourseTools.copy(task).put("id",Planner.id());
        Planner.confirm(state,task.getString("id"),20,now);SyncLedger ledger=new SyncLedger();ledger.capture(state);
        JSONObject wrong=CourseTools.copy(other).put("id",Planner.id());
        ledger.records().getJSONObject("tasks/"+task.getString("id")).put("deleted",true)
            .put("payload",java.util.Base64.getEncoder().encodeToString(wrong.toString().getBytes(StandardCharsets.UTF_8)));
        return ledger;
    }
    static void referencedTombstoneIntegrity()throws Exception{
        SyncLedger ledger=mismatchedTaskTombstoneFixture();String before=ledger.value.toString();
        boolean rejected=false;try{ledger.materialize();}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,"task tombstone restored a different payload identity");
        check(before.equals(ledger.value.toString()),"rejected task recovery changed the ledger");
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
        rejected=false;try{CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,"cloud archive accepted mismatched task tombstone identity");
    }
    static void completionCourseIntegrity()throws Exception{
        for(String kind:new String[]{"live","deletedDraft","deletedConfirmed"}){
            double now=Planner.now();JSONObject state=fixture(now),task=state.getJSONArray("tasks").getJSONObject(0);
            JSONObject other=CourseTools.copy(state.getJSONArray("courses").getJSONObject(0)).put("id",Planner.id()).put("name","Other course");
            state.getJSONArray("courses").put(other);Planner.confirm(state,task.getString("id"),20,now);
            if(kind.equals("deletedDraft")){task.remove("confirmedAt");task.put("completedMinutes",0).put("status","planned");}
            SyncLedger ledger=new SyncLedger();ledger.capture(state);
            JSONObject record=state.getJSONArray("completions").getJSONObject(0);record.put("courseID",other.getString("id"));
            ledger.records().getJSONObject("completions/"+record.getString("id"))
                .put("payload",java.util.Base64.getEncoder().encodeToString(record.toString().getBytes(StandardCharsets.UTF_8)));
            if(!kind.equals("live"))ledger.records().getJSONObject("tasks/"+task.getString("id")).put("deleted",true);
            String before=ledger.value.toString(),input=state.toString();boolean rejected=false;
            try{ledger.materialize();}catch(IllegalArgumentException expected){rejected=true;}
            check(rejected,"completion credited another course through "+kind);
            check(before.equals(ledger.value.toString()),"rejected course association changed ledger");
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
            rejected=false;try{CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));}catch(IllegalArgumentException expected){rejected=true;}
            check(rejected,"archive accepted mismatched completion course through "+kind);
            check(input.equals(state.toString())&&before.equals(ledger.value.toString()),"course association validation mutated input");
        }
        for(boolean hasTombstone:new boolean[]{false,true}){
            double now=Planner.now();JSONObject state=fixture(now);String task=state.getJSONArray("tasks").getJSONObject(0).getString("id");
            Planner.confirm(state,task,20,now);SyncLedger ledger=new SyncLedger();ledger.capture(state);
            if(hasTombstone)ledger.records().getJSONObject("tasks/"+task).put("deleted",true);else ledger.records().remove("tasks/"+task);
            JSONObject restored=ledger.materialize();
            check(restored.getJSONArray("tasks").length()==0,"legacy task history was unexpectedly restored");
            check(Planner.completed(restored,restored.getJSONArray("courses").getJSONObject(0))==20,"legacy completion without live task lost progress");
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
            check(CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray())).ledger.materialize().getJSONArray("completions").length()==1,"legacy archive completion was lost");
        }
    }
    static void captureCompletionCourseIntegrity()throws Exception{
        for(boolean archivedTaskCourse:new boolean[]{false,true}){
            double now=Planner.now();JSONObject state=fixture(now),first=state.getJSONArray("courses").getJSONObject(0);
            JSONObject other=CourseTools.copy(first).put("id",Planner.id()).put("name","Other course");state.getJSONArray("courses").put(other);
            Planner.confirm(state,state.getJSONArray("tasks").getJSONObject(0).getString("id"),20,now);
            SyncLedger ledger=new SyncLedger();ledger.capture(state);String before=ledger.value.toString();
            first.put("isArchived",archivedTaskCourse);state.getJSONArray("completions").getJSONObject(0).put("courseID",other.getString("id"));String input=state.toString();
            boolean rejected=false;try{ledger.capture(state);}catch(IllegalArgumentException expected){rejected=true;}
            check(rejected,"capture accepted a completion for another course");
            check(before.equals(ledger.value.toString()),"rejected course association capture changed ledger");
            check(input.equals(state.toString()),"rejected course association capture changed UI state");
        }
    }
    static void nestedMergeCompletionCourseIntegrity()throws Exception{
        for(boolean replaceDraft:new boolean[]{false,true}){
            double now=Planner.at(java.time.LocalDate.of(2026,11,3),420);JSONObject base=fixture(now);
            JSONObject firstSource=base.getJSONArray("courses").getJSONObject(0);firstSource.put("autoScheduleEnabled",true);
            JSONObject second=CourseTools.copy(firstSource).put("id",Planner.id()).put("name","B").put("totalMinutes",60),third=CourseTools.copy(second).put("id",Planner.id()).put("name","C");
            base.getJSONArray("courses").put(second).put(third);JSONObject task=base.getJSONArray("tasks").getJSONObject(0);task.put("start",now+3600);String taskID=task.getString("id");
            SyncLedger mac=new SyncLedger(),phone=new SyncLedger();mac.capture(base,1000);phone.merge(mac.changes(0));JSONObject combined=CourseTools.copy(base);
            JSONObject first=CourseTools.merge(combined,new java.util.HashSet<>(java.util.Arrays.asList(firstSource.getString("id"),second.getString("id"))),"First merge");mac.capture(combined,2000);
            JSONObject merged=CourseTools.merge(combined,new java.util.HashSet<>(java.util.Arrays.asList(first.getString("id"),third.getString("id"))),"Nested merge");
            if(replaceDraft)Planner.replan(combined,now);mac.capture(combined,4000);
            JSONObject offline=phone.materialize();Planner.confirm(offline,taskID,20,now+7200);phone.capture(offline,3000);
            JSONArray localRows=mac.changes(0),remoteRows=phone.changes(0);mac.merge(remoteRows);phone.merge(localRows);JSONObject restored=mac.materialize();
            check(SyncLedger.equivalent(restored,phone.materialize()),"nested course references failed to converge");
            check(Planner.completed(restored,Planner.course(restored,merged.getString("id")))==20,"nested merge lost offline progress");
            check(restored.getJSONArray("completions").getJSONObject(0).getString("courseID").equals(merged.getString("id")),"nested completion was not reparented");
            JSONObject recovered=null;for(JSONObject row:Planner.list(restored.getJSONArray("tasks")))if(row.getString("id").equals(taskID))recovered=row;
            check(recovered!=null&&recovered.getString("courseID").equals(merged.getString("id")),"nested task was not reparented before validation");
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,mac,CloudSnapshot.header(mac));CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
        }
    }
    static void latestEditRegression()throws Exception{
        long time=2000000000000L;JSONObject state=fixture(Planner.now());SyncLedger mac=new SyncLedger(),phone=new SyncLedger();
        mac.capture(state,time);phone.merge(mac.changes(0));
        for(int i=1;i<=20;i++){state.getJSONArray("courses").getJSONObject(0).put("notes","Old "+i);phone.capture(state,time+i*1000);}
        JSONObject newer=mac.materialize();newer.getJSONArray("courses").getJSONObject(0).put("notes","New Mac");mac.capture(newer,time+30000);
        JSONArray left=mac.changes(0),right=phone.changes(0);mac.merge(right);phone.merge(left);
        check(phone.materialize().getJSONArray("courses").getJSONObject(0).getString("notes").equals("New Mac"),"larger offline counter defeated newer edit");
        phone=new SyncLedger(CourseTools.copy(phone.value));newer=phone.materialize();newer.getJSONArray("courses").getJSONObject(0).put("notes","New Phone");phone.capture(newer,time+40000);mac.merge(phone.changes(0));
        check(mac.materialize().getJSONArray("courses").getJSONObject(0).getString("notes").equals("New Phone"),"phone's newer edit lost after reopen");
        long revision=mac.sequence();mac.capture(mac.materialize(),time+50000);check(mac.sequence()==revision,"no-op changed timestamps");
    }
    static void earlyCompletionRegression()throws Exception{
        for(boolean legacy:new boolean[]{false,true}){
        double now=Planner.at(java.time.LocalDate.of(2026,10,19),7*60);JSONObject state=fixture(now);
        state.put("tasks",new JSONArray());state.getJSONArray("courses").getJSONObject(0).put("autoScheduleEnabled",true);
        Planner.replan(state,now);JSONObject first=state.getJSONArray("tasks").getJSONObject(0);if(legacy)first.put("id",Planner.id());String firstID=first.getString("id");
        Planner.confirm(state,firstID,first.getInt("durationMinutes"),now);Planner.replan(state,now);
        String replacement="";for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(task)&&task.getDouble("start")==first.getDouble("start")&&task.getInt("durationMinutes")==first.getInt("durationMinutes"))replacement=task.getString("id");
        check(!replacement.isEmpty()&&!replacement.equals(firstID),"early completion must generate another block in the freed slot");
        SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject merged=ledger.materialize();
        check(merged.getJSONArray("tasks").length()==state.getJSONArray("tasks").length(),"deduplication removed legitimate replacement work");
        check(merged.getJSONArray("completions").length()==1,"early confirmation lost");
        Planner.confirm(state,replacement,60,now+1);Planner.replan(state,now+1);ledger.capture(state);
        check(ledger.materialize().getJSONArray("completions").length()==2,"second early confirmation lost");
        check(ledger.materialize().getJSONArray("tasks").length()==state.getJSONArray("tasks").length(),"second replacement removed");
        }
    }
    static void confirmationRegression()throws Exception{
        for(int minutes:new int[]{0,20,60}){
            double now=Planner.now();long time=2000000000000L;JSONObject state=fixture(now);String id=state.getJSONArray("tasks").getJSONObject(0).getString("id");
            SyncLedger mac=new SyncLedger(),phone=new SyncLedger();mac.capture(state,time);phone.merge(mac.changes(0));
            JSONObject confirmed=mac.materialize();Planner.confirm(confirmed,id,minutes,now);mac.capture(confirmed,time+1000);
            JSONObject stale=phone.materialize();stale.getJSONArray("tasks").getJSONObject(0).put("status","planned");
            stale.getJSONArray("tasks").put(CourseTools.copy(stale.getJSONArray("tasks").getJSONObject(0)).put("id",Planner.id()));phone.capture(stale,time+2000);
            JSONArray left=mac.changes(0),right=phone.changes(0);exchange(phone,left,0);mac.merge(phone.changes(0));mac.merge(right);
            JSONObject merged=mac.materialize();check(merged.getJSONArray("tasks").length()==1,"stale duplicate returned");
            check(merged.getJSONArray("tasks").getJSONObject(0).has("confirmedAt"),"stale draft cleared confirmation");
            check(merged.getJSONArray("completions").getJSONObject(0).getInt("minutes")==minutes,"partial/zero credit lost");
            check(Planner.review(merged,now).isEmpty(),"confirmed task asks for confirmation again");
            long revision=phone.sequence();exchange(phone,left,0);check(phone.sequence()==revision,"repeat created confirmation edits");
            JSONObject undone=phone.materialize();Planner.undoConfirmation(undone,id,now);phone.capture(undone,time+4000);mac.merge(phone.changes(0));
            check(!mac.materialize().getJSONArray("tasks").getJSONObject(0).has("confirmedAt"),"newer explicit undo lost");
            JSONObject taskRow=SyncLedger.shallowCopy(mac.records().getJSONObject("tasks/"+id));
            taskRow.put("payload",java.util.Base64.getEncoder().encodeToString(confirmed.getJSONArray("tasks").getJSONObject(0).toString().getBytes(StandardCharsets.UTF_8))).put("modifiedAt",time+5000).put("version",taskRow.getLong("version")+1);
            mac.merge(new JSONArray().put(taskRow));check(!mac.materialize().getJSONArray("tasks").getJSONObject(0).has("confirmedAt"),"stale task restored undone confirmation");
            JSONObject redone=mac.materialize();Planner.confirm(redone,id,minutes,now);mac.capture(redone,time+6000);phone.merge(mac.changes(0));
            check(phone.materialize().getJSONArray("tasks").getJSONObject(0).has("confirmedAt"),"newer reconfirmation lost");
        }
        double now=Planner.now();JSONObject state=fixture(now);String id=state.getJSONArray("tasks").getJSONObject(0).getString("id");SyncLedger mac=new SyncLedger(),phone=new SyncLedger();mac.capture(state);phone.merge(mac.changes(0));
        JSONObject confirmed=mac.materialize();Planner.confirm(confirmed,id,60,now);mac.capture(confirmed);state.put("tasks",new JSONArray());phone.capture(state);
        exchange(phone,mac.changes(0),0);check(phone.materialize().getJSONArray("tasks").getJSONObject(0).has("confirmedAt"),"deleted draft lost offline confirmation");
    }
    public static void main(String[] args)throws Exception{
        referencedTombstoneIntegrity();duplicateCompletionIntegrity();captureCompletionCourseIntegrity();completionCourseIntegrity();nestedMergeCompletionCourseIntegrity();latestEditRegression();confirmationRegression();earlyCompletionRegression();
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
