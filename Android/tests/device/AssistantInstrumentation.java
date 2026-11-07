package local.studyplanner;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import org.json.*;
import java.io.File;
import java.util.concurrent.atomic.AtomicInteger;

/** Device-only, disposable database checks. Does not open the user's planner or assistant workspace. */
public final class AssistantInstrumentation extends Instrumentation {
    int checks;
    void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    public void onCreate(Bundle args){super.onCreate(args);start();}
    public void onStart(){
        Context context=getTargetContext();String name="assistant-guard-test-"+System.nanoTime()+".db";PlannerDatabase db=new PlannerDatabase(context,name);Bundle result=new Bundle();
        try{
            JSONObject state=PlannerBackupFile.readLegacyState(context.getAssets().open("initial-state.json"));db.save(state);String before=SyncLedger.canonical(db.ledger().value);long revision=db.assistantRevision();
            JSONObject changed=CourseTools.copy(state);int old=changed.getJSONObject("settings").getInt("minimumScheduleUnit");changed.getJSONObject("settings").put("minimumScheduleUnit",old==30?60:30);AtomicInteger guards=new AtomicInteger();
            try{db.saveChecked(changed,()->{if(guards.incrementAndGet()==2)throw new AssistantProtocol.Failure("synthetic expiry at transaction boundary");});throw new AssertionError("Expired transaction committed");}catch(AssistantProtocol.Failure expected){checks++;}
            check(before.equals(SyncLedger.canonical(db.ledger().value)),"Rows or metadata survived rollback");check(db.assistantRevision()==revision,"Rollback advanced revision");check(db.backups.entries().size()==1,"Pre-change backup missing");
            db.saveChecked(changed,()->{});check(db.load().getJSONObject("settings").getInt("minimumScheduleUnit")!=old,"Confirmed change missing");check(db.assistantRevision()>revision,"Successful commit didn't advance revision");
            result.putString("stream","PASS "+checks+" isolated assistant SQLite checks; no API or user workspace accessed\n");finish(-1,result);
        }catch(Throwable error){result.putString("stream","FAIL: "+error.getClass().getSimpleName());finish(1,result);}
        finally{db.close();context.deleteDatabase(name);File[] files=db.backups.directory.listFiles();if(files!=null)for(File file:files)file.delete();db.backups.directory.delete();}
    }
}
