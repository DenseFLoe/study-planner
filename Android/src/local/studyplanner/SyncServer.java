package local.studyplanner;

import android.content.*;
import android.security.keystore.*;
import org.json.*;
import javax.net.ssl.*;
import javax.security.auth.x500.X500Principal;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.X509Certificate;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;

/** A finite HTTPS window. No service, discovery, polling or wake lock survives it. */
public final class SyncServer implements AutoCloseable {
    private static final String ALIAS="planner-sync-tls-v1";
    private final Context context;private final PlannerDatabase db;private final ExecutorService databaseWorker;
    private final Consumer<String> notice;private final Runnable changed;private final SharedPreferences prefs;
    private volatile boolean running;private volatile ServerSocket listener;private volatile Socket active;
    private ScheduledExecutorService deadline;private String code="",pairingText="",session="",sessionDate="";private boolean sessionAuto;
    private String lastFailure="";private int attempts;private Thread thread;private final int windowSeconds;
    public SyncServer(Context c,PlannerDatabase d,ExecutorService worker,Consumer<String> notice,Runnable changed){this(c,d,worker,notice,changed,120);}
    SyncServer(Context c,PlannerDatabase d,ExecutorService worker,Consumer<String> notice,Runnable changed,int seconds){context=c;db=d;databaseWorker=worker;this.notice=notice;this.changed=changed;windowSeconds=seconds;prefs=c.getSharedPreferences("local-sync",0);}
    public boolean isRunning(){return running;}
    public synchronized String pairingText(){return pairingText;}
    private void log(String text){android.util.Log.i("PlannerSync",text);try{File f=new File(context.getFilesDir(),"sync.log");if(f.length()>131072)try(FileOutputStream clear=new FileOutputStream(f)){clear.write(new byte[0]);}try(FileOutputStream out=new FileOutputStream(f,true)){out.write((new Date()+" "+text+"\n").getBytes(StandardCharsets.UTF_8));}}catch(Exception ignored){}notice.accept(text);}
    public synchronized void start(boolean pairing,boolean manual){
        if(running || (thread!=null && thread.isAlive())){notice.accept("接收窗口已开启，请在 Mac 点击立即同步");return;}
        String today=java.time.LocalDate.now(Planner.ZONE).toString();long now=System.currentTimeMillis();
        if(!manual&&(today.equals(prefs.getString("autoDate",""))||now-prefs.getLong("lastWindow",0)<1800000||!prefs.contains("tokenHash")))return;
        if(!prefs.edit().putLong("lastWindow",now).commit()){notice.accept("无法保存同步状态");return;}
        running=true;lastFailure="";attempts=0;session="";code="";pairingText="";
        boolean needsPairing=pairing||!prefs.contains("tokenHash");
        thread=new Thread(()->serve(needsPairing),"planner-sync-window");thread.start();
    }
    private void serve(boolean pairing){
        try{
            SSLContext ssl=tls();ServerSocket socket=ssl.getServerSocketFactory().createServerSocket();
            synchronized(this){if(!running){socket.close();return;}socket.setReuseAddress(true);socket.bind(new InetSocketAddress(8765));listener=socket;deadline=Executors.newSingleThreadScheduledExecutor(r->new Thread(r,"planner-sync-deadline"));deadline.schedule(this::close,windowSeconds,TimeUnit.SECONDS);
                if(pairing){code=String.format(Locale.ROOT,"%08d",new SecureRandom().nextInt(100000000));pairingText=code+"."+fingerprint();}}
            log(pairing?"配对窗口已开启（120 秒）":"等待 Mac 同步（120 秒）；端口 8765");
            while(running){try(Socket connection=socket.accept()){
                active=connection;connection.setSoTimeout(10000);((SSLSocket)connection).setEnabledProtocols(new String[]{"TLSv1.2"});((SSLSocket)connection).startHandshake();
                Request request=read(connection.getInputStream());JSONObject result;boolean finish=false;
                try{
                    if(request.path.equals("/sync/pair")&&request.method.equals("POST"))result=pair(request.body);
                    else {authenticate(request.token);switch(request.path){
                        case "/sync/cancel":finish=true;result=new JSONObject().put("ok",true);listener.close();break;
                        case "/sync/status":if(!request.method.equals("GET"))throw new IOException("方法无效");result=new JSONObject().put("protocol",1).put("listening",true);break;
                        case "/sync/changes":
                            if(!request.method.equals("POST"))throw new IOException("方法无效");
                            sessionAuto=request.body.getBoolean("automatic");sessionDate=request.body.getString("date");
                            if(!sessionDate.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}"))throw new IOException("日期无效");
                            log((sessionAuto?"自动":"手动")+"同步开始；接收 "+request.body.getJSONArray("changes").length()+" 条变化");
                            result=databaseWorker.submit(()->{JSONObject response=db.exchange(request.body);changed.run();return response;}).get();
                            log(result.optString("applied"));session=UUID.randomUUID().toString();result.put("session",session);log("已提交接收变化；发送 "+result.getJSONArray("changes").length()+" 条变化");break;
                        case "/sync/finish":
                            if(!request.method.equals("POST")||session.isEmpty()||!session.equals(request.body.optString("session")))throw new RequestFailure("session_invalid","会话无效");
                            sessionDate=java.time.LocalDate.now(Planner.ZONE).toString();
                            databaseWorker.submit(()->{db.finish(sessionAuto,sessionDate);changed.run();return true;}).get();
                            if(sessionAuto&&!prefs.edit().putString("autoDate",sessionDate).commit())throw new IOException("无法保存自动同步日期");
                            session="";finish=true;result=new JSONObject().put("ok",true);listener.close();log("同步完成，停止监听");break;
                        default:throw new IOException("路径无效");}}
                    respond(connection,200,result);
                }catch(Exception e){
                    String errorCode=e instanceof RequestFailure?((RequestFailure)e).code:"data_rejected";
                    respond(connection,errorCode.equals("unauthorized")?401:400,new JSONObject().put("code",errorCode).put("error","请求未完成，请查看手机同步日志"));throw e;
                }
                if(finish)break;
            }finally{active=null;}}
        }catch(Exception e){if(running){lastFailure="同步失败："+safe(e);log(lastFailure);}}
        finally{close();}
    }
    private static String safe(Exception e){Throwable t=e instanceof ExecutionException&&e.getCause()!=null?e.getCause():e;return t.getClass().getSimpleName()+": "+(t.getMessage()==null?"连接结束":t.getMessage());}
    private synchronized JSONObject pair(JSONObject body)throws Exception{
        if(code.isEmpty())throw new RequestFailure("pairing_closed","未开启配对窗口或配对码已经使用；请重新开启配对");
        if(++attempts>5||!MessageDigest.isEqual(code.getBytes(StandardCharsets.UTF_8),body.optString("code").getBytes(StandardCharsets.UTF_8)))throw new RequestFailure("pairing_mismatch","配对码不匹配，请使用本次窗口生成的新码");
        byte[] random=new byte[32];new SecureRandom().nextBytes(random);String token=Base64.getEncoder().encodeToString(random);
        if(!prefs.edit().putString("tokenHash",hash(token.getBytes(StandardCharsets.UTF_8))).remove("autoDate").commit())throw new IOException("配对保存失败");
        code="";pairingText="";log("配对成功");return new JSONObject().put("token",token).put("device",db.ledger().value.getString("device"));
    }
    private void authenticate(String token)throws Exception{
        String expected=prefs.getString("tokenHash","");if(expected.isEmpty()||!MessageDigest.isEqual(expected.getBytes(StandardCharsets.UTF_8),hash(token.getBytes(StandardCharsets.UTF_8)).getBytes(StandardCharsets.UTF_8)))throw new RequestFailure("unauthorized","配对凭据失效，请重新配对");
    }
    private static String hash(byte[] data)throws Exception{StringBuilder b=new StringBuilder();for(byte v:MessageDigest.getInstance("SHA-256").digest(data))b.append(String.format(Locale.ROOT,"%02x",v&255));return b.toString();}
    private String fingerprint()throws Exception{KeyStore ks=KeyStore.getInstance("AndroidKeyStore");ks.load(null);return hash(ks.getCertificate(ALIAS).getEncoded());}
    private SSLContext tls()throws Exception{
        KeyStore ks=KeyStore.getInstance("AndroidKeyStore");ks.load(null);
        if(!ks.containsAlias(ALIAS)){KeyPairGenerator g=KeyPairGenerator.getInstance("RSA","AndroidKeyStore");g.initialize(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_SIGN|KeyProperties.PURPOSE_DECRYPT).setKeySize(2048).setDigests(KeyProperties.DIGEST_NONE,KeyProperties.DIGEST_SHA256,KeyProperties.DIGEST_SHA384,KeyProperties.DIGEST_SHA512).setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1,KeyProperties.SIGNATURE_PADDING_RSA_PSS).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1,KeyProperties.ENCRYPTION_PADDING_NONE).setCertificateSubject(new X500Principal("CN=StudyPlanner Local Sync")).setCertificateNotAfter(new Date(System.currentTimeMillis()+10L*365*86400000)).build());g.generateKeyPair();}
        PrivateKey privateKey=(PrivateKey)ks.getKey(ALIAS,null);X509Certificate certificate=(X509Certificate)ks.getCertificate(ALIAS);
        X509ExtendedKeyManager manager=new X509ExtendedKeyManager(){
            public String[] getClientAliases(String k,Principal[] i){return null;}public String chooseClientAlias(String[] k,Principal[] i,Socket s){return null;}
            public String[] getServerAliases(String k,Principal[] i){return k.equals("RSA")?new String[]{ALIAS}:null;}public String chooseServerAlias(String k,Principal[] i,Socket s){return k.equals("RSA")?ALIAS:null;}
            public X509Certificate[] getCertificateChain(String a){return new X509Certificate[]{certificate};}public PrivateKey getPrivateKey(String a){return privateKey;}
        };
        SSLContext ssl=SSLContext.getInstance("TLSv1.2");ssl.init(new KeyManager[]{manager},null,new SecureRandom());return ssl;
    }
    public synchronized void close(){
        if(!running)return;running=false;code="";pairingText="";
        try{if(listener!=null)listener.close();}catch(IOException ignored){}try{if(active!=null)active.close();}catch(IOException ignored){}
        listener=null;active=null;if(deadline!=null){deadline.shutdownNow();deadline=null;}
        log((lastFailure.isEmpty()?"":lastFailure+"；")+"网络模块关闭：监听 0，连接 0，同步定时任务 0");
    }
    private static final class RequestFailure extends IOException {
        final String code;RequestFailure(String code,String message){super(message);this.code=code;}
    }
    private static final class Request{String method,path,token="";JSONObject body=new JSONObject();}
    private static String line(InputStream in)throws IOException{ByteArrayOutputStream out=new ByteArrayOutputStream();int b;while((b=in.read())!=-1){if(b=='\n')return out.toString("US-ASCII").replace("\r","");if(out.size()>=8192)throw new IOException("请求头过长");out.write(b);}throw new EOFException();}
    private static Request read(InputStream in)throws Exception{
        Request r=new Request();String[] first=line(in).split(" ");if(first.length!=3)throw new IOException("请求无效");r.method=first[0];r.path=first[1];int size=0,total=0;boolean lengthSeen=false;
        for(String l;!(l=line(in)).isEmpty();){total+=l.length();if(total>16384)throw new IOException("请求头过长");int colon=l.indexOf(':');if(colon<0)throw new IOException("请求头无效");String k=l.substring(0,colon).toLowerCase(Locale.ROOT),v=l.substring(colon+1).trim();if(k.equals("content-length")){if(lengthSeen)throw new IOException("重复长度");lengthSeen=true;size=Integer.parseInt(v);}if(k.equals("transfer-encoding"))throw new IOException("不支持分块请求");if(k.equals("authorization")&&v.startsWith("Bearer "))r.token=v.substring(7);}
        if(size<0||size>16*1024*1024)throw new IOException("同步批次过大");byte[] b=new byte[size];new DataInputStream(in).readFully(b);if(size>0)r.body=new JSONObject(new String(b,StandardCharsets.UTF_8));return r;
    }
    private static void respond(Socket s,int status,JSONObject body)throws Exception{byte[] bytes=body.toString().getBytes(StandardCharsets.UTF_8);if(bytes.length>16*1024*1024)throw new IOException("响应过大");OutputStream out=s.getOutputStream();out.write(("HTTP/1.1 "+status+(status==200?" OK":" Bad Request")+"\r\nContent-Type: application/json\r\nContent-Length: "+bytes.length+"\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n").getBytes(StandardCharsets.US_ASCII));out.write(bytes);out.flush();}
}
