package local.studyplanner;

import android.app.job.*;
import android.content.*;
import android.net.*;
import android.os.*;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;
import javax.net.ssl.HttpsURLConnection;

/** Independent cloud sync; hotspot pairing, tokens and cursors are never reused. */
final class CloudSync {
    static final String ACTION="local.studyplanner.CLOUD_STATUS";
    static final int JOB=878701;
    private static CloudSync instance;
    final Context context;final PlannerDatabase database;
    final ScheduledExecutorService network=Executors.newSingleThreadScheduledExecutor(r->new Thread(r,"planner-cloud"));
    boolean running=false,again=false,monitoring=false;int failures=0;ScheduledFuture<?> retry;
    final List<Consumer<Boolean>> callbacks=new ArrayList<>();
    private CloudSync(Context c){context=c.getApplicationContext();database=PlannerRuntime.get(context).database;}
    static synchronized CloudSync get(Context c){if(instance==null)instance=new CloudSync(c);return instance;}
    synchronized boolean isRunning(){return running;}
    static File outbox(Context c){return new File(c.getFilesDir(),"cloud-outbox");}
    static void enqueue(Context c,SyncLedger ledger)throws Exception{
        File directory=outbox(c);if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("无法创建待上传目录");
        File destination=new File(directory,ledger.value.getString("device")+"-"+ledger.sequence()+".json.gz");
        if(destination.exists())return;
        File temporary=File.createTempFile(".pending-",".tmp",directory);
        try{try(OutputStream out=new FileOutputStream(temporary)){CloudSnapshot.write(out,ledger,CloudSnapshot.header(ledger));}
            if(!temporary.renameTo(destination))throw new IOException("无法保存待上传文件");
        }finally{temporary.delete();}
    }
    static String summary(Context c){SharedPreferences p=c.getSharedPreferences(CloudSettings.PREFS,0);return p.getString("status",CloudSettings.enabled(c)?"等待同步":"尚未启用云同步");}
    void status(String text){context.getSharedPreferences(CloudSettings.PREFS,0).edit().putString("status",text).apply();context.sendBroadcast(new Intent(ACTION).setPackage(context.getPackageName()));}
    synchronized void start(){
        JobScheduler scheduler=(JobScheduler)context.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        if(!CloudSettings.enabled(context)){scheduler.cancel(JOB);return;}
        scheduler.schedule(new JobInfo.Builder(JOB,new ComponentName(context,CloudSyncJob.class)).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPeriodic(3600000).setPersisted(true).build());
        if(!monitoring){monitoring=true;ConnectivityManager connectivity=(ConnectivityManager)context.getSystemService(Context.CONNECTIVITY_SERVICE);
            connectivity.registerDefaultNetworkCallback(new ConnectivityManager.NetworkCallback(){public void onAvailable(Network n){request(null);}});}
        request(null);
    }
    synchronized void request(Consumer<Boolean> completion){
        if(!CloudSettings.enabled(context)){if(completion!=null)completion.accept(true);return;}
        if(completion!=null)callbacks.add(completion);
        if(running){again=true;return;}running=true;
        network.execute(()->{
            boolean success=false;
            try{sync();success=true;failures=0;synchronized(this){if(retry!=null){retry.cancel(false);retry=null;}}}catch(Exception e){
                status(e instanceof IllegalStateException?e.getMessage():"云同步未完成，待传数据已保留。请检查网络、HTTPS 证书及服务访问码。");
                synchronized(this){if(retry!=null)retry.cancel(false);long delay=Math.min(1800,30L<<Math.min(failures++,6));retry=network.schedule(()->request(null),delay,TimeUnit.SECONDS);}
            }
            List<Consumer<Boolean>> done;boolean repeat;
            synchronized(this){running=false;repeat=again;again=false;done=new ArrayList<>(callbacks);callbacks.clear();}
            final boolean ok=success;for(Consumer<Boolean> callback:done)new Handler(Looper.getMainLooper()).post(()->callback.accept(ok));
            if(repeat)request(null);
        });
    }
    static void checkStatus(JSONObject result)throws Exception{
        if(result.getInt("format")!=1||!CloudSnapshot.validID(result.getString("serverID"))||result.getLong("revision")<0)throw new IOException("云端响应无效");
    }
    void sync()throws Exception{
        if(!database.initialized())return;
        String endpoint=CloudSettings.validateEndpoint(CloudSettings.endpoint(context)),token=CloudSettings.token(context);
        if(token.isEmpty())throw new IOException("尚未配置访问码");
        SyncLedger initial=database.ledger();long sequence=initial.sequence();JSONObject progress=initial.value.optJSONObject("cloudProgress");
        if(progress!=null&&!endpoint.equals(progress.optString("endpoint")))progress=null;
        JSONObject remote=json(endpoint,token,"status",null);checkStatus(remote);String identity=remote.getString("serverID");
        if(progress!=null&&(!identity.equals(progress.optString("serverID"))||remote.getLong("revision")<progress.optLong("revision")))throw new IllegalStateException("云端身份或版本变化，待传数据已保留。请核对服务器后重新保存云同步配置。");
        if(progress==null||progress.optLong("uploadedSequence",-1)!=sequence)enqueue(context,initial);
        File[] queued=outbox(context).listFiles((dir,name)->name.endsWith(".json.gz"));if(queued==null)queued=new File[0];
        Arrays.sort(queued,Comparator.comparingLong(File::lastModified).thenComparing(File::getName));
        for(File file:queued){JSONObject reply=json(endpoint,token,"snapshot",file);checkStatus(reply);
            if(!identity.equals(reply.getString("serverID"))||reply.getLong("revision")<remote.getLong("revision"))throw new IOException("云端身份或版本变化");remote=reply;}
        CloudSnapshot archive=null;
        if(queued.length>0||progress==null||progress.optLong("revision")!=remote.getLong("revision")){
            HttpsURLConnection connection=connection(endpoint,token,"latest");
            try{if(connection.getResponseCode()!=200)throw new IOException("云端下载失败");try(InputStream in=connection.getInputStream()){archive=CloudSnapshot.read(in);}}
            finally{connection.disconnect();}
            if(!identity.equals(archive.header.getString("serverID"))||archive.header.getLong("revision")<remote.getLong("revision"))throw new IOException("云端版本无效");
            remote.put("revision",archive.header.getLong("revision"));
        }
        boolean dirty;
        synchronized(database){
            SyncLedger current=database.ledger();dirty=current.sequence()!=sequence;
            if(archive!=null)current.merge(archive.ledger.changes(0));
            JSONObject state=current.materialize();current.capture(state);
            current.value.put("cloudProgress",new JSONObject().put("endpoint",endpoint).put("serverID",identity).put("revision",remote.getLong("revision"))
                .put("uploadedSequence",dirty?-1:current.sequence()).put("lastSuccess",System.currentTimeMillis()/1000.0));
            database.commit(current,false);
        }
        for(File file:queued)if(!file.delete()&&file.exists())throw new IOException("无法清理已上传文件");
        status("已同步 · 云端版本 "+remote.getLong("revision")+" · "+java.time.LocalTime.now(Planner.ZONE).withSecond(0).withNano(0));
        if(dirty){synchronized(this){again=true;}}
    }
    static HttpsURLConnection connection(String endpoint,String token,String path)throws Exception{
        HttpsURLConnection c=(HttpsURLConnection)new URL(endpoint+"/cloud/"+path).openConnection();
        c.setConnectTimeout(15000);c.setReadTimeout(30000);c.setInstanceFollowRedirects(false);c.setUseCaches(false);c.setRequestProperty("Authorization","Bearer "+token);return c;
    }
    static JSONObject json(String endpoint,String token,String path,File upload)throws Exception{
        HttpsURLConnection c=connection(endpoint,token,path);
        try{
            if(upload!=null){if(upload.length()>CloudSnapshot.MAX_GZIP)throw new IOException("完整压缩数据包超过32MB");c.setRequestMethod("POST");c.setDoOutput(true);c.setFixedLengthStreamingMode(upload.length());c.setRequestProperty("Content-Type","application/gzip");
                try(InputStream in=new FileInputStream(upload);OutputStream out=c.getOutputStream()){byte[] b=new byte[8192];for(int n;(n=in.read(b))!=-1;)out.write(b,0,n);}}
            if(c.getResponseCode()!=200)throw new IOException("云端请求失败");
            try(InputStream in=new CloudSnapshot.LimitedInput(c.getInputStream(),65536);ByteArrayOutputStream out=new ByteArrayOutputStream()){
                byte[] b=new byte[8192];for(int n;(n=in.read(b))!=-1;)out.write(b,0,n);return new JSONObject(new String(out.toByteArray(),StandardCharsets.UTF_8));}
        }finally{c.disconnect();}
    }
}
