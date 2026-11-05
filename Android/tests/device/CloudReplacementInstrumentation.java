package local.studyplanner;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import org.json.*;
import java.io.*;

/** Isolated SQLite coverage for the backup-before-replace transaction. */
public final class CloudReplacementInstrumentation extends Instrumentation {
    int checks;
    void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    public void onCreate(Bundle args){super.onCreate(args);start();}
    public void onStart(){
        Bundle result=new Bundle();Context context=getTargetContext();
        String name="cloud-replacement-test-"+System.nanoTime()+".db";PlannerDatabase db=new PlannerDatabase(context,name);
        try{
            JSONObject state=PlannerBackupFile.readLegacyState(context.getAssets().open("initial-state.json"));
            SyncLedger local=new SyncLedger();local.capture(state,1000);db.commit(local,false);
            SyncLedger remote=new SyncLedger(CourseTools.copy(local.value));
            JSONObject changed=remote.materialize();changed.getJSONObject("settings").put("minimumScheduleUnit",30);remote.capture(changed,2000);
            // Ensure a new timestamp even when a fixture already has the same setting.
            if(!CloudReplacement.serverNewer(local,remote)){
                changed.getJSONObject("settings").put("minimumScheduleUnit",60);remote.capture(changed,2000);
            }
            SyncLedger replacement=CloudReplacement.prepare(local,remote);JSONObject checkpoint=local.metadata();
            String original=SyncLedger.canonical(db.ledger().value);
            // Backup creation failure cannot reach the database replacement.
            try(FileOutputStream out=new FileOutputStream(db.backups.directory)){out.write(1);}
            try{db.commitCloud(replacement,checkpoint,true);throw new AssertionError("Backup failure accepted");}
            catch(IllegalStateException expected){checks++;}
            check(original.equals(SyncLedger.canonical(db.ledger().value)),"Backup failure changed SQLite");
            check(db.backups.directory.delete(),"Could not remove backup failure fixture");
            // Force an insert failure after DELETE; SQLite must roll back both rows and metadata.
            db.getWritableDatabase().execSQL("CREATE TRIGGER cloud_test_abort BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'injected test failure'); END");
            try{db.commitCloud(replacement,checkpoint,true);throw new AssertionError("Commit failure accepted");}
            catch(android.database.SQLException expected){checks++;}
            check(original.equals(SyncLedger.canonical(db.ledger().value)),"Partial replacement survived SQLite rollback");
            check(db.backups.entries().size()==1,"Rollback lost backup");
            db.getWritableDatabase().execSQL("DROP TRIGGER cloud_test_abort");
            check(db.commitCloud(replacement,checkpoint,true),"Valid replacement failed");
            check(SyncLedger.equivalent(db.ledger().records(),replacement.records()),"SQLite retained rows outside replacement");
            check(db.metadata().optLong("cloudDiscardedSequence")==local.sequence(),"Discard checkpoint not atomic with rows");
            check(!db.commitCloud(replacement,checkpoint,true),"Stale checkpoint accepted");
            result.putString("stream","PASS "+checks+" cloud replacement SQLite checks\n");finish(-1,result);
        }catch(Throwable error){result.putString("stream","FAIL: "+error.getClass().getSimpleName()+" · "+error.getMessage());finish(1,result);}
        finally{db.close();context.deleteDatabase(name);File[] files=db.backups.directory.listFiles();if(files!=null)for(File file:files)file.delete();db.backups.directory.delete();}
    }
}
