package local.studyplanner;

import com.sun.net.httpserver.*;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.channels.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;

/** One personal sync space. HTTPS terminates at a reverse proxy; never publish this HTTP listener. */
public final class CloudSyncServer implements AutoCloseable {
    final Path directory;final String serverID;final byte[] tokenHash;
    final HttpServer server;final ExecutorService workers;
    final FileChannel lockChannel;final FileLock lock;
    SyncLedger ledger;long revision;Path latest;
    public CloudSyncServer(Path directory,String bind,int port,String token)throws Exception{
        if(token.length()<32||token.length()>512||token.matches(".*[\\r\\n].*"))throw new IOException("访问码必须为32至512个字符");
        this.directory=directory;Files.createDirectories(directory);tokenHash=hash(token);
        lockChannel=FileChannel.open(directory.resolve("server.lock"),StandardOpenOption.CREATE,StandardOpenOption.WRITE);
        lock=lockChannel.tryLock();if(lock==null)throw new IOException("已有服务使用此数据目录");
        try(java.util.stream.Stream<Path> paths=Files.list(directory)){
            for(Path pending:(Iterable<Path>)paths.filter(p->p.getFileName().toString().startsWith(".pending-")&&p.getFileName().toString().endsWith(".tmp"))::iterator)Files.delete(pending);
        }
        Path identity=directory.resolve("server-id");
        if(!Files.exists(identity))atomic(identity,UUID.randomUUID().toString().toUpperCase(Locale.ROOT).getBytes(StandardCharsets.UTF_8));
        serverID=new String(Files.readAllBytes(identity),StandardCharsets.UTF_8).trim();
        if(!CloudSnapshot.validID(serverID))throw new IOException("服务器身份文件损坏，已停止启动");
        List<Path> files=archives();
        if(!files.isEmpty()){
            latest=files.get(files.size()-1);CloudSnapshot saved;
            try(InputStream in=Files.newInputStream(latest)){saved=CloudSnapshot.read(in);}
            if(!serverID.equals(saved.header.getString("serverID")))throw new IOException("服务器身份不匹配");
            revision=saved.header.getLong("revision");if(!latest.getFileName().toString().equals(name(revision)))throw new IOException("版本编号无效");
            ledger=saved.ledger;ledger.value.put("device",serverID);
        }
        prune();
        server=HttpServer.create(new InetSocketAddress(bind,port),16);
        workers=new ThreadPoolExecutor(2,4,30,TimeUnit.SECONDS,new ArrayBlockingQueue<Runnable>(16),new ThreadPoolExecutor.CallerRunsPolicy());
        server.setExecutor(workers);server.createContext("/",this::handle);
    }
    public void start(){server.start();}
    public int port(){return server.getAddress().getPort();}
    static byte[] hash(String value)throws Exception{return MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));}
    static String name(long revision){return String.format(Locale.ROOT,"%020d.json.gz",revision);}
    List<Path> archives()throws IOException{
        List<Path> files=new ArrayList<>();try(java.util.stream.Stream<Path> paths=Files.list(directory)){
            paths.filter(p->p.getFileName().toString().matches("[0-9]{20}\\.json\\.gz")).forEach(files::add);
        }files.sort(Comparator.comparing(p->p.getFileName().toString()));return files;
    }
    void prune()throws IOException{List<Path> files=archives();for(int i=0;i<files.size()-10;i++)Files.delete(files.get(i));}
    static void atomic(Path destination,byte[] data)throws IOException{
        Path temporary=Files.createTempFile(destination.getParent(),".pending-",".tmp");
        try{try(FileChannel out=FileChannel.open(temporary,StandardOpenOption.WRITE)){java.nio.ByteBuffer bytes=java.nio.ByteBuffer.wrap(data);while(bytes.hasRemaining())out.write(bytes);out.force(true);}
            Files.move(temporary,destination,StandardCopyOption.ATOMIC_MOVE);
        }finally{Files.deleteIfExists(temporary);}
    }
    synchronized JSONObject status()throws Exception{prune();return new JSONObject().put("format",1).put("serverID",serverID).put("revision",revision).put("retained",archives().size());}
    synchronized JSONObject accept(CloudSnapshot incoming)throws Exception{
        // Work on an isolated candidate. Validation, file staging or disk failures never mutate the current ledger.
        SyncLedger candidate=ledger==null?new SyncLedger():new SyncLedger(SyncLedger.shallowCopy(ledger.value).put("records",SyncLedger.shallowCopy(ledger.records())));
        candidate.value.put("device",serverID);long previous=candidate.sequence();
        JSONObject old=ledger==null?null:ledger.materialize();
        candidate.merge(incoming.ledger.changes(0));
        if(ledger!=null&&candidate.sequence()==previous)return status();
        JSONObject state=candidate.materialize();double now=Planner.now();
        if((old!=null&&SyncExchange.needsReplan(old,state,now))||SyncExchange.invalidPending(state,now))Planner.replan(state,now);
        Planner.validate(state);candidate.capture(state);
        long next=revision+1;JSONObject header=CloudSnapshot.header(candidate).put("serverID",serverID).put("revision",next)
            .put("archiveID",Planner.stableID("server|"+serverID+"|"+next));
        Path temporary=Files.createTempFile(directory,".pending-",".tmp"),destination=directory.resolve(name(next));
        try{
            try(OutputStream out=Files.newOutputStream(temporary)){CloudSnapshot.write(out,candidate,header);}
            try(FileChannel channel=FileChannel.open(temporary,StandardOpenOption.WRITE)){channel.force(true);}
            Files.move(temporary,destination,StandardCopyOption.ATOMIC_MOVE);
        }finally{Files.deleteIfExists(temporary);}
        ledger=candidate;revision=next;latest=destination;
        // The new version is durable before old history is removed. A failed prune is retried on the next request/start.
        prune();return status();
    }
    void handle(HttpExchange exchange){
        try{
            String auth=exchange.getRequestHeaders().getFirst("Authorization");
            if(auth==null||!auth.startsWith("Bearer ")||!MessageDigest.isEqual(tokenHash,hash(auth.substring(7)))){json(exchange,401,new JSONObject().put("error","unauthorized"));return;}
            String path=exchange.getRequestURI().getPath(),method=exchange.getRequestMethod();
            if(path.equals("/cloud/status")&&method.equals("GET"))json(exchange,200,status());
            else if(path.equals("/cloud/snapshot")&&method.equals("POST")){
                String length=exchange.getRequestHeaders().getFirst("Content-Length");if(length!=null&&Long.parseLong(length)>CloudSnapshot.MAX_GZIP){json(exchange,413,new JSONObject().put("error","too_large"));return;}
                CloudSnapshot incoming=CloudSnapshot.read(exchange.getRequestBody());json(exchange,200,accept(incoming));
            }else if(path.equals("/cloud/latest")&&method.equals("GET"))sendArchive(exchange,null);
            else if(path.matches("/cloud/history/[0-9]{1,19}")&&method.equals("GET"))sendArchive(exchange,Long.parseLong(path.substring(path.lastIndexOf('/')+1)));
            else if(path.equals("/cloud/history")&&method.equals("GET")){
                synchronized(this){JSONArray history=new JSONArray();for(Path file:archives())history.put(new JSONObject().put("revision",Long.parseLong(file.getFileName().toString().substring(0,20))).put("bytes",Files.size(file)).put("createdAt",Files.getLastModifiedTime(file).toMillis()));
                    json(exchange,200,status().put("versions",history));}
            }else json(exchange,404,new JSONObject().put("error","not_found"));
        }catch(Exception error){try{json(exchange,400,new JSONObject().put("error","invalid_snapshot_or_storage_failure"));}catch(Exception ignored){} }
        finally{exchange.close();}
    }
    synchronized void sendArchive(HttpExchange exchange,Long requested)throws Exception{
        Path file=requested==null?latest:directory.resolve(name(requested));
        if(file==null||!Files.exists(file)){json(exchange,404,new JSONObject().put("error","no_snapshot"));return;}
        exchange.getResponseHeaders().set("Content-Type","application/gzip");exchange.getResponseHeaders().set("Cache-Control","no-store");
        exchange.sendResponseHeaders(200,Files.size(file));try(InputStream in=Files.newInputStream(file);OutputStream out=exchange.getResponseBody()){in.transferTo(out);}
    }
    static void json(HttpExchange exchange,int code,JSONObject object)throws Exception{
        byte[] data=object.toString().getBytes(StandardCharsets.UTF_8);exchange.getResponseHeaders().set("Content-Type","application/json; charset=utf-8");exchange.getResponseHeaders().set("Cache-Control","no-store");
        exchange.sendResponseHeaders(code,data.length);try(OutputStream out=exchange.getResponseBody()){out.write(data);}
    }
    public void close(){server.stop(0);workers.shutdownNow();try{lock.release();lockChannel.close();}catch(IOException ignored){}}
    public static void main(String[] args)throws Exception{
        System.setProperty("sun.net.httpserver.maxReqTime","60");System.setProperty("sun.net.httpserver.maxRspTime","120");
        String tokenFile=System.getenv("STUDY_SYNC_TOKEN_FILE");if(tokenFile==null)throw new IOException("请设置 STUDY_SYNC_TOKEN_FILE，不能把访问码写入启动参数");
        String token=Files.readString(Path.of(tokenFile),StandardCharsets.UTF_8).trim();
        String bind=System.getenv().getOrDefault("STUDY_SYNC_BIND","127.0.0.1");int port=Integer.parseInt(System.getenv().getOrDefault("STUDY_SYNC_PORT","8787"));
        CloudSyncServer server=new CloudSyncServer(Path.of(System.getenv().getOrDefault("STUDY_SYNC_DATA","./data")),bind,port,token);
        Runtime.getRuntime().addShutdownHook(new Thread(server::close));server.start();System.out.println("学习日程同步服务已启动："+bind+":"+server.port()+"；需要 HTTPS 反向代理");
    }
}
