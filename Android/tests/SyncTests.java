package local.studyplanner;
import org.json.*;import java.nio.file.*;import java.util.*;
public final class SyncTests {
    static int checks;static void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    static JSONObject clone(JSONObject s)throws Exception{return new JSONObject(s.toString());}
    public static void main(String[] args)throws Exception{
        JSONObject source=new JSONObject(new String(Files.readAllBytes(Paths.get("/tmp/study-sync-swift-fixture.json")),"UTF-8"));
        SyncLedger mac=new SyncLedger(source),phone=new SyncLedger();phone.value.put("device","PHONE-FIXTURE");phone.merge(mac.changes(0));
        JSONObject a=phone.materialize();check(a.getJSONArray("courses").length()==1,"Swift base64 decoding");a.getJSONArray("courses").getJSONObject(0).put("notes","Java round trip 中文");phone.capture(a);
        long seq=phone.sequence();phone.capture(a);check(phone.sequence()==seq,"No-op capture");mac.merge(phone.changes(0));check(mac.materialize().getJSONArray("courses").getJSONObject(0).getString("notes").equals("Java round trip 中文"),"Bidirectional change");
        seq=mac.sequence();mac.merge(phone.changes(0));check(mac.sequence()==seq,"Duplicate delivery");
        Files.write(Paths.get("/tmp/study-sync-java-fixture.json"),phone.value.toString().getBytes("UTF-8"));
        JSONObject b=clone(a);a.getJSONArray("courses").getJSONObject(0).put("name","Mac conflict");b.getJSONArray("courses").getJSONObject(0).put("name","Phone conflict");mac.capture(a);phone.capture(b);JSONArray m=mac.changes(0),p=phone.changes(0);mac.merge(p);phone.merge(m);check(SyncLedger.canonical(mac.materialize()).equals(SyncLedger.canonical(phone.materialize())),"Conflict convergence");
        JSONObject deleted=phone.materialize();deleted.put("courses",new JSONArray());phone.capture(deleted);mac.merge(phone.changes(0));check(mac.materialize().getJSONArray("courses").length()==0,"Soft deletion");check(mac.value.getJSONObject("records").getJSONObject("courses/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA").getBoolean("deleted"),"Tombstone retained");
        SyncLedger offlineA=new SyncLedger(),offlineB=new SyncLedger();JSONObject sa=new JSONObject(new String(Files.readAllBytes(Paths.get("Android/assets/initial-state.json")),"UTF-8"));JSONObject sb=clone(sa);sa.getJSONArray("courses").put(clone(sa.getJSONArray("courses").getJSONObject(0)).put("id",Planner.id()).put("name","Offline A"));sb.getJSONArray("courses").put(clone(sb.getJSONArray("courses").getJSONObject(0)).put("id",Planner.id()).put("name","Offline B"));offlineA.capture(sa);offlineB.capture(sb);offlineA.merge(offlineB.changes(0));offlineB.merge(offlineA.changes(0));check(offlineA.materialize().getJSONArray("courses").length()==6,"Offline union");check(SyncLedger.canonical(offlineA.materialize()).equals(SyncLedger.canonical(offlineB.materialize())),"Offline convergence");
        long before=offlineA.sequence();offlineA.capture(offlineA.materialize());check(before==offlineA.sequence(),"Canonical capture stable");
        boolean refused=false;try{mac.changes(mac.sequence()+1);}catch(Exception e){refused=true;}check(refused,"Invalid cursor refused");
        System.out.println("PASS "+checks+" sync checks including Swift/Java interoperability");
    }
}
