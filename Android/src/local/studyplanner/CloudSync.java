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

/** Independent cloud sync; hotspot pairing, tokens and cursors are never reused. */
final class CloudSync {
    static final String ACTION="local.studyplanner.CLOUD_STATUS";
    static final int JOB=878701;
    private static CloudSync instance;
    final Context context;final PlannerDatabase database;
    final ScheduledExecutorService network=Executors.newSingleThreadScheduledExecutor(r->new Thread(r,"planner-cloud"));
    final CloudOperationGate gate=new CloudOperationGate();
    boolean again=false,monitoring=false;int failures=0;ScheduledFuture<?> retry;
    final List<Consumer<Boolean>> callbacks=new ArrayList<>();
    private CloudSync(Context c){context=c.getApplicationContext();database=PlannerRuntime.get(context).database;}
    static synchronized CloudSync get(Context c){if(instance==null)instance=new CloudSync(c);return instance;}
    synchronized boolean isRunning(){return gate.isActive(CloudOperationGate.Operation.SYNC);}
    synchronized boolean beginConfiguration(){return gate.begin(CloudOperationGate.Operation.CONFIGURATION);}
    synchronized void finishConfiguration(boolean success){
        gate.finish(CloudOperationGate.Operation.CONFIGURATION);again=false;
        if(success){
            failures=0;if(retry!=null){retry.cancel(false);retry=null;}
            if(!CloudSettings.enabled(context))status("云同步已暂停，待上传文件已保留");
        }
        if(!success||!CloudSettings.enabled(context)){
            List<Consumer<Boolean>> done=new ArrayList<>(callbacks);callbacks.clear();
            for(Consumer<Boolean> callback:done)new Handler(Looper.getMainLooper()).post(()->callback.accept(success));
        }
        if(success)start();
    }
    static File outbox(Context c){return new File(c.getFilesDir(),"cloud-outbox");}
    static void enqueue(Context c,SyncLedger ledger)throws Exception{
        CloudOutbox.enqueue(outbox(c),ledger);
    }
    static String summary(Context c){SharedPreferences p=c.getSharedPreferences(CloudSettings.PREFS,0);return p.getString("status",CloudSettings.enabled(c)?"等待同步":"尚未启用云同步");}
    void status(String text){status(text,false);}
    void status(String text,boolean changed){context.getSharedPreferences(CloudSettings.PREFS,0).edit().putString("status",text).apply();context.sendBroadcast(new Intent(ACTION).setPackage(context.getPackageName()).putExtra("changed",changed));}
    synchronized void start(){
        JobScheduler scheduler=(JobScheduler)context.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        if(!CloudSettings.enabled(context)){scheduler.cancel(JOB);return;}
        scheduler.schedule(new JobInfo.Builder(JOB,new ComponentName(context,CloudSyncJob.class)).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPeriodic(3600000).setPersisted(true).build());
        if(!monitoring){monitoring=true;ConnectivityManager connectivity=(ConnectivityManager)context.getSystemService(Context.CONNECTIVITY_SERVICE);
            connectivity.registerDefaultNetworkCallback(new ConnectivityManager.NetworkCallback(){public void onAvailable(Network n){request(null);}});}
        request(null);
    }
    synchronized void request(Consumer<Boolean> completion){
        if(gate.isActive(CloudOperationGate.Operation.CONFIGURATION)){
            if(completion!=null)callbacks.add(completion);return;
        }
        if(!CloudSettings.enabled(context)){if(completion!=null)completion.accept(true);return;}
        if(completion!=null)callbacks.add(completion);
        if(!gate.begin(CloudOperationGate.Operation.SYNC)){again=true;return;}status("正在同步完整课表…");
        network.execute(()->{
            boolean success=false;
            try{sync();success=true;failures=0;synchronized(this){if(retry!=null){retry.cancel(false);retry=null;}}}catch(Exception e){
                status(e instanceof IllegalStateException?e.getMessage():"云同步未完成，待传数据已保留。请检查网络、所选连接方式及服务访问码。",true);
                synchronized(this){if(retry!=null)retry.cancel(false);long delay=Math.min(1800,30L<<Math.min(failures++,6));retry=network.schedule(()->request(null),delay,TimeUnit.SECONDS);}
            }
            List<Consumer<Boolean>> done;boolean repeat;
            synchronized(this){gate.finish(CloudOperationGate.Operation.SYNC);repeat=again;again=false;done=new ArrayList<>(callbacks);callbacks.clear();}
            context.sendBroadcast(new Intent(ACTION).setPackage(context.getPackageName()));
            final boolean ok=success;for(Consumer<Boolean> callback:done)new Handler(Looper.getMainLooper()).post(()->callback.accept(ok));
            if(repeat)request(null);
        });
    }
    static void checkStatus(JSONObject result)throws Exception{
        CloudSyncEngine.checkStatus(result);
    }
    void sync()throws Exception{
        if(!database.initialized())return;
        boolean ssh="ssh".equals(CloudSettings.method(context));
        CloudSSHConfig config=ssh?CloudSettings.ssh(context):null;
        String identityEndpoint=ssh?config.identity():CloudSettings.validateEndpoint(CloudSettings.endpoint(context));
        String token=CloudSettings.token(context);CloudSettings.validateToken(token);
        if(token.isEmpty())throw new IOException("尚未配置访问码");
        try(CloudSSHTunnel tunnel=ssh?CloudSSHTunnel.open(config):null){
        String endpoint=tunnel==null?identityEndpoint:tunnel.endpoint;
        CloudSyncEngine.Store store=new CloudSyncEngine.Store(){
            public SyncLedger read()throws Exception{return database.ledger();}
            public boolean commit(SyncLedger candidate,JSONObject checkpoint,boolean replace)throws Exception{
                synchronized(database){
                    if(!database.commitCloud(candidate,checkpoint,replace))return false;
                    CompressedPreviewStore.receive(context,candidate.materialize());
                    return true;
                }
            }
        };
        CloudSyncEngine.Remote remote=new CloudSyncEngine.Remote(){
            public JSONObject status()throws Exception{return json(endpoint,token,"status",null);}
            public JSONObject upload(File file)throws Exception{return json(endpoint,token,"snapshot",file);}
            public CloudSnapshot latest()throws Exception{
                HttpURLConnection connection=connection(endpoint,token,"latest");
                try{if(connection.getResponseCode()!=200)throw new IOException("云端下载失败");try(InputStream in=connection.getInputStream()){return CloudSnapshot.read(in);}}
                finally{connection.disconnect();}
            }
        };
        CloudSyncEngine.Result result=new CloudSyncEngine(store,remote,outbox(context),identityEndpoint,Planner::now,this::status).sync();
        if(result.again&&!result.changed)status("手机日程已有新修改，正在重新核对云端…");
        else status((result.replaced?"已备份手机原课表并更新":"已同步")+" · 云端版本 "+result.revision+" · "+java.time.LocalTime.now(Planner.ZONE).withSecond(0).withNano(0),result.changed);
        if(result.again){synchronized(this){again=true;}}
        }
    }
    static HttpURLConnection connection(String endpoint,String token,String path)throws Exception{
        URL target=new URL(endpoint+"/cloud/"+path);
        if(!"https".equals(target.getProtocol())&&!("http".equals(target.getProtocol())&&"127.0.0.1".equals(target.getHost())&&target.getPort()>0))throw new IOException("只允许 HTTPS 或内部 SSH 转发");
        HttpURLConnection c=(HttpURLConnection)("http".equals(target.getProtocol())?target.openConnection(java.net.Proxy.NO_PROXY):target.openConnection());
        c.setConnectTimeout(15000);c.setReadTimeout(30000);c.setInstanceFollowRedirects(false);c.setUseCaches(false);c.setRequestProperty("Authorization","Bearer "+token);return c;
    }
    static JSONObject json(String endpoint,String token,String path,File upload)throws Exception{
        HttpURLConnection c=connection(endpoint,token,path);
        try{
            if(upload!=null){if(upload.length()>CloudSnapshot.MAX_GZIP)throw new IOException("完整压缩数据包超过32MB");c.setRequestMethod("POST");c.setDoOutput(true);c.setFixedLengthStreamingMode(upload.length());c.setRequestProperty("Content-Type","application/gzip");
                try(InputStream in=new FileInputStream(upload);OutputStream out=c.getOutputStream()){byte[] b=new byte[8192];for(int n;(n=in.read(b))!=-1;)out.write(b,0,n);}}
            if(c.getResponseCode()!=200)throw new IOException("云端请求失败");
            try(InputStream in=new CloudSnapshot.LimitedInput(c.getInputStream(),65536);ByteArrayOutputStream out=new ByteArrayOutputStream()){
                byte[] b=new byte[8192];for(int n;(n=in.read(b))!=-1;)out.write(b,0,n);return new JSONObject(new String(out.toByteArray(),StandardCharsets.UTF_8));}
        }finally{c.disconnect();}
    }
}
