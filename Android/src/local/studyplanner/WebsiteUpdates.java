package local.studyplanner;

import android.app.job.*;
import android.content.*;
import android.os.*;
import java.util.*;

final class WebsiteUpdates {
    static final int JOB=878702;
    static boolean checking;
    static void schedule(Context context){
        JobScheduler scheduler=(JobScheduler)context.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        boolean enabled=false;for(Object value:context.getSharedPreferences(WebsiteSourceSettings.PREFS,0).getAll().values())try{if(new org.json.JSONObject(value.toString()).optBoolean("enabled"))enabled=true;}catch(Exception ignored){}
        if(!enabled){scheduler.cancel(JOB);return;}
        if(scheduler.getPendingJob(JOB)==null)scheduler.schedule(new JobInfo.Builder(JOB,new ComponentName(context,WebsiteUpdateJob.class)).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPeriodic(30*60000L).setPersisted(true).build());
    }
    static void due(Context context,Runnable done){
        if(checking||WebsiteUpdateRunner.current!=null||DraftEditorDialog.openCount>0||Build.VERSION.SDK_INT<28&&CourseImportActivity.active>0){done.run();return;}
        checking=true;Context app=context.getApplicationContext();Handler main=new Handler(Looper.getMainLooper());
        PlannerRuntime.get(app).worker.execute(()->{try{List<String> ids=WebsiteSourceSettings.due(app);main.post(()->{checking=false;next(app,new ArrayDeque<>(ids),done);});}catch(Exception error){main.post(()->{checking=false;done.run();});}});
    }
    static void next(Context context,Deque<String> ids,Runnable done){
        if(ids.isEmpty()||WebsiteUpdateRunner.current!=null||DraftEditorDialog.openCount>0){done.run();return;}
        new WebsiteUpdateRunner(context,ids.removeFirst(),false,message->{},ok->new Handler(Looper.getMainLooper()).post(()->next(context,ids,done))).start(web->{});
    }
}
