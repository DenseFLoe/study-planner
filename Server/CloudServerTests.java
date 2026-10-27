package local.studyplanner;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

public final class CloudServerTests {
    static int checks;
    static void check(boolean condition,String message){checks++;if(!condition)throw new AssertionError(message);}
    static byte[] packed(SyncLedger ledger)throws Exception{ByteArrayOutputStream out=new ByteArrayOutputStream();CloudSnapshot.write(out,ledger,CloudSnapshot.header(ledger));return out.toByteArray();}
    static CloudSnapshot snapshot(SyncLedger ledger)throws Exception{return CloudSnapshot.read(new ByteArrayInputStream(packed(ledger)));}
    static SyncLedger initial()throws Exception{SyncLedger ledger=new SyncLedger();ledger.capture(SyncExchangeTests.fixture(Planner.now()),System.currentTimeMillis()-60000);return ledger;}
    static SyncLedger copy(SyncLedger ledger)throws Exception{SyncLedger result=snapshot(ledger).ledger;result.value.put("device",Planner.id());return result;}
    static byte[] request(CloudSyncServer server,String token,String path,byte[] body,int status)throws Exception{
        return request(server,token,path,body,status,0);
    }
    static byte[] request(CloudSyncServer server,String token,String path,byte[] body,int status,int attempt)throws Exception{
        HttpURLConnection c=(HttpURLConnection)new URL("http://127.0.0.1:"+server.port()+path).openConnection();c.setConnectTimeout(5000);c.setReadTimeout(10000);
        c.setRequestProperty("Authorization","Bearer "+token);
        try{if(body!=null){c.setRequestMethod("POST");c.setDoOutput(true);try(OutputStream out=c.getOutputStream()){out.write(body);}}
            if(c.getResponseCode()==503&&status==200&&attempt<30){c.disconnect();Thread.sleep(100);return request(server,token,path,body,status,attempt+1);}
            check(c.getResponseCode()==status,"unexpected HTTP status "+c.getResponseCode()+" for "+path);
            try(InputStream in=status==200?c.getInputStream():c.getErrorStream()){return in.readAllBytes();}
        }finally{c.disconnect();}
    }
    static void diskRegression(CloudSyncServer server,String token,Path parent)throws Exception{
        Path upload=Files.createTempFile(parent,"fixture-",".gz");
        try{
            // Relevant tombstones must preserve offline confirmation recovery and explicit undo.
            for(boolean undo:new boolean[]{false,true}){
                SyncLedger ledger=initial();JSONObject state=ledger.materialize();String id=state.getJSONArray("tasks").getJSONObject(0).getString("id");
                String draftPayload=ledger.records().getJSONObject("tasks/"+id).getString("payload");
                Planner.confirm(state,id,30,Planner.now());ledger.capture(state);
                if(undo){Planner.undoConfirmation(state,id,Planner.now());ledger.capture(state);}
                else ledger.records().getJSONObject("tasks/"+id).put("deleted",true).put("payload",draftPayload);
                // Historical rows are present on disk but must not inflate the working set.
                JSONObject prototype=ledger.records().getJSONObject("tasks/"+id);
                for(int i=0;i<700;i++){
                    JSONObject row=SyncLedger.shallowCopy(prototype).put("id",Planner.stableID("unused-deleted-"+i)).put("deleted",true);
                    ledger.records().put(SyncLedger.key(row),row);
                }
                Files.write(upload,packed(ledger));
                try(DiskSnapshot disk=new DiskSnapshot(parent)){
                    disk.read(upload);SyncLedger compact=disk.workingSet(ledger.value.getString("device")).ledger;
                    if(!undo)check(compact.materialize().getJSONArray("tasks").getJSONObject(0).has("confirmedAt"),"deleted draft lost offline confirmation");
                    check(compact.records().length()<20,"working set retained unrelated tombstones");
                    check(SyncLedger.equivalent(ledger.materialize(),compact.materialize()),"disk materialization differs for confirmation/undo");
                    disk.normalize(ledger.value.getString("device"),null);
                    disk.write(upload,CloudSnapshot.header(ledger));
                }
                CloudSnapshot roundtrip;try(InputStream in=Files.newInputStream(upload)){roundtrip=CloudSnapshot.read(in);}
                check(roundtrip.ledger.records().length()>=700,"normalization discarded historical tombstones");
                check(SyncLedger.equivalent(ledger.materialize(),roundtrip.ledger.materialize()),"disk normalization changed business state");
            }
            // Duplicate keys in different sort runs must fail before any version is committed.
            SyncLedger ledger=initial();JSONArray rows=ledger.changes(0);JSONObject first=rows.getJSONObject(0);
            for(int i=0;i<600;i++)rows.put(new JSONObject().put("kind","tasks").put("id",Planner.stableID("duplicate-test-"+i))
                .put("payload","e30=").put("deleted",true).put("version",1).put("device","TEST").put("sequence",i+10));
            rows.put(first);
            try(Writer out=new OutputStreamWriter(new java.util.zip.GZIPOutputStream(Files.newOutputStream(upload)),java.nio.charset.StandardCharsets.UTF_8)){
                SyncJSON.write(out,CloudSnapshot.header(ledger).put("records",rows));
            }
            try(DiskSnapshot disk=new DiskSnapshot(parent)){
                try{disk.read(upload);throw new AssertionError("cross-run duplicate accepted");}catch(IOException expected){check(true,"duplicate rejected");}
            }
            // Explicitly bounded active state fails predictably instead of exhausting the heap.
            rows=ledger.changes(0);
            for(int i=0;i<DiskSnapshot.ACTIVE_ROWS;i++)rows.put(new JSONObject().put("kind","tasks").put("id",Planner.stableID("active-limit-"+i))
                .put("payload","e30=").put("deleted",false).put("version",1).put("device","TEST").put("sequence",i+10));
            try(Writer out=new OutputStreamWriter(new java.util.zip.GZIPOutputStream(Files.newOutputStream(upload)),java.nio.charset.StandardCharsets.UTF_8)){
                SyncJSON.write(out,CloudSnapshot.header(ledger).put("records",rows));
            }
            try(DiskSnapshot disk=new DiskSnapshot(parent)){
                disk.read(upload);try{disk.workingSet("TEST");throw new AssertionError("unbounded active state accepted");}
                catch(DiskSnapshot.CapacityException expected){check(true,"capacity rejected");}
            }
            long revision=server.revision;request(server,token,"/cloud/snapshot",Files.readAllBytes(upload),413);
            check(server.revision==revision,"oversized working set changed revision");
            request(server,token,"/cloud/status",null,200);
        }finally{Files.deleteIfExists(upload);}
    }
    public static void main(String[] args)throws Exception{
        Path directory=Files.createTempDirectory("planner-cloud-server-");String token=UUID.randomUUID().toString()+UUID.randomUUID();
        CloudSyncServer server=new CloudSyncServer(directory,"127.0.0.1",0,token);server.start();
        try{
            request(server,"invalid-placeholder","/cloud/status",null,401);
            server.uploadLock.lock();
            try{request(server,token,"/cloud/snapshot",packed(initial()),503);}finally{server.uploadLock.unlock();}
            diskRegression(server,token,directory);
            SyncLedger base=initial(),mac=copy(base),phone=copy(base);server.accept(snapshot(base));long first=server.revision;
            server.accept(snapshot(base));check(server.revision==first,"retry created a version");
            JSONObject left=mac.materialize(),right=phone.materialize();
            JSONObject added=CourseTools.copy(left.getJSONArray("courses").getJSONObject(0)).put("id",Planner.id()).put("name","Mac offline addition");left.getJSONArray("courses").put(added);mac.capture(left);
            JSONObject task=right.getJSONArray("tasks").getJSONObject(0);Planner.confirm(right,task.getString("id"),30,Planner.now());phone.capture(right);
            ExecutorService clients=Executors.newFixedThreadPool(2);final CloudSyncServer running=server;
            Future<?> a=clients.submit(()->{try{request(running,token,"/cloud/snapshot",packed(mac),200);}catch(Exception e){throw new RuntimeException(e);}});
            Future<?> b=clients.submit(()->{try{request(running,token,"/cloud/snapshot",packed(phone),200);}catch(Exception e){throw new RuntimeException(e);}});
            a.get();b.get();clients.shutdown();
            JSONObject merged=server.loadLedger().materialize();check(merged.getJSONArray("courses").length()==2,"offline addition lost");check(merged.getJSONArray("completions").length()==1,"offline confirmation lost");
            long before=server.revision;request(server,token,"/cloud/snapshot",Arrays.copyOf(packed(mac),12),400);check(server.revision==before,"truncated upload committed");
            JSONObject corruptHeader=CloudSnapshot.header(base);ByteArrayOutputStream duplicate=new ByteArrayOutputStream();
            SyncLedger invalid=copy(base);invalid.records().remove("settings/settings");CloudSnapshot.write(duplicate,invalid,corruptHeader);
            request(server,token,"/cloud/snapshot",duplicate.toByteArray(),400);check(server.revision==before,"invalid full snapshot committed");
            SyncLedger newest=copy(server.loadLedger());JSONObject state=newest.materialize();Planner.removeCourse(state,added.getString("id"));newest.capture(state);server.accept(snapshot(newest));
            server.accept(snapshot(mac));check(server.loadLedger().materialize().getJSONArray("courses").length()==1,"stale full snapshot revived deleted course");
            newest=copy(server.loadLedger());state=newest.materialize();state.getJSONArray("courses").getJSONObject(0).put("notes","disk-failure-check");newest.capture(state);
            long stable=server.revision;Path obstruction=directory.resolve(CloudSyncServer.name(stable+1));Files.createDirectory(obstruction);
            try{server.accept(snapshot(newest));throw new AssertionError("disk failure accepted");}catch(IOException expected){}
            check(server.revision==stable,"failed persistence changed live revision");Files.delete(obstruction);
            for(int i=0;i<15;i++){newest=copy(server.loadLedger());state=newest.materialize();state.getJSONArray("courses").getJSONObject(0).put("notes","revision "+i);newest.capture(state,System.currentTimeMillis()+i+1);server.accept(snapshot(newest));}
            check(server.archives().size()==10,"history must contain latest plus nine old versions");
            JSONObject history=new JSONObject(new String(request(server,token,"/cloud/history",null,200),java.nio.charset.StandardCharsets.UTF_8));check(history.getJSONArray("versions").length()==10,"history listing differs");
            CloudSnapshot wire=CloudSnapshot.read(new ByteArrayInputStream(request(server,token,"/cloud/latest",null,200)));check(wire.header.getLong("revision")==server.revision,"download revision differs");
            request(server,token,"/cloud/history/"+history.getJSONArray("versions").getJSONObject(0).getLong("revision"),null,200);
            long last=server.revision;String identity=server.serverID;server.close();server=new CloudSyncServer(directory,"127.0.0.1",0,token);server.start();
            check(server.revision==last&&server.serverID.equals(identity),"restart lost identity or revision");check(server.archives().size()==10,"restart changed history");
            check(server.loadLedger().materialize().getJSONArray("completions").length()==1,"restart lost confirmation");
            String fixture=System.getenv("STUDY_CLOUD_FIXTURE_DIR");if(fixture!=null){Path output=Path.of(fixture);Files.createDirectories(output);Files.copy(server.latest,output.resolve("java-latest.json.gz"),StandardCopyOption.REPLACE_EXISTING);}
            System.out.println("PASS "+checks+" cloud server checks: offline merge, concurrent uploads, retries, tombstones, malformed input, disk failure, ten-version retention, restart, HTTP authentication");
        }finally{server.close();try(java.util.stream.Stream<Path> files=Files.walk(directory)){files.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.delete(p);}catch(IOException ignored){}});}}
    }
}
