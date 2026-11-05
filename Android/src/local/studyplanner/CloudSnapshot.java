package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.*;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

/** Complete gzip JSON snapshots shared by Android, macOS and the standalone Linux service. */
public final class CloudSnapshot {
    public static final long MAX_RAW=128L*1024*1024,MAX_GZIP=32L*1024*1024;
    public final SyncLedger ledger;
    public final JSONObject header;
    private CloudSnapshot(SyncLedger ledger,JSONObject header){this.ledger=ledger;this.header=header;}
    public static JSONObject header(SyncLedger ledger)throws Exception{
        return new JSONObject().put("format",1).put("archiveID",Planner.stableID("cloud|"+ledger.value.getString("device")+"|"+ledger.sequence()))
            .put("device",ledger.value.getString("device")).put("createdAt",System.currentTimeMillis());
    }
    public static CloudSnapshot read(InputStream input)throws Exception{
        SyncLedger ledger=new SyncLedger();
        JSONObject header=readRecords(input,ledger::mergeRecord);
        ledger.materialize();
        return new CloudSnapshot(ledger,header);
    }
    /** Merge only into a disposable candidate; callers must discard it if any validation fails. */
    public static void mergeInto(InputStream input,SyncLedger candidate)throws Exception{
        readRecords(input,candidate::mergeRecord);
    }
    private static JSONObject readRecords(InputStream input,SyncJSON.RecordConsumer consumer)throws Exception{
        Set<String> keys=new HashSet<>();boolean[] settings={false};JSONObject header;
        try(Reader reader=new BufferedReader(new InputStreamReader(new LimitedInput(new GZIPInputStream(new LimitedInput(input,MAX_GZIP)),MAX_RAW),
                StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)))){
            header=SyncJSON.readEnvelope(reader,"records",Arrays.asList("format","archiveID","device","createdAt","serverID","revision"),row->{
                if(keys.size()>=200000||!keys.add(SyncLedger.key(row)))throw new IOException("重复或过多的同步记录");
                if(row.has("modifiedAt")&&!row.isNull("modifiedAt")&&!(row.get("modifiedAt") instanceof Number))throw new IOException("修改时间无效");
                if("settings".equals(row.getString("kind"))&&"settings".equals(row.getString("id"))&&!row.getBoolean("deleted"))settings[0]=true;
                consumer.accept(row);
            });
        }
        if(header.getInt("format")!=1||!validID(header.getString("archiveID"))||header.getString("device").isEmpty()||header.getString("device").length()>64||header.getLong("createdAt")<0)
            throw new IOException("云端数据包格式无效");
        if(!settings[0])throw new IOException("完整数据包缺少设置");
        return header;
    }
    public static void write(OutputStream output,SyncLedger ledger,JSONObject header)throws Exception{
        JSONObject envelope=SyncLedger.shallowCopy(header).put("records",ledger.changes(0));
        try(Writer writer=new BufferedWriter(new OutputStreamWriter(new LimitedOutput(new GZIPOutputStream(new LimitedOutput(output,MAX_GZIP)),MAX_RAW),StandardCharsets.UTF_8))){SyncJSON.write(writer,envelope);}
    }
    /** Clean old queued archives one record at a time; preserve identities, versions and retries. */
    public static void sanitizeSourceURLs(File file)throws Exception{
        long length=file.length(),modified=file.lastModified();boolean[] changed={false};JSONObject header;
        try(InputStream input=new FileInputStream(file)){
            header=readRecords(input,row->{if(CourseSourcePrivacy.record(row)!=row)changed[0]=true;});
        }
        if(!changed[0])return;
        File temporary=File.createTempFile(".source-clean-",".tmp",file.getAbsoluteFile().getParentFile());
        try{
            try(Writer out=new BufferedWriter(new OutputStreamWriter(new LimitedOutput(
                    new GZIPOutputStream(new LimitedOutput(new FileOutputStream(temporary),MAX_GZIP)),MAX_RAW),StandardCharsets.UTF_8))){
                out.write('{');List<String> names=new ArrayList<>();Iterator<String> keys=header.keys();
                while(keys.hasNext())names.add(keys.next());Collections.sort(names);
                for(String key:names){SyncJSON.write(out,key);out.write(':');SyncJSON.write(out,header.get(key));out.write(',');}
                out.write("\"records\":[");boolean[] first={true};JSONObject verified;
                try(InputStream input=new FileInputStream(file)){
                    verified=readRecords(input,row->{if(!first[0])out.write(',');first[0]=false;SyncJSON.write(out,CourseSourcePrivacy.record(row));});
                }
                if(!SyncLedger.equivalent(header,verified)||length!=file.length()||modified!=file.lastModified())
                    throw new IOException("待上传文件在检查期间发生变化，请重试。");
                out.write("]}");
            }
            try(FileChannel channel=FileChannel.open(temporary.toPath(),StandardOpenOption.WRITE)){channel.force(true);}
            Files.move(temporary.toPath(),file.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
        }finally{temporary.delete();}
    }
    static boolean validID(String value){try{return UUID.fromString(value).toString().equalsIgnoreCase(value);}catch(Exception e){return false;}}
    static final class LimitedInput extends FilterInputStream {
        long remaining;LimitedInput(InputStream in,long limit){super(in);remaining=limit;}
        public int read()throws IOException{int n=super.read();if(n!=-1&&--remaining<0)throw new IOException("数据包超过大小上限");return n;}
        public int read(byte[] b,int o,int n)throws IOException{int count=in.read(b,o,(int)Math.min(n,remaining+1));if(count>0&&(remaining-=count)<0)throw new IOException("数据包超过大小上限");return count;}
    }
    static final class LimitedOutput extends FilterOutputStream {
        long remaining;LimitedOutput(OutputStream out,long limit){super(out);remaining=limit;}
        public void write(int n)throws IOException{if(--remaining<0)throw new IOException("数据包超过大小上限");out.write(n);}
        public void write(byte[] b,int o,int n)throws IOException{if((remaining-=n)<0)throw new IOException("数据包超过大小上限");out.write(b,o,n);}
    }
}
