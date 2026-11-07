package local.studyplanner;

import android.app.Instrumentation;
import android.content.Intent;
import android.os.Bundle;
import org.json.*;
import java.io.File;
import java.lang.reflect.Field;
import java.util.Collections;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;

/** Packaged native UI smoke test with a disposable workspace and no real credentials, planner or API. */
public final class AssistantStartupInstrumentation extends Instrumentation {
    int checks;AssistantActivity activity;
    void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    boolean onMain(BooleanSupplier condition){AtomicBoolean result=new AtomicBoolean();runOnMainSync(()->result.set(condition.getAsBoolean()));return result.get();}
    void await(BooleanSupplier condition)throws Exception{
        long end=System.nanoTime()+TimeUnit.SECONDS.toNanos(10);
        while(System.nanoTime()<end){if(onMain(condition))return;Thread.sleep(25);}
        throw new AssertionError("Native assistant startup timed out");
    }
    void open()throws Exception{
        activity=(AssistantActivity)startActivitySync(new Intent(getTargetContext(),AssistantActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        await(()->activity.state!=null&&activity.state.ready&&activity.apiButton.isEnabled());
    }
    void close()throws Exception{AssistantActivity closing=activity;runOnMainSync(closing::finish);await(closing::isDestroyed);activity=null;}
    static void delete(File file){File[] files=file.listFiles();if(files!=null)for(File child:files)delete(child);file.delete();}
    public void onCreate(Bundle args){super.onCreate(args);start();}
    public void onStart(){
        Bundle result=new Bundle();int code=-1;File isolated=new File(getTargetContext().getFilesDir(),"assistant-startup-test-"+System.nanoTime());
        AssistantSession session=null;Field shared=null;Object previous=null;boolean injected=false;
        try{
            if(!isolated.mkdirs())throw new AssertionError("Cannot create isolated workspace");
            AssistantProtocol.Contract contract=new AssistantProtocol.Contract(new JSONObject(AssistantProtocol.read(getTargetContext().getAssets().open("assistant-contract.json"),100000)));
            AssistantHistory history=new AssistantHistory(isolated,contract);JSONObject empty=history.load();
            check(empty.getJSONArray("conversations").length()==1,"System private-data path blocked first launch");
            history.save(empty,Collections.emptySet());check(history.load().getString("selectedID").equals(empty.getString("selectedID")),"Private workspace did not roundtrip");
            JSONObject fixture=PlannerBackupFile.readLegacyState(getTargetContext().getAssets().open("initial-state.json"));AtomicInteger requests=new AtomicInteger(),writes=new AtomicInteger();
            StateMutation.Store<JSONObject> store=new StateMutation.Store<JSONObject>(){
                public JSONObject load()throws Exception{return CourseTools.copy(fixture);}
                public void save(JSONObject value){writes.incrementAndGet();throw new AssertionError("Startup changed schedule");}
            };
            session=new AssistantSession(history,store,(request,key,token)->{requests.incrementAndGet();throw new AssertionError("Startup called API");},()->{});
            shared=AssistantActivity.class.getDeclaredField("shared");shared.setAccessible(true);
            synchronized(AssistantActivity.class){previous=shared.get(null);shared.set(null,session);injected=true;}
            open();
            check(onMain(()->activity.send.isEnabled()&&activity.newButton.isEnabled()&&activity.historyButton.isEnabled()&&activity.memoryButton.isEnabled()),"First-launch buttons stayed disabled without a key");
            runOnMainSync(()->activity.newButton.performClick());await(()->activity.state.workspace.optJSONArray("conversations").length()==2);
            check(history.load().getJSONArray("conversations").length()==2,"Native new-conversation button did not save");
            close();open();check(onMain(()->activity.apiButton.isEnabled()&&activity.state.workspace.optJSONArray("conversations").length()==2),"Reopened assistant stayed disabled or lost history");
            check(requests.get()==0&&writes.get()==0,"Startup touched API or planner");
            result.putString("stream","PASS "+checks+" isolated assistant startup/native button checks; no API, credentials or user workspace accessed\n");
        }catch(Throwable error){code=1;result.putString("stream","FAIL: "+error.getClass().getSimpleName());}
        finally{
            if(activity!=null)try{close();}catch(Exception ignored){}
            if(session!=null){try{session.queue.submit(()->{}).get(10,TimeUnit.SECONDS);}catch(Exception ignored){}session.queue.shutdownNow();session.network.shutdownNow();}
            if(injected)try{synchronized(AssistantActivity.class){shared.set(null,previous);}}catch(Exception ignored){}
            delete(isolated);
        }
        finish(code,result);
    }
}
