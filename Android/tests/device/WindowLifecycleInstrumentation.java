package local.studyplanner;
import android.content.*;import android.app.*;import org.json.*;
import java.net.*;import java.util.concurrent.atomic.AtomicBoolean;

/** Regression for scanning a Mac pairing QR, backgrounding, then connecting from Mac. */
public final class WindowLifecycleInstrumentation extends SyncInstrumentation {
    MainActivity foreground()throws Exception{
        MainActivity activity=(MainActivity)startActivitySync(new Intent(getTargetContext(),MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        long end=System.currentTimeMillis()+5000;AtomicBoolean ready=new AtomicBoolean();
        while(System.currentTimeMillis()<end){runOnMainSync(()->ready.set(activity.ready));if(ready.get())return activity;Thread.sleep(25);}
        throw new AssertionError("Activity failed to load");
    }
    void awaitPair()throws Exception{long end=System.currentTimeMillis()+10000;while(!SyncWindowService.running()&&System.currentTimeMillis()<end)Thread.sleep(25);check(SyncWindowService.running(),"QR pairing window did not start");}
    void assertClosed()throws Exception{
        long end=System.currentTimeMillis()+5000;while(SyncWindowService.exists()&&System.currentTimeMillis()<end)Thread.sleep(25);
        check(!SyncWindowService.exists(),"foreground service remains alive");Thread.sleep(150);
        boolean refused=false;try(Socket socket=new Socket()){socket.connect(new InetSocketAddress("127.0.0.1",8765),200);}catch(java.io.IOException e){refused=true;}
        check(refused,"port remains listening");
        check(java.util.Arrays.stream(getTargetContext().getSystemService(NotificationManager.class).getActiveNotifications()).noneMatch(n->n.getId()==8765),"notification remains after cleanup");
        check(Thread.getAllStackTraces().keySet().stream().noneMatch(t->t.isAlive()&&t.getName().startsWith("planner-sync-")),"sync worker remains after cleanup");
    }
    @Override void runTests()throws Exception{
        Context target=getTargetContext();target.getSharedPreferences("local-sync",0).edit().clear().commit();
        PlannerRuntime runtime=PlannerRuntime.get(target);
        runtime.worker.submit(()->{runtime.database.save(new JSONObject(MainActivity.read(target.getAssets().open("initial-state.json"))));return true;}).get();
        String pairing=String.join("",java.util.Collections.nCopies(32,"c3"));MainActivity first=foreground();runOnMainSync(()->first.syncServer.startPairing(pairing));awaitPair();
        pin=certificatePin();runOnMainSync(()->first.moveTaskToBack(true));Thread.sleep(3000);
        check(SyncWindowService.running(),"switching apps closed the pairing window");
        token=post("pair",new JSONObject().put("code",pairing),"").getString("token");check(!token.isEmpty(),"pairing failed while Activity stopped");
        JSONObject reply=post("changes",new JSONObject().put("protocol",1).put("cursor",0).put("changes",new JSONArray()).put("automatic",false).put("date",java.time.LocalDate.now(Planner.ZONE).toString()),token);
        post("finish",new JSONObject().put("session",reply.getString("session")),token);assertClosed();runOnMainSync(first::finish);
        MainActivity second=foreground();long start=android.os.SystemClock.elapsedRealtime();runOnMainSync(()->second.syncServer.start(false,true));
        long end=System.currentTimeMillis()+5000;while(!SyncWindowService.running()&&System.currentTimeMillis()<end)Thread.sleep(20);check(SyncWindowService.running(),"manual service did not restart");runOnMainSync(()->second.moveTaskToBack(true));
        while(SyncWindowService.exists()&&android.os.SystemClock.elapsedRealtime()-start<130000)Thread.sleep(100);
        long elapsed=android.os.SystemClock.elapsedRealtime()-start;check(elapsed>=118000&&elapsed<125000,"window lifetime not bounded at 120 seconds: "+elapsed);assertClosed();runOnMainSync(second::finish);
    }
}
