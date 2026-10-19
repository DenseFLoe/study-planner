package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Base64;

/** Window-scoped staging; only a complete upload may enter the database transaction. */
final class SyncTransfer implements AutoCloseable {
    static final int CHUNK_SIZE=4*1024*1024, MAXIMUM_SIZE=128*1024*1024;
    interface Exchange { JSONObject run(JSONObject request)throws Exception; }
    private final File directory;
    private File upload,download;
    private int expected,received;
    private boolean ready,exchanged;
    SyncTransfer(File directory){this.directory=directory;}

    synchronized JSONObject handle(JSONObject request,Exchange exchange)throws Exception {
        switch(request.getString("operation")) {
            case "begin":
                close();expected=request.getInt("length");
                if(expected<=0||expected>MAXIMUM_SIZE)throw new IOException("同步数据超过 128 MB 或长度无效");
                upload=File.createTempFile("planner-transfer-",".upload",directory);
                return new JSONObject().put("transfer",1);
            case "upload":
                if(upload==null||exchanged||request.getInt("offset")!=received)throw new IOException("同步分块顺序无效");
                String encoded=request.getString("data");
                if(encoded.length()>((CHUNK_SIZE+2)/3)*4)throw new IOException("同步分块过大");
                byte[] bytes=Base64.getDecoder().decode(encoded);
                if(bytes.length==0||bytes.length>CHUNK_SIZE||bytes.length>expected-received)throw new IOException("同步分块长度无效");
                try(FileOutputStream out=new FileOutputStream(upload,true)){out.write(bytes);}
                received+=bytes.length;return new JSONObject().put("offset",received);
            case "exchange":
                if(upload==null||received!=expected||exchanged)throw new IOException("同步数据尚未收齐或已提交");
                exchanged=true;
                JSONObject body=new JSONObject(new String(Files.readAllBytes(upload.toPath()),StandardCharsets.UTF_8));
                byte[] reply=exchange.run(body).toString().getBytes(StandardCharsets.UTF_8);
                if(reply.length>MAXIMUM_SIZE)throw new IOException("同步响应超过 128 MB");
                download=File.createTempFile("planner-transfer-",".download",directory);
                try(FileOutputStream out=new FileOutputStream(download)){out.write(reply);}
                upload.delete();upload=null;ready=true;
                return new JSONObject().put("length",reply.length);
            case "download":
                if(!ready)throw new IOException("同步响应尚未就绪");
                int offset=request.getInt("offset");
                if(offset<0||offset>=download.length())throw new IOException("同步下载位置无效");
                byte[] chunk=new byte[(int)Math.min(CHUNK_SIZE,download.length()-offset)];
                try(RandomAccessFile file=new RandomAccessFile(download,"r")){file.seek(offset);file.readFully(chunk);}
                return new JSONObject().put("data",Base64.getEncoder().encodeToString(chunk));
            default:throw new IOException("同步分块操作无效");
        }
    }
    public synchronized void close(){
        if(upload!=null)upload.delete();if(download!=null)download.delete();
        upload=null;download=null;expected=0;received=0;ready=false;exchanged=false;
    }
}
