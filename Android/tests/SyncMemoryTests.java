package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.*;
import java.util.*;

/** Run in its own 256 MiB heap with UTF-16 strings, like the reported Android heap. */
public final class SyncMemoryTests {
    static void check(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    static Reader reader(File file)throws Exception{return new BufferedReader(new InputStreamReader(new FileInputStream(file),StandardCharsets.UTF_8));}
    static JSONObject initial()throws Exception{return new JSONObject(new String(Files.readAllBytes(new File("Android/assets/initial-state.json").toPath()),StandardCharsets.UTF_8));}
    static void fixture(File file)throws Exception{
        SyncLedger small=new SyncLedger();small.capture(initial());
        char[] chars=new char[200000];Arrays.fill(chars,'课');String notes=new String(chars);
        try(Writer out=SyncTransfer.writer(file)){
            out.write("{\"changes\":[");SyncJSON.write(out,small.changes(0).getJSONObject(0));
            for(int i=0;i<60;i++){
                String id=Planner.stableID("memory-course-"+i);
                JSONObject course=new JSONObject().put("id",id).put("name","Memory fixture "+i).put("type","录播课程")
                    .put("totalMinutes",60).put("initialCompletedMinutes",0).put("startDate",0).put("deadline",1000000000)
                    .put("minimumBlockMinutes",60).put("priority",2).put("color","blue").put("autoScheduleEnabled",false).put("isArchived",false).put("notes",notes+i);
                JSONObject row=new JSONObject().put("kind","courses").put("id",id).put("deleted",false).put("version",1).put("device","MEMORY-FIXTURE")
                    .put("sequence",i+2).put("payload",Base64.getEncoder().encodeToString(course.toString().getBytes(StandardCharsets.UTF_8)));
                out.write(',');SyncJSON.write(out,row);
            }
            // Generated/deleted tasks accumulate in a real ledger even when the visible plan is small.
            for(int i=0;i<10000;i++){
                String id=Planner.stableID("memory-deleted-task-"+i);
                JSONObject task=new JSONObject().put("id",id).put("courseID",Planner.stableID("memory-course-0")).put("start",0)
                    .put("durationMinutes",30).put("completedMinutes",0).put("status","planned");
                JSONObject row=new JSONObject().put("kind","tasks").put("id",id).put("deleted",true).put("version",1).put("device","MEMORY-FIXTURE")
                    .put("sequence",i+62).put("payload",Base64.getEncoder().encodeToString(task.toString().getBytes(StandardCharsets.UTF_8)));
                out.write(',');SyncJSON.write(out,row);
            }
            out.write("],\"protocol\":1,\"cursor\":0,\"automatic\":false,\"date\":\"2026-10-19\"}");
        }
    }
    static byte[] digest(File file)throws Exception{
        MessageDigest hash=MessageDigest.getInstance("SHA-256");byte[] block=new byte[8192];
        try(InputStream in=new FileInputStream(file)){for(int n;(n=in.read(block))!=-1;)hash.update(block,0,n);}return hash.digest();
    }
    public static void main(String[] args)throws Exception{
        File root=Files.createTempDirectory("planner-memory-test-").toFile(),input=new File(root,"input"),output=new File(root,"output");
        try{
            fixture(input);check(input.length()>40*1024*1024,"fixture must exceed the reported ~37.5 MiB allocation");
            byte[] otherHeap=new byte[32*1024*1024];Arrays.fill(otherHeap,(byte)7);
            SyncLedger ledger=new SyncLedger();ledger.capture(initial());JSONObject visibleState=null;byte[] previous=null;long through=0;
            for(int round=0;round<3;round++){
                try(SyncTransfer transfer=new SyncTransfer(root)){
                    transfer.handle(new JSONObject().put("operation","begin").put("length",input.length()),(in,out)->{});
                    byte[] uploadBlock=new byte[SyncTransfer.CHUNK_SIZE];int offset=0;
                    try(InputStream in=new FileInputStream(input)){
                        for(int size;(size=in.read(uploadBlock))!=-1;){
                            transfer.handle(new JSONObject().put("operation","upload").put("offset",offset)
                                .put("data",Base64.getEncoder().encodeToString(Arrays.copyOf(uploadBlock,size))),(source,target)->{});
                            offset+=size;
                        }
                    }
                    JSONObject ready=transfer.handle(new JSONObject().put("operation","exchange"),(source,target)->{
                        SyncExchange.Result result=SyncExchange.apply(ledger,consumer->{try(Reader in=reader(source)){return SyncJSON.readExchange(in,consumer);}},Planner.now());
                        if(args.length>0&&args[0].equals("legacy"))new JSONObject(ledger.value.toString()).remove("records");
                        check(!ledger.metadata().has("records")&&ledger.metadata().toString().length()<4096,"metadata copied payloads");
                        result.reply.put("changes",ledger.changes(result.after)).put("session","MEMORY-SESSION");
                        try(Writer out=SyncTransfer.writer(target)){SyncJSON.write(out,result.reply);}
                        Iterator<String> keys=ledger.records().keys();while(keys.hasNext())check(ledger.records().getJSONObject(keys.next()).toString().length()<1401000,"unbounded database row");
                    });
                    int length=ready.getInt("length"),downloaded=0;
                    try(OutputStream out=new FileOutputStream(output)){
                        while(downloaded<length){
                            JSONObject chunk=transfer.handle(new JSONObject().put("operation","download").put("offset",downloaded),(source,target)->{});
                            byte[] bytes=Base64.getDecoder().decode(chunk.getString("data"));
                            check(bytes.length<=SyncTransfer.DOWNLOAD_CHUNK_SIZE,"download exceeded memory bound");out.write(bytes);downloaded+=bytes.length;
                        }
                    }
                }
                if(visibleState==null)visibleState=ledger.materialize(); // Keep the UI state live during following full transfers.
                byte[] current=digest(output);
                if(round>0)check(through==ledger.sequence(),"retry created extra revisions");
                if(round>1)check(Arrays.equals(previous,current),"retry changed staged response");
                through=ledger.sequence();previous=current;
                check(visibleState.getJSONArray("courses").length()==60&&otherHeap[otherHeap.length-1]==7,"UI/reserved heap was not retained");
            }
            System.out.println("PASS 3 full exchanges: "+input.length()+" byte upload, "+output.length()+" byte response, retained UI + 32 MiB reserve, max heap "+Runtime.getRuntime().maxMemory());
        }finally{for(File file:root.listFiles())file.delete();root.delete();}
    }
}
