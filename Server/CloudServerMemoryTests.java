package local.studyplanner;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPOutputStream;

/** Synthetic large ledgers only. The HTTP server runs in a separate 128 MiB heap. */
public final class CloudServerMemoryTests {
    static final int OLD_TASKS=40000,NEW_TASKS=44000;
    static final String TOKEN="MEMORY_TEST_ACCESS_CODE_PLACEHOLDER_32_CHARACTERS";
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    static void fixture(Path file,JSONArray base,String courseID,String identity,int count,boolean old)throws Exception{
        JSONObject header=new JSONObject().put("format",1).put("archiveID",Planner.id()).put("device","MEMORY-FIXTURE").put("createdAt",0);
        if(old)header.put("serverID",identity).put("revision",1);
        try(Writer out=new BufferedWriter(new OutputStreamWriter(new GZIPOutputStream(Files.newOutputStream(file)),StandardCharsets.UTF_8))){
            out.write('{');boolean first=true;Iterator<String> fields=header.keys();
            while(fields.hasNext()){String key=fields.next();if(!first)out.write(',');first=false;out.write(JSONObject.quote(key));out.write(':');SyncJSON.write(out,header.get(key));}
            out.write(",\"records\":[");for(int i=0;i<base.length();i++){if(i>0)out.write(',');SyncJSON.write(out,base.getJSONObject(i));}
            for(int i=0;i<count;i++){
                String id=Planner.stableID("cloud-memory-task-"+i);
                JSONObject task=new JSONObject().put("id",id).put("courseID",courseID).put("start",0).put("durationMinutes",30)
                    .put("completedMinutes",0).put("status","planned").put("lessonName","Synthetic deleted lesson "+Planner.stableID("lesson-"+i));
                JSONObject row=new JSONObject().put("kind","tasks").put("id",id).put("deleted",true)
                    .put("payload",Base64.getEncoder().encodeToString(task.toString().getBytes(StandardCharsets.UTF_8)))
                    .put("device","MEMORY-FIXTURE").put("version",old?1:2).put("modifiedAt",old?1:2).put("sequence",i+base.length()+1);
                out.write(',');SyncJSON.write(out,row);
            }out.write("]}");
        }
    }
    static JSONObject request(CloudSyncServer server,Path upload,int expected)throws Exception{
        HttpURLConnection connection=(HttpURLConnection)new URL("http://127.0.0.1:"+server.port()+"/cloud/snapshot").openConnection();
        connection.setConnectTimeout(5000);connection.setReadTimeout(90000);connection.setRequestProperty("Authorization","Bearer "+TOKEN);
        connection.setRequestMethod("POST");connection.setDoOutput(true);connection.setFixedLengthStreamingMode(Files.size(upload));
        try{
            try(OutputStream out=connection.getOutputStream();InputStream in=Files.newInputStream(upload)){in.transferTo(out);}
            int code=connection.getResponseCode();check(code==expected,"upload HTTP status "+code+", expected "+expected);
            try(InputStream in=code==200?connection.getInputStream():connection.getErrorStream()){return new JSONObject(new String(in.readAllBytes(),StandardCharsets.UTF_8));}
        }finally{connection.disconnect();}
    }
    static void verifyLatest(Path directory,long revision)throws Exception{
        try(InputStream in=Files.newInputStream(directory.resolve(CloudSyncServer.name(revision)))){
            CloudSnapshot saved=CloudSnapshot.read(in);
            check(saved.ledger.records().length()>=NEW_TASKS,"large tombstone ledger lost records");
            check(saved.header.getLong("revision")==revision,"saved revision mismatch");
        }
    }
    static void worker(Path root)throws Exception{
        Path data=root.resolve("data"),incoming=root.resolve("incoming.json.gz");
        CloudSyncServer server=new CloudSyncServer(data,"127.0.0.1",0,TOKEN);server.start();
        try{
            JSONObject first=request(server,incoming,200);long revision=first.getLong("revision");check(revision==2,"first upload must create one version");
            System.out.println("PASS large upload at max heap "+Runtime.getRuntime().maxMemory());
            check(request(server,incoming,200).getLong("revision")==revision,"retry created duplicate revision");
            Path invalid=root.resolve("truncated.json.gz");Files.write(invalid,new byte[]{31,-117,8,0});request(server,invalid,400);
            check(server.revision==revision&&server.archives().size()==2,"failed upload changed durable versions");
            verifyLatest(data,revision);
            String identity=server.serverID;server.close();server=new CloudSyncServer(data,"127.0.0.1",0,TOKEN);server.start();
            check(server.revision==revision&&server.serverID.equals(identity),"restart lost latest snapshot");
            try(java.util.stream.Stream<Path> paths=Files.list(data)){check(paths.noneMatch(p->p.getFileName().toString().startsWith(".upload-")),"staged upload not cleaned");}
            System.out.println("PASS 128 MiB cloud heap: 40k old + 44k incoming tombstones, retry, malformed upload, persistence and restart");
        }finally{server.close();}
    }
    public static void main(String[] args)throws Exception{
        if(args.length==2&&args[0].equals("worker")){worker(Path.of(args[1]));return;}
        Path root=Files.createTempDirectory("cloud-memory-fixture-");
        try{
            Path data=root.resolve("data");Files.createDirectories(data);String identity=Planner.id();Files.writeString(data.resolve("server-id"),identity);
            SyncLedger base=new SyncLedger();JSONObject state=SyncExchangeTests.fixture(Planner.now());base.capture(state,1);
            JSONArray rows=base.changes(0);String course=state.getJSONArray("courses").getJSONObject(0).getString("id");
            fixture(data.resolve(CloudSyncServer.name(1)),rows,course,identity,OLD_TASKS,true);
            fixture(root.resolve("incoming.json.gz"),rows,course,identity,NEW_TASKS,false);
            String classpath=System.getProperty("java.class.path");
            String baseline=System.getenv("STUDY_CLOUD_MEMORY_BASELINE");
            if(baseline!=null)classpath=baseline+File.pathSeparator+classpath;
            Process child=new ProcessBuilder(Path.of(System.getProperty("java.home"),"bin/java").toString(),"-Xms16m","-Xmx128m","-XX:+UseSerialGC",
                "-XX:ActiveProcessorCount=2","-XX:MaxMetaspaceSize=64m","-XX:ReservedCodeCacheSize=32m","-XX:MaxDirectMemorySize=16m","-Xss512k",
                "-cp",classpath,CloudServerMemoryTests.class.getName(),"worker",root.toString()).inheritIO().start();
            if(!child.waitFor(180,TimeUnit.SECONDS)){child.destroyForcibly();throw new AssertionError("memory regression exceeded time limit");}
            check(child.exitValue()==0,"128 MiB memory regression failed");
        }finally{try(java.util.stream.Stream<Path> paths=Files.walk(root)){paths.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.deleteIfExists(p);}catch(IOException ignored){}});}}
    }
}
