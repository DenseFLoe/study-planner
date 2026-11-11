package local.studyplanner;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import org.json.*;

/** Exercise untrusted metadata at the actual outbox and backup filesystem boundaries. */
public final class LocalFileBoundaryTests {
    static int checks;
    interface Action { void run()throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejected(Action action)throws Exception {
        try{action.run();throw new AssertionError("Unsafe file operation accepted");}
        catch(IOException expected){checks++;}
    }
    static void outbox(Path root)throws Exception {
        File directory=root.resolve("outbox").toFile();
        SyncLedger ledger=CloudSyncEngineTests.fixture();
        String device=ledger.value.getString("device");long sequence=ledger.sequence();
        for(String invalid:new String[]{"../outside","nested/file","nested\\file","/absolute","..","", "x".repeat(65)}){
            ledger.value.put("device",invalid);
            rejected(()->CloudOutbox.enqueue(directory,ledger));
            rejected(()->CloudOutbox.prepare(directory,ledger));
            check(!directory.exists(),"Invalid device created an outbox");
        }
        ledger.value.put("device",device).put("sequence",-1);
        rejected(()->CloudOutbox.enqueue(directory,ledger));
        rejected(()->CloudOutbox.prepare(directory,ledger));
        ledger.value.put("sequence",sequence);
        CloudOutbox.enqueue(directory,ledger);CloudOutbox.enqueue(directory,ledger);
        check(CloudOutbox.queued(directory).length==1,"Duplicate enqueue lost idempotence");
        check(CloudOutbox.queued(directory)[0].getName().equals(device+"-"+sequence+".json.gz"),"Existing outbox naming changed");
        File prepared=CloudOutbox.prepare(directory,ledger);
        try(InputStream input=new FileInputStream(prepared)){
            check(CloudSnapshot.read(input).header.getString("device").equals(device),"Prepared snapshot lost its identity");
        }
        ledger.value.put("cloudDiscardedSequence",sequence);CloudOutbox.discardReplaced(directory,ledger);
        check(CloudOutbox.queued(directory).length==0,"Discard boundary left prepared or queued snapshots");
        // A serialization error after file creation must not leave an uploadable partial snapshot.
        ledger.value.put("records",new JSONObject().put("broken","invalid record"));
        try{CloudOutbox.prepare(directory,ledger);throw new AssertionError("Malformed ledger accepted");}
        catch(JSONException expected){checks++;}
        check(directory.list().length==0,"Failed preparation left a partial archive");
    }
    static void backups(Path root)throws Exception {
        Path directory=Files.createDirectory(root.resolve("backups"));
        PlannerBackupRepository repository=new PlannerBackupRepository(directory.toFile());
        PlannerBackupRepository.Entry entry=repository.save(PlannerTests.empty(),100,"Synthetic boundary test",null);
        for(String invalid:new String[]{"../outside","/absolute","nested/file","1-1-1-1-1","aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"})
            rejected(()->repository.load(invalid));
        Path file=directory.resolve(entry.id+".json"),outside=root.resolve("outside.json");
        byte[] original=Files.readAllBytes(file);Files.move(file,outside);Files.createSymbolicLink(file,outside);
        rejected(()->repository.load(entry.id));
        check(repository.entries().isEmpty()&&repository.unreadable==1,"Linked backup was listed as readable");
        check(Arrays.equals(original,Files.readAllBytes(outside)),"External backup was changed");
        Files.delete(file);Files.move(outside,file);
        check(repository.load(entry.id).id().equals(entry.id),"Ordinary backup no longer loads");
    }
    public static void main(String[] args)throws Exception {
        Path root=Files.createTempDirectory("planner-file-boundaries-");
        try{outbox(root);backups(root);System.out.println("PASS "+checks+" local file boundary and partial archive checks");}
        finally{try(java.util.stream.Stream<Path> paths=Files.walk(root)){
            for(Path path:(Iterable<Path>)paths.sorted(Comparator.reverseOrder())::iterator)Files.delete(path);
        }}
    }
}
