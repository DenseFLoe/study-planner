package local.studyplanner;
import android.content.*;
import java.util.function.Consumer;

/** Activity facade. Only an eligible foreground event or explicit button starts a window. */
final class SyncWindow {
    private final Context context;private final Consumer<String> status;
    SyncWindow(Context context,Consumer<String> status){this.context=context;this.status=status;}
    boolean isRunning(){return SyncWindowService.running();}
    String pairingText(){return SyncWindowService.pairing();}
    void start(boolean pairing,boolean manual){
        if(isRunning()){if(manual)status.accept("接收窗口已开启，请在 Mac 同步；切换应用不会重置两分钟期限");return;}
        SharedPreferences prefs=context.getSharedPreferences("local-sync",0);
        if(!manual&&(java.time.LocalDate.now(Planner.ZONE).toString().equals(prefs.getString("autoDate",""))||System.currentTimeMillis()-prefs.getLong("lastWindow",0)<1800000||!prefs.contains("tokenHash")))return;
        try{context.startForegroundService(new Intent(context,SyncWindowService.class).putExtra("pairing",pairing).putExtra("manual",manual));}
        catch(RuntimeException error){status.accept("接收窗口未开启："+error.getClass().getSimpleName()+"。请回到应用前台重试。");}
    }
    void close(){context.stopService(new Intent(context,SyncWindowService.class));}
}
