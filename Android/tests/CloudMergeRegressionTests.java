package local.studyplanner;
import org.json.*;
import java.util.*;

public final class CloudMergeRegressionTests {
    static int checks;
    static void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    static SyncLedger copy(SyncLedger ledger)throws Exception{return new SyncLedger(CourseTools.copy(ledger.value));}
    static void fields()throws Exception{
        double now=Planner.now();long time=System.currentTimeMillis();JSONObject base=SyncExchangeTests.fixture(now);base.put("tasks",new JSONArray());
        SyncLedger common=new SyncLedger();common.capture(base,time-100000);SyncLedger a=copy(common),b=copy(common);
        a.value.put("device","mac");b.value.put("device","phone");JSONObject local=a.materialize(),phone=b.materialize();
        local.getJSONArray("courses").getJSONObject(0).put("totalMinutes",60).put("deletedLessonIDs",new JSONArray().put("removed-lesson"));a.capture(local,time-50000);
        phone.getJSONArray("courses").getJSONObject(0).put("deadline",now+10*86400);b.capture(phone,time-1000);
        SyncLedger left=copy(a),right=copy(b);left.merge(b.changes(0));right.merge(a.changes(0));
        JSONObject result=left.materialize().getJSONArray("courses").getJSONObject(0);
        check(result.getInt("totalMinutes")==60,"stale phone restored deleted lesson duration");
        check(result.getJSONArray("deletedLessonIDs").length()==1,"stale phone removed deletion markers");
        check(result.getDouble("deadline")==now+10*86400,"actual phone deadline edit was lost");
        check(SyncLedger.equivalent(left.materialize(),right.materialize()),"opposite merge orders diverged");
        long sequence=left.sequence();left.merge(right.changes(0));left.capture(left.materialize());check(left.sequence()==sequence,"converged fields keep uploading");
        for(JSONObject row:Planner.list(common.changes(0)))common.records().getJSONObject(SyncLedger.key(row)).remove("fieldVersions");
        a=copy(common);b=copy(common);local=a.materialize();local.getJSONArray("courses").getJSONObject(0).put("totalMinutes",60);a.capture(local,time-1000);
        phone=b.materialize();phone.getJSONArray("courses").getJSONObject(0).put("notes","Phone note");b.capture(phone,time);
        a.merge(b.changes(0));result=a.materialize().getJSONArray("courses").getJSONObject(0);check(result.getInt("totalMinutes")==60&&result.getString("notes").equals("Phone note"),"legacy first edit lost field baseline");
    }
    static void stalePlan()throws Exception{
        double now=Planner.now();long time=System.currentTimeMillis();JSONObject base=SyncExchangeTests.fixture(now);base.put("tasks",new JSONArray());
        String course=base.getJSONArray("courses").getJSONObject(0).getString("id");
        SyncLedger common=new SyncLedger();common.capture(base,time-4*86400000L);SyncLedger a=copy(common),b=copy(common);
        JSONObject local=a.materialize(),phone=b.materialize(),old=Planner.task(course,now-3*86400,60),studied=Planner.task(course,now-2*86400,60);
        phone.getJSONArray("tasks").put(old);b.capture(phone,time-3*86400000L);
        // The newer Mac plan explicitly removes its prior draft. Its tombstone
        // must also retire unknown old phone drafts for this same course.
        local.getJSONArray("tasks").put(Planner.task(course,now-86400,60));a.capture(local,time-86400000L);
        local.put("tasks",new JSONArray());a.capture(local,time-3600000);
        phone.getJSONArray("tasks").put(studied);Planner.confirm(phone,studied.getString("id"),60,now-60);b.capture(phone,time-60000);
        a.mergeCloudSnapshot(b,now);JSONObject result=a.materialize();
        check(Planner.review(result,now).isEmpty(),"old phone task reappeared for confirmation");
        check(result.getJSONArray("completions").length()==1,"offline completion was lost");
        check(a.records().getJSONObject("tasks/"+old.getString("id")).getBoolean("deleted"),"obsolete task lacks tombstone");
        b.merge(a.changes(0));check(Planner.review(b.materialize(),now).isEmpty(),"subsequent sync resurrected obsolete task");
    }
    static void legacyReplacementAndOutbox()throws Exception{
        SyncLedger local=CloudSyncEngineTests.fixture(),remote=copy(local);
        // Legacy rows older than a known dated edit must not disable replacement.
        local.records().getJSONObject("settings/settings").remove("modifiedAt");remote.records().getJSONObject("settings/settings").remove("modifiedAt");
        CloudSyncEngineTests.rename(remote,"Cloud latest",2000);
        check(CloudReplacement.serverNewer(local,remote),"old legacy records disabled safe replacement");
        try(CloudSyncEngineTests.Fixture f=new CloudSyncEngineTests.Fixture(local,remote)){
            CloudOutbox.prepare(f.outbox,local);f.sync();check(f.remote.uploads==0,"replacement uploaded stale prepared snapshot");
            check(CloudOutbox.queued(f.outbox).length==0,"prepared snapshot survived replacement discard boundary");
        }
        // An unrecognized newer legacy edit remains ambiguous.
        local.records().getJSONObject("settings/settings").put("version",10000);
        check(!CloudReplacement.serverNewer(local,remote),"ambiguous legacy edit was overwritten");
        local=CloudSyncEngineTests.fixture();remote=copy(local);SyncLedger obsolete=copy(local);
        CloudSyncEngineTests.addLocalCourse(obsolete,1500);CloudSyncEngineTests.rename(local,"Phone latest",3000);
        try(CloudSyncEngineTests.Fixture f=new CloudSyncEngineTests.Fixture(local,remote)){
            CloudOutbox.enqueue(f.outbox,obsolete);f.sync();
            check(f.remote.uploads==1,"historical outbox files were replayed");
            check(f.remote.ledger.materialize().getJSONArray("courses").length()==1,"obsolete queued course reappeared on server");
        }
    }
    static void confirmationOnly()throws Exception{
        long time=1793880000000L;double now=time/1000.0-Planner.EPOCH;JSONObject base=SyncExchangeTests.fixture(now);
        base.getJSONArray("courses").getJSONObject(0).put("autoScheduleEnabled",true).put("deadline",now+30*86400);
        JSONArray availability=new JSONArray();for(int weekday=1;weekday<=7;weekday++)availability.put(new JSONObject().put("id",Planner.id()).put("weekday",weekday).put("startMinute",0).put("endMinute",1440));
        base.getJSONObject("settings").put("availability",availability);
        String course=base.getJSONArray("courses").getJSONObject(0).getString("id");
        JSONObject studied=Planner.task(course,now-3600,60),future=Planner.task(course,now+86400,60);
        base.put("tasks",new JSONArray().put(studied).put(future));
        SyncLedger common=new SyncLedger();common.capture(base,time-7200000);
        SyncLedger confirmed=copy(common);JSONObject edited=confirmed.materialize();Planner.confirm(edited,studied.getString("id"),60,now);confirmed.capture(edited,time);
        for(SyncLedger[] pair:Arrays.asList(new SyncLedger[]{copy(confirmed),common},new SyncLedger[]{copy(common),confirmed})){
            SyncLedger local=pair[0];local.mergeCloudSnapshot(pair[1],now);JSONObject result=local.materialize();
            check(result.getJSONArray("completions").length()==1,"confirmation-only sync rejected or lost completion");
            check(result.getJSONArray("tasks").length()==2,"confirmation-only sync changed the plan");
            long sequence=local.sequence();local.mergeCloudSnapshot(pair[1],now);check(local.sequence()==sequence,"repeated confirmation sync did not converge");
        }
        SyncLedger undone=copy(confirmed);JSONObject undo=undone.materialize();Planner.undoConfirmation(undo,studied.getString("id"),now+60);undone.capture(undo,time+60000);
        for(SyncLedger[] pair:Arrays.asList(new SyncLedger[]{copy(undone),confirmed},new SyncLedger[]{copy(confirmed),undone})){
            pair[0].mergeCloudSnapshot(pair[1],now+60);JSONObject result=pair[0].materialize();
            check(result.getJSONArray("completions").length()==0,"undo confirmation was lost");
            check(SyncLedger.pendingPlans(result).get(course).contains(studied.getString("id")),"undone task no longer pending");
        }
        SyncLedger a=new SyncLedger();a.value.put("device","same-plan-source");a.capture(base,time);
        JSONObject other=CourseTools.copy(base);other.getJSONArray("tasks").getJSONObject(0).put("id",Planner.id());
        SyncLedger b=new SyncLedger();b.value.put("device","same-plan-source");b.capture(other,time);
        String before=SyncLedger.canonical(a.value);boolean rejected=false;
        try{a.mergeCloudSnapshot(b,now);}catch(IllegalStateException expected){rejected=true;}
        check(rejected,"different plans with identical revision were accepted");check(before.equals(SyncLedger.canonical(a.value)),"rejected plan merge mutated local data");
    }
    public static void main(String[] args)throws Exception{fields();stalePlan();legacyReplacementAndOutbox();confirmationOnly();System.out.println("Cloud incident regressions: "+checks+" checks passed");}
}
