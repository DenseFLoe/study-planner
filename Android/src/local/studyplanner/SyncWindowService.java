package local.studyplanner;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.os.*;

/** Visible, non-sticky, at most two minutes. Switching apps must not invalidate a pairing code. */
public final class SyncWindowService extends Service {
    static final String ACTION_STATUS="local.studyplanner.SYNC_STATUS";
    static final String ACTION_STOP="local.studyplanner.SYNC_STOP";
    private static final String CHANNEL="sync-window";
    private static final int NOTIFICATION=8765;
    private static volatile SyncWindowService active;
    static volatile String lastStatus="尚未同步";
    private SyncServer server;
    private final Handler main=new Handler(Looper.getMainLooper());
    private boolean stopping=false,started=false;
    private final Runnable timeout=()->{lastStatus="接收窗口已到期，请按需重新开启";stopSelf();};
    static boolean exists(){return active!=null;}
    static boolean running(){SyncWindowService s=active;return s!=null&&s.server!=null&&s.server.isRunning();}
    static String pairing(){SyncWindowService s=active;return s==null||s.server==null?"":s.server.pairingText();}
    @Override public void onCreate(){
        super.onCreate();active=this;
        NotificationManager manager=getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL,"短时局域网同步",NotificationManager.IMPORTANCE_LOW));
        PlannerRuntime runtime=PlannerRuntime.get(this);
        server=new SyncServer(this,runtime.database,runtime.worker,message->main.post(()->{
            if(stopping)return;
            lastStatus=message;publish(false);
            if(!server.isRunning()){stopSelf();return;}
            if(!stopping)manager.notify(NOTIFICATION,notification());
        }),()->main.post(()->publish(true)));
    }
    @Override public int onStartCommand(Intent intent,int flags,int startId){
        if(intent==null||ACTION_STOP.equals(intent.getAction())){stopSelf();return START_NOT_STICKY;}
        if(stopping)return START_NOT_STICKY;
        if(Build.VERSION.SDK_INT>=29)startForeground(NOTIFICATION,notification(),ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        else startForeground(NOTIFICATION,notification());
        if(!started){started=true;main.postDelayed(timeout,120000);}
        server.start(intent.getBooleanExtra("pairing",false),intent.getBooleanExtra("manual",false));
        if(!server.isRunning())stopSelf();
        return START_NOT_STICKY;
    }
    private Notification notification(){
        PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        PendingIntent stop=PendingIntent.getService(this,1,new Intent(this,SyncWindowService.class).setAction(ACTION_STOP),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.stat_notify_sync).setContentTitle("学习日程 · 两分钟同步窗口")
            .setContentText("可临时切换应用；同步完成或到期后自动关闭").setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(new Notification.Action.Builder(null,"关闭窗口",stop).build()).build();
    }
    private void publish(boolean changed){sendBroadcast(new Intent(ACTION_STATUS).setPackage(getPackageName()).putExtra("changed",changed));}
    @Override public void onTimeout(int startId,int type){stopSelf();}
    @Override public void onTaskRemoved(Intent rootIntent){stopSelf();}
    @Override public void onDestroy(){
        stopping=true;main.removeCallbacksAndMessages(null);server.close();
        main.removeCallbacksAndMessages(null);
        lastStatus=(lastStatus.contains("失败")||lastStatus.contains("到期"))?lastStatus+"；网络已关闭":"网络模块已关闭，无活动接收窗口";
        if(active==this)active=null;publish(false);stopForeground(STOP_FOREGROUND_REMOVE);super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent){return null;}
}
