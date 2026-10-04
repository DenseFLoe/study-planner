package local.studyplanner;
import org.json.*;import java.nio.file.*;import java.util.*;
public final class SyncTests {
    static int checks;static void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    static JSONObject clone(JSONObject s)throws Exception{return new JSONObject(s.toString());}
    static void courseDeletionRegression()throws Exception{
        JSONObject state=new SyncLedger(new JSONObject(new String(Files.readAllBytes(Paths.get("/tmp/study-sync-swift-fixture.json")),"UTF-8"))).materialize();java.time.LocalDate day=java.time.LocalDate.of(2026,10,3);
        JSONObject removed=state.getJSONArray("courses").getJSONObject(0).put("name","删除课程").put("totalMinutes",180);
        JSONObject kept=clone(removed).put("id",Planner.id()).put("name","保留课程");state.getJSONArray("courses").put(kept);
        for(JSONObject c:new JSONObject[]{removed,kept})for(int i=0;i<3;i++){
            JSONObject t=Planner.task(c.getString("id"),Planner.at(day,480+i*120),60);state.getJSONArray("tasks").put(t);
            if(i<2)Planner.confirm(state,t.getString("id"),i==0?60:20,Planner.end(t));
        }
        String id=removed.getString("id");
        SyncLedger mac=new SyncLedger(),phone=new SyncLedger();mac.capture(state);phone.merge(mac.changes(0));
        JSONObject concurrent=phone.materialize();for(JSONObject t:Planner.list(concurrent.getJSONArray("tasks")))if(t.getString("courseID").equals(id)&&Planner.pending(t))Planner.confirm(concurrent,t.getString("id"),60,Planner.end(t));phone.capture(concurrent);
        JSONObject deleted=clone(state);Planner.removeCourse(deleted,id);
        check(deleted.getJSONArray("courses").length()==1&&deleted.getJSONArray("tasks").length()==3&&deleted.getJSONArray("completions").length()==2,"Delete must preserve only other course history");
        mac.capture(deleted);JSONArray m=mac.changes(0),p=phone.changes(0);mac.merge(p);phone.merge(m);
        check(SyncLedger.canonical(mac.materialize()).equals(SyncLedger.canonical(phone.materialize())),"Deletion and concurrent confirmation must converge");
        check(mac.materialize().getJSONArray("completions").length()==2,"Concurrent completion must not restore removed course history");
        mac.capture(mac.materialize());phone.merge(mac.changes(0));check(phone.materialize().getJSONArray("tasks").length()==3,"Deleted tasks must stay removed");
        SyncLedger legacy=new SyncLedger();legacy.capture(state);
        JSONObject archived=clone(legacy.records().getJSONObject("courses/"+id));JSONObject payload=SyncLedger.payload(archived);payload.put("isArchived",true);
        archived.put("payload",Base64.getEncoder().encodeToString(payload.toString().getBytes("UTF-8"))).put("version",archived.getLong("version")+1);
        legacy.merge(new JSONArray().put(archived));JSONObject cleaned=legacy.materialize();
        check(cleaned.getJSONArray("courses").length()==1&&cleaned.getJSONArray("tasks").length()==3&&cleaned.getJSONArray("completions").length()==2,"Legacy archive must remove history");
        legacy.capture(cleaned);check(legacy.records().getJSONObject("courses/"+id).getBoolean("deleted"),"Legacy cleanup must sync deletion");
    }
    public static void main(String[] args)throws Exception{
        courseDeletionRegression();
        JSONObject source=new JSONObject(new String(Files.readAllBytes(Paths.get("/tmp/study-sync-swift-fixture.json")),"UTF-8"));
        SyncLedger mac=new SyncLedger(source),phone=new SyncLedger();phone.value.put("device","PHONE-FIXTURE");phone.merge(mac.changes(0));
        JSONObject a=phone.materialize();check(a.getJSONArray("courses").length()==1,"Swift base64 decoding");a.getJSONArray("courses").getJSONObject(0).put("notes","Java round trip 中文");phone.capture(a);
        long seq=phone.sequence();phone.capture(a);check(phone.sequence()==seq,"No-op capture");mac.merge(phone.changes(0));check(mac.materialize().getJSONArray("courses").getJSONObject(0).getString("notes").equals("Java round trip 中文"),"Bidirectional change");
        seq=mac.sequence();mac.merge(phone.changes(0));check(mac.sequence()==seq,"Duplicate delivery");
        Files.write(Paths.get("/tmp/study-sync-java-fixture.json"),phone.value.toString().getBytes("UTF-8"));
        JSONObject b=clone(a);a.getJSONArray("courses").getJSONObject(0).put("name","Mac conflict");b.getJSONArray("courses").getJSONObject(0).put("name","Phone conflict");mac.capture(a);phone.capture(b);JSONArray m=mac.changes(0),p=phone.changes(0);mac.merge(p);phone.merge(m);check(SyncLedger.canonical(mac.materialize()).equals(SyncLedger.canonical(phone.materialize())),"Conflict convergence");
        JSONObject deleted=phone.materialize();deleted.put("courses",new JSONArray());phone.capture(deleted);mac.merge(phone.changes(0));check(mac.materialize().getJSONArray("courses").length()==0,"Soft deletion");check(mac.value.getJSONObject("records").getJSONObject("courses/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA").getBoolean("deleted"),"Tombstone retained");
        SyncLedger offlineA=new SyncLedger(),offlineB=new SyncLedger();JSONObject sa=clone(a),sb=clone(a);sa.getJSONArray("courses").put(clone(sa.getJSONArray("courses").getJSONObject(0)).put("id",Planner.id()).put("name","Offline A"));sb.getJSONArray("courses").put(clone(sb.getJSONArray("courses").getJSONObject(0)).put("id",Planner.id()).put("name","Offline B"));offlineA.capture(sa);offlineB.capture(sb);offlineA.merge(offlineB.changes(0));offlineB.merge(offlineA.changes(0));check(offlineA.materialize().getJSONArray("courses").length()==3,"Offline union");check(SyncLedger.canonical(offlineA.materialize()).equals(SyncLedger.canonical(offlineB.materialize())),"Offline convergence");
        long before=offlineA.sequence();offlineA.capture(offlineA.materialize());check(before==offlineA.sequence(),"Canonical capture stable");
        boolean refused=false;try{mac.changes(mac.sequence()+1);}catch(Exception e){refused=true;}check(refused,"Invalid cursor refused");
        SyncLedger floating=new SyncLedger(new JSONObject(new String(Files.readAllBytes(Paths.get("/tmp/study-floating-swift-fixture.json")),"UTF-8")));
        JSONObject fs=floating.materialize();
        check(fs.getJSONArray("fixedEvents").getJSONObject(0).getInt("floatingDurationMinutes")==60,"Floating duration lost from Swift");
        check(fs.getJSONArray("tasks").getJSONObject(0).has("floatingWindowEnd"),"Floating window lost from Swift");
        floating.capture(fs);
        Files.write(Paths.get("/tmp/study-floating-java-fixture.json"),floating.value.toString().getBytes("UTF-8"));
        System.out.println("PASS "+checks+" sync checks including Swift/Java interoperability");
    }
}
