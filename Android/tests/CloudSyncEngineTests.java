package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.file.*;
import java.time.LocalDate;
import java.util.*;

/** Real gzip archives/outbox/backups with a deterministic remote and transactional store. */
public final class CloudSyncEngineTests {
    static int checks;
    static final double NOW=Planner.at(LocalDate.of(2026,11,5),480);
    static final String ENDPOINT="https://sync.example.invalid",SERVER="11111111-1111-4111-8111-111111111111";
    interface Action{void run()throws Exception;}
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejected(Action action)throws Exception{
        try{action.run();throw new AssertionError("Expected safe failure");}catch(IOException|IllegalStateException expected){checks++;}
    }
    static SyncLedger copy(SyncLedger ledger)throws Exception{return new SyncLedger(CourseTools.copy(ledger.value));}
    static String state(SyncLedger ledger)throws Exception{return SyncLedger.canonical(PlannerBackupFile.businessState(ledger.materialize()));}
    static SyncLedger fixture()throws Exception{
        JSONObject state=PlannerTests.empty(),course=CourseEditingTests.course();
        course.put("autoScheduleEnabled",false).put("name","Shared course");state.getJSONArray("courses").put(course);
        SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);return ledger;
    }
    static void rename(SyncLedger ledger,String name,long time)throws Exception{
        JSONObject state=ledger.materialize();state.getJSONArray("courses").getJSONObject(0).put("name",name);ledger.capture(state,time);
    }
    static void addLocalCourse(SyncLedger ledger,long time)throws Exception{
        JSONObject state=ledger.materialize(),course=CourseEditingTests.course();
        course.put("name","Only on phone").put("autoScheduleEnabled",false);state.getJSONArray("courses").put(course);
        JSONObject task=Planner.task(course.getString("id"),NOW,60);state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),20,NOW);
        ledger.capture(state,time);
    }
    static final class Store implements CloudSyncEngine.Store {
        SyncLedger ledger;final PlannerBackupRepository backups;int commits,replacements;boolean failCommit;
        Store(SyncLedger ledger,File directory)throws Exception{this.ledger=copy(ledger);backups=new PlannerBackupRepository(directory);}
        public SyncLedger read()throws Exception{return copy(ledger);}
        public boolean commit(SyncLedger candidate,JSONObject checkpoint,boolean replace)throws Exception{
            if(!SyncLedger.equivalent(checkpoint,ledger.metadata()))return false;
            candidate.materialize();
            if(replace)backups.save(ledger.materialize(),NOW,"云端较新课表覆盖前的手机日程",null);
            if(failCommit)throw new IOException("Injected atomic commit failure");
            ledger=copy(candidate);commits++;if(replace)replacements++;return true;
        }
    }
    static final class Remote implements CloudSyncEngine.Remote {
        SyncLedger ledger;long revision=1;int uploads,downloads;boolean failDownload,wrongIdentity,failUpload;
        Action duringDownload;final List<String> calls=new ArrayList<>();
        Remote(SyncLedger ledger)throws Exception{this.ledger=copy(ledger);}
        public JSONObject status()throws Exception{calls.add("status");return new JSONObject().put("format",1).put("serverID",SERVER).put("revision",revision);}
        public JSONObject upload(File file)throws Exception{
            calls.add("upload");uploads++;if(failUpload)throw new IOException("Injected network failure");
            try(InputStream in=new FileInputStream(file)){ledger.merge(CloudSnapshot.read(in).ledger.changes(0));}
            revision++;return status();
        }
        public CloudSnapshot latest()throws Exception{
            calls.add("download");downloads++;if(failDownload)throw new IOException("Interrupted download");
            JSONObject header=CloudSnapshot.header(ledger).put("serverID",wrongIdentity?"22222222-2222-4222-8222-222222222222":SERVER).put("revision",revision);
            // File creation time is deliberately later than every business edit.
            header.put("createdAt",System.currentTimeMillis());
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,header);
            if(duringDownload!=null){Action action=duringDownload;duringDownload=null;action.run();}
            return CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
        }
    }
    static final class Fixture implements AutoCloseable {
        final Path directory;final File outbox;final Store store;final Remote remote;
        Fixture(SyncLedger local,SyncLedger server)throws Exception{
            directory=Files.createTempDirectory("cloud-replacement-");outbox=directory.resolve("outbox").toFile();
            store=new Store(local,directory.resolve("backups").toFile());remote=new Remote(server);
        }
        CloudSyncEngine.Result sync()throws Exception{return new CloudSyncEngine(store,remote,outbox,ENDPOINT,()->NOW,text->{}).sync();}
        public void close()throws Exception{
            try(java.util.stream.Stream<Path> paths=Files.walk(directory)){
                for(Path path:(Iterable<Path>)paths.sorted(Comparator.reverseOrder())::iterator)Files.delete(path);
            }
        }
    }
    static void replaceAndRepeat()throws Exception{
        SyncLedger local=fixture(),earlier=copy(local),remote=copy(local);remote.value.put("device","server-source");
        addLocalCourse(local,1500);rename(remote,"Latest server course",2000);String original=state(local),expected=state(remote);
        try(Fixture f=new Fixture(local,remote)){
            CloudOutbox.enqueue(f.outbox,earlier);CloudOutbox.enqueue(f.outbox,local);
            CloudSyncEngine.Result result=f.sync();
            check(result.replaced&&result.changed&&!result.again,"newer server did not finish with direct replacement");
            check(f.remote.uploads==0&&f.remote.downloads==1,"replacement uploaded old data or downloaded multiple times");
            check(expected.equals(state(f.store.ledger)),"replacement mixed local-only courses/progress into server state");
            check(f.store.ledger.value.getString("device").equals(local.value.getString("device")),"phone identity changed");
            check(f.store.ledger.sequence()>local.sequence(),"peer sequence moved backwards");
            check(CloudReplacement.modifiedAt(f.store.ledger)==2000,"download manufactured a new business edit time");
            check(CloudOutbox.queued(f.outbox).length==0,"replaced outbox survived");
            List<PlannerBackupRepository.Entry> entries=f.store.backups.entries();check(entries.size()==1,"replacement backup missing");
            PlannerBackupFile backup=f.store.backups.load(entries.get(0).id);
            check(SyncLedger.canonical(backup.state()).equals(original),"backup lost phone-only records or progress");
            check(backup.summary().contains("云端较新课表覆盖前"),"replacement backup cannot be identified in UI");
            // A previously paired peer must receive removals, not resurrect discarded phone rows.
            SyncLedger peer=copy(local);peer.merge(f.store.ledger.changes(local.sequence()));
            check(expected.equals(state(peer)),"hotspot incremental resurrected discarded local records");
            int commits=f.store.commits,downloads=f.remote.downloads;result=f.sync();
            check(!result.changed&&!result.replaced&&!result.again,"unchanged sync did work");
            check(f.store.commits==commits&&f.remote.downloads==downloads&&f.remote.uploads==0,"unchanged sync rewrote/downloaded data");
            check(f.store.backups.entries().size()==1,"unchanged sync duplicated backup");
            // Simulate a crash between database commit and outbox deletion.
            CloudOutbox.enqueue(f.outbox,local);f.sync();
            check(CloudOutbox.queued(f.outbox).length==0&&f.remote.uploads==0,"crash recovery uploaded discarded snapshot");
            // New saves after the replacement boundary must remain pending.
            SyncLedger edited=copy(f.store.ledger);rename(edited,"New phone edit",3000);CloudOutbox.enqueue(f.outbox,edited);
            CloudOutbox.discardReplaced(f.outbox,f.store.ledger);
            check(CloudOutbox.queued(f.outbox).length==1,"discard boundary removed a later phone edit");
        }
    }
    static void fallbackAndDates()throws Exception{
        for(String mode:new String[]{"phone-newer","equal","legacy-local","legacy-remote"}){
            SyncLedger local=fixture(),remote=copy(local);addLocalCourse(local,mode.equals("phone-newer")?3000:2000);rename(remote,"Cloud name",2000);
            if(mode.startsWith("legacy")){
                SyncLedger legacy=mode.equals("legacy-local")?local:remote;
                legacy.records().getJSONObject("settings/settings").remove("modifiedAt");
            }
            check(!CloudReplacement.serverNewer(local,remote),"unsafe timestamp authorized replacement: "+mode);
            try(Fixture f=new Fixture(local,remote)){
                CloudSyncEngine.Result result=f.sync();
                check(!result.replaced&&f.remote.uploads>0,"fallback did not preserve normal two-way sync: "+mode);
                check(f.store.ledger.materialize().getJSONArray("courses").length()==2,"fallback discarded local-only course: "+mode);
                check(f.store.backups.entries().isEmpty(),"fallback incorrectly made replacement backup: "+mode);
                check(f.remote.calls.indexOf("download")<f.remote.calls.indexOf("upload"),"comparison happened after upload");
            }
        }
        SyncLedger local=fixture(),remote=copy(local);JSONObject deleted=remote.materialize();deleted.put("courses",new JSONArray());remote.capture(deleted,5000);
        check(CloudReplacement.serverNewer(local,remote),"deletion time was ignored");
        try(Fixture f=new Fixture(local,remote)){f.sync();check(f.store.ledger.materialize().getJSONArray("courses").length()==0,"server deletion was not mirrored");}
    }
    static void failuresAndConcurrentEdit()throws Exception{
        SyncLedger local=fixture(),remote=copy(local);rename(remote,"Server newer",2000);String before=state(local);
        for(String mode:new String[]{"backup","commit","download","identity"})try(Fixture f=new Fixture(local,remote)){
            CloudOutbox.enqueue(f.outbox,local);
            if(mode.equals("backup"))Files.write(f.store.backups.directory.toPath(),new byte[]{1});
            if(mode.equals("commit"))f.store.failCommit=true;
            if(mode.equals("download"))f.remote.failDownload=true;
            if(mode.equals("identity"))f.remote.wrongIdentity=true;
            rejected(()->f.sync());
            check(before.equals(state(f.store.ledger))&&f.store.commits==0,"failure changed phone: "+mode);
            check(f.remote.uploads==0&&CloudOutbox.queued(f.outbox).length==1,"failure uploaded or deleted pending data: "+mode);
            if(mode.equals("commit"))check(f.store.backups.entries().size()==1,"failed commit lost recovery backup");
        }
        try(Fixture f=new Fixture(local,remote)){
            f.remote.duringDownload=()->rename(f.store.ledger,"Edit while downloading",3000);
            CloudSyncEngine.Result result=f.sync();
            check(result.again&&!result.replaced&&f.store.commits==0,"download race overwrote a new phone edit");
            check(f.store.backups.entries().isEmpty()&&f.remote.uploads==0,"download race used stale decision");
            f.sync();check(f.store.ledger.materialize().getJSONArray("courses").getJSONObject(0).getString("name").equals("Edit while downloading"),"retry lost concurrent phone edit");
        }
    }
    static void bootstrapAndRollback()throws Exception{
        SyncLedger local=fixture();try(Fixture f=new Fixture(local,local)){
            f.remote.revision=0;f.sync();check(f.remote.uploads==1&&f.remote.downloads==1,"empty server bootstrap failed");
            f.remote.revision=0;int uploads=f.remote.uploads;rejected(()->f.sync());
            check(f.remote.uploads==uploads,"server rollback accepted local upload");
        }
    }
    static void recoverBackup()throws Exception{
        SyncLedger local=fixture(),remote=copy(local);addLocalCourse(local,1500);rename(remote,"Server newer",2000);
        try(Fixture f=new Fixture(local,remote)){
            f.sync();PlannerBackupFile backup=f.store.backups.load(f.store.backups.entries().get(0).id);
            JSONObject current=f.store.ledger.materialize();new PlannerBackupFile.Restore(backup,current).apply(current);
            f.store.ledger.capture(current,3000);CloudSyncEngine.Result result=f.sync();
            check(!result.replaced&&f.remote.uploads==1,"manual backup restore was immediately overwritten");
            check(state(local).equals(state(f.store.ledger)),"restored phone-only course/progress did not survive sync");
            check(state(local).equals(state(f.remote.ledger)),"restored data did not reach server");
        }
    }
    public static void main(String[] args)throws Exception{
        replaceAndRepeat();fallbackAndDates();failuresAndConcurrentEdit();bootstrapAndRollback();recoverBackup();
        System.out.println("Cloud download-first replacement: "+checks+" checks passed");
    }
}
