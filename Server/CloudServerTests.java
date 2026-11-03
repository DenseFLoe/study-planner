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
    static void duplicateCompletionRegression(CloudSyncServer server,String token)throws Exception{
        SyncLedger invalid=copy(server.loadLedger());JSONObject state=invalid.materialize();
        JSONObject record=CourseTools.copy(state.getJSONArray("completions").getJSONObject(0));
        JSONObject row=CourseTools.copy(invalid.records().getJSONObject("completions/"+record.getString("id")));
        record.put("id",Planner.id());row.put("id",record.getString("id")).put("payload",Base64.getEncoder().encodeToString(record.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        invalid.merge(new JSONArray().put(row));
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        request(server,token,"/cloud/snapshot",packed(invalid),400);
        check(server.revision==revision,"duplicate task confirmation committed a cloud version");
        check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"rejected duplicate changed cloud progress");
    }
    static void completionCourseRegression(CloudSyncServer server,String token)throws Exception{
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        for(String taskKind:new String[]{"live","draftTombstone","confirmedTombstone"}){
            SyncLedger invalid=copy(server.loadLedger());JSONObject state=invalid.materialize();
            JSONObject record=CourseTools.copy(state.getJSONArray("completions").getJSONObject(0));
            String other=null;for(JSONObject course:Planner.list(state.getJSONArray("courses")))
                if(!course.getString("id").equals(record.getString("courseID"))){other=course.getString("id");break;}
            if(other==null)throw new AssertionError("course mismatch fixture needs two courses");
            record.put("courseID",other);
            JSONObject row=invalid.records().getJSONObject("completions/"+record.getString("id"));
            row.put("payload",Base64.getEncoder().encodeToString(record.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                .put("version",row.getLong("version")+1).put("modifiedAt",row.optLong("modifiedAt")+1);
            if(!taskKind.equals("live")){
                JSONObject taskRow=invalid.records().getJSONObject("tasks/"+record.getString("taskID"));
                JSONObject task=SyncLedger.payload(taskRow);
                if(taskKind.equals("draftTombstone")){task.remove("confirmedAt");task.put("completedMinutes",0).put("status","planned");}
                taskRow.put("deleted",true).put("version",taskRow.getLong("version")+1).put("modifiedAt",taskRow.optLong("modifiedAt")+1)
                    .put("payload",Base64.getEncoder().encodeToString(task.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)));
            }
            request(server,token,"/cloud/snapshot",packed(invalid),400);
            check(server.revision==revision,"course-mismatched completion committed: "+taskKind);
            check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"course-mismatched completion changed cloud progress: "+taskKind);
        }
    }
    static void taskIntervalRegression(CloudSyncServer server,String token)throws Exception{
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        for(String shape:new String[]{"both","startOnly","endOnly"}){
            SyncLedger invalid=copy(server.loadLedger());JSONObject task=CourseTools.copy(invalid.materialize().getJSONArray("tasks").getJSONObject(0));
            double start=task.getDouble("start"),end=Planner.end(task);
            task.remove("floatingWindowStart");task.remove("floatingWindowEnd");
            if(!shape.equals("endOnly"))task.put("floatingWindowStart",end+600);
            if(!shape.equals("startOnly"))task.put("floatingWindowEnd",start-600);
            JSONObject row=invalid.records().getJSONObject("tasks/"+task.getString("id"));
            row.put("payload",Base64.getEncoder().encodeToString(task.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                .put("version",row.getLong("version")+1).put("modifiedAt",row.optLong("modifiedAt")+1);
            request(server,token,"/cloud/snapshot",packed(invalid),400);
            check(server.revision==revision,"inverted task interval committed: "+shape);
            check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"inverted task interval changed cloud state: "+shape);
        }
    }
    static void completionNumberRegression(CloudSyncServer server,String token)throws Exception{
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        for(boolean removedTask:new boolean[]{false,true})for(Object minutes:new Object[]{4294967297L,1.5,"2",-1,true,JSONObject.NULL}){
            SyncLedger invalid=copy(server.loadLedger());JSONObject record=CourseTools.copy(invalid.materialize().getJSONArray("completions").getJSONObject(0));
            record.put("minutes",minutes);
            JSONObject row=invalid.records().getJSONObject("completions/"+record.getString("id"));
            row.put("payload",Base64.getEncoder().encodeToString(record.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                .put("version",row.getLong("version")+1).put("modifiedAt",row.optLong("modifiedAt")+1);
            if(removedTask){
                JSONObject task=invalid.records().getJSONObject("tasks/"+record.getString("taskID"));
                task.put("deleted",true).put("version",task.getLong("version")+1).put("modifiedAt",task.optLong("modifiedAt")+1);
            }
            request(server,token,"/cloud/snapshot",packed(invalid),400);
            check(server.revision==revision,"invalid completion number committed, removedTask="+removedTask+", minutes="+minutes);
            check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"invalid completion number changed cloud progress");
        }
    }
    static void completionTotalRegression(CloudSyncServer server,String token)throws Exception{
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        for(boolean baselineOverflow:new boolean[]{false,true}){
            SyncLedger invalid=copy(server.loadLedger());JSONObject record=CourseTools.copy(invalid.materialize().getJSONArray("completions").getJSONObject(0));
            JSONObject row=invalid.records().getJSONObject("completions/"+record.getString("id"));
            record.put("minutes",baselineOverflow?1:Integer.MAX_VALUE);
            row.put("payload",Base64.getEncoder().encodeToString(record.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                .put("version",row.getLong("version")+1).put("modifiedAt",row.optLong("modifiedAt")+1);
            JSONObject task=invalid.records().getJSONObject("tasks/"+record.getString("taskID"));
            task.put("deleted",true).put("version",task.getLong("version")+1).put("modifiedAt",task.optLong("modifiedAt")+1);
            if(baselineOverflow){
                JSONObject courseRow=invalid.records().getJSONObject("courses/"+record.getString("courseID"));
                JSONObject course=SyncLedger.payload(courseRow).put("initialCompletedMinutes",Integer.MAX_VALUE);
                courseRow.put("payload",Base64.getEncoder().encodeToString(course.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                    .put("version",courseRow.getLong("version")+1).put("modifiedAt",courseRow.optLong("modifiedAt")+1);
            }else{
                JSONObject extra=CourseTools.copy(record).put("taskID",Planner.id()).put("minutes",1);
                extra.put("id",Planner.stableID("completion|"+extra.getString("taskID")));
                JSONObject extraRow=CourseTools.copy(row).put("id",extra.getString("id"))
                    .put("payload",Base64.getEncoder().encodeToString(extra.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)));
                invalid.records().put(SyncLedger.key(extraRow),extraRow);
            }
            request(server,token,"/cloud/snapshot",packed(invalid),400);
            check(server.revision==revision,"overflowing completion total committed");
            check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"overflowing completion total changed cloud progress");
        }
    }
    static void courseNumberRegression(CloudSyncServer server,String token)throws Exception{
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        for(boolean nested:new boolean[]{false,true})for(Object total:new Object[]{4294967416L,120.5,"120",true,JSONObject.NULL,null}){
            SyncLedger invalid=copy(server.loadLedger());JSONObject state=invalid.materialize(),course;
            if(nested){
                Set<String> ids=new HashSet<>();for(JSONObject source:Planner.list(state.getJSONArray("courses")))ids.add(source.getString("id"));
                course=CourseTools.merge(state,ids,"Synthetic merged course");invalid.capture(state);
            }else course=CourseTools.copy(state.getJSONArray("courses").getJSONObject(0));
            JSONObject target=nested?course.getJSONArray("mergedSources").getJSONObject(0):course;
            if(total==null)target.remove("totalMinutes");else target.put("totalMinutes",total);
            JSONObject row=invalid.records().getJSONObject("courses/"+course.getString("id"));
            row.put("payload",Base64.getEncoder().encodeToString(course.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                .put("version",row.getLong("version")+1).put("modifiedAt",row.optLong("modifiedAt")+1);
            request(server,token,"/cloud/snapshot",packed(invalid),400);
            check(server.revision==revision,"invalid course number committed, nested="+nested);
            check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"invalid course number changed cloud state");
        }
    }
    static void manualLessonNumberRegression(CloudSyncServer server,String token)throws Exception{
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        for(String kind:new String[]{"manual","nested","unused"})for(Object duration:new Object[]{4294967356L,60.5,"60",true,JSONObject.NULL,null}){
            SyncLedger invalid=copy(server.loadLedger());JSONObject state=invalid.materialize(),course;
            if(kind.equals("nested")){
                Set<String> ids=new HashSet<>();for(JSONObject source:Planner.list(state.getJSONArray("courses")))ids.add(source.getString("id"));
                course=CourseTools.merge(state,ids,"Synthetic merged course");invalid.capture(state);
            }else course=CourseTools.copy(state.getJSONArray("courses").getJSONObject(0));
            JSONObject target=kind.equals("nested")?course.getJSONArray("mergedSources").getJSONObject(0):course;
            if(!kind.equals("unused"))target.put("type","不定时录播课程");
            JSONObject lesson=new JSONObject().put("id","synthetic-lesson").put("name","Synthetic lesson");
            if(duration!=null)lesson.put("durationMinutes",duration);
            target.put("manualLessons",new JSONArray().put(lesson));
            JSONObject row=invalid.records().getJSONObject("courses/"+course.getString("id"));
            row.put("payload",Base64.getEncoder().encodeToString(course.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                .put("version",row.getLong("version")+1).put("modifiedAt",row.optLong("modifiedAt")+1);
            request(server,token,"/cloud/snapshot",packed(invalid),400);
            check(server.revision==revision,"invalid manual lesson number committed: "+kind);
            check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"invalid manual lesson number changed cloud state");
        }
        for(Object manual:new Object[]{"invalid",true,new JSONObject(),new JSONArray().put(JSONObject.NULL),new JSONArray().put(60),new JSONArray().put("lesson")}){
            SyncLedger invalid=copy(server.loadLedger());JSONObject course=CourseTools.copy(invalid.materialize().getJSONArray("courses").getJSONObject(0));
            course.put("manualLessons",manual);JSONObject row=invalid.records().getJSONObject("courses/"+course.getString("id"));
            row.put("payload",Base64.getEncoder().encodeToString(course.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                .put("version",row.getLong("version")+1).put("modifiedAt",row.optLong("modifiedAt")+1);
            request(server,token,"/cloud/snapshot",packed(invalid),400);
            check(server.revision==revision,"invalid manual lesson container committed");
            check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"invalid manual lesson container changed cloud state");
        }
    }
    static void taskNumberRegression(CloudSyncServer server,String token)throws Exception{
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        for(String field:new String[]{"durationMinutes","completedMinutes"})for(String kind:new String[]{"live","draftTombstone","confirmedTombstone"}){
            int ordinary=field.equals("durationMinutes")?60:20;
            for(Object value:new Object[]{4294967296L+ordinary,ordinary+0.5,String.valueOf(ordinary),true,JSONObject.NULL,null}){
                SyncLedger invalid=copy(server.loadLedger());JSONObject record=invalid.materialize().getJSONArray("completions").getJSONObject(0);
                JSONObject row=invalid.records().getJSONObject("tasks/"+record.getString("taskID")),task=SyncLedger.payload(row);
                if(kind.equals("draftTombstone")){task.remove("confirmedAt");task.put("completedMinutes",0).put("status","planned");}
                if(value==null)task.remove(field);else task.put(field,value);
                row.put("payload",Base64.getEncoder().encodeToString(task.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)))
                    .put("deleted",!kind.equals("live")).put("version",row.getLong("version")+1).put("modifiedAt",row.optLong("modifiedAt")+1);
                request(server,token,"/cloud/snapshot",packed(invalid),400);
                check(server.revision==revision,"invalid task number committed: "+field+", "+kind);
                check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"invalid task number changed cloud state");
            }
        }
    }
    static void legacyConfirmationRegression(CloudSyncServer server,String token)throws Exception{
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        for(int completed:new int[]{61,120}){
            SyncLedger invalid=copy(server.loadLedger());JSONObject state=invalid.materialize();
            JSONObject task=CourseTools.copy(state.getJSONArray("tasks").getJSONObject(0)).put("id",Planner.id());
            task.put("start",task.getDouble("start")+86400).put("durationMinutes",60).put("completedMinutes",completed)
                .put("confirmedAt",Planner.now()).put("status","completed");
            state.getJSONArray("tasks").put(task);invalid.capture(state);
            request(server,token,"/cloud/snapshot",packed(invalid),400);
            check(server.revision==revision,"invalid legacy confirmation committed a cloud version");
            check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"invalid legacy confirmation changed cloud progress");
        }
    }
    static void malformedTombstoneWireRegression(CloudSyncServer server,String token)throws Exception{
        long revision=server.revision;String before=SyncLedger.canonical(server.loadLedger().materialize());
        for(Map.Entry<String,JSONObject> sample:SyncRecordValidationTests.invalidRows().entrySet()){
            request(server,token,"/cloud/snapshot",SyncRecordValidationTests.packedWithRow(sample.getValue()),400);
            check(server.revision==revision,"malformed tombstone committed: "+sample.getKey());
        }
        check(before.equals(SyncLedger.canonical(server.loadLedger().materialize())),"malformed wire changed cloud state");
    }
    static void mergedHistoryRestRegression(Path parent)throws Exception{
        double now=Planner.now();JSONObject state=SyncScheduleIntegrityTests.confirmedHistoryAndDraft(now,5,60);
        String completion=SyncLedger.canonical(state.getJSONArray("completions").getJSONObject(0));
        SyncLedger ledger=new SyncLedger();ledger.capture(state);
        Path archive=Files.createTempFile(parent,"rest-fixture-",".gz");
        try{
            Files.write(archive,packed(ledger));
            try(DiskSnapshot disk=new DiskSnapshot(parent)){
                disk.read(archive);
                // Inputs are unchanged: only the merged task/history rest boundary needs repair.
                disk.normalize(ledger.value.getString("device"),state);
                disk.write(archive,CloudSnapshot.header(ledger));
            }
            JSONObject normalized;try(InputStream in=Files.newInputStream(archive)){normalized=CloudSnapshot.read(in).ledger.materialize();}
            int pending=0;for(JSONObject task:Planner.list(normalized.getJSONArray("tasks")))if(Planner.pending(task)&&Planner.end(task)>now){
                pending++;check(task.getDouble("start")>=now+Planner.BREAK_SECONDS,"cloud normalization overlapped confirmed history/rest");
            }
            check(pending>0,"cloud rest repair removed all feasible work");
            check(completion.equals(SyncLedger.canonical(normalized.getJSONArray("completions").getJSONObject(0))),"cloud rest repair changed confirmed progress");
        }finally{Files.deleteIfExists(archive);}
    }
    public static void main(String[] args)throws Exception{
        Path directory=Files.createTempDirectory("planner-cloud-server-");String token=UUID.randomUUID().toString()+UUID.randomUUID();
        CloudSyncServer server=new CloudSyncServer(directory,"127.0.0.1",0,token);server.start();
        try{
            request(server,"invalid-placeholder","/cloud/status",null,401);
            server.uploadLock.lock();
            try{request(server,token,"/cloud/snapshot",packed(initial()),503);}finally{server.uploadLock.unlock();}
            diskRegression(server,token,directory);
            mergedHistoryRestRegression(directory);
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
            duplicateCompletionRegression(server,token);
            completionCourseRegression(server,token);
            taskIntervalRegression(server,token);
            completionNumberRegression(server,token);
            completionTotalRegression(server,token);
            courseNumberRegression(server,token);
            manualLessonNumberRegression(server,token);
            taskNumberRegression(server,token);
            legacyConfirmationRegression(server,token);
            malformedTombstoneWireRegression(server,token);
            long tombstoneRevision=server.revision;String beforeTombstone=SyncLedger.canonical(server.loadLedger().materialize());
            request(server,token,"/cloud/snapshot",packed(SyncExchangeTests.mismatchedTaskTombstoneFixture()),400);
            check(server.revision==tombstoneRevision,"mismatched task tombstone committed a cloud version");
            check(beforeTombstone.equals(SyncLedger.canonical(server.loadLedger().materialize())),"rejected task recovery changed cloud progress");
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
