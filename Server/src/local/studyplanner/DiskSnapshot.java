package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.*;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

/** Disposable, externally sorted records. Historical payloads never form an in-memory ledger. */
final class DiskSnapshot implements AutoCloseable {
    static final int MAX_RECORDS=200000, RUN_ROWS=256, RUN_CHARS=512*1024;
    static final int ACTIVE_ROWS=10000, ACTIVE_CHARS=6*1024*1024;
    static final class CapacityException extends IOException {
        CapacityException(){super("同步工作集超过服务器资源上限");}
    }
    final Path directory;
    JSONObject header;
    Path rows;
    long clock;
    boolean changed;

    DiskSnapshot(Path parent)throws IOException{directory=Files.createTempDirectory(parent,".merge-");}
    Path temporary()throws IOException{return Files.createTempFile(directory,"rows-",".jsonl");}
    static BufferedReader reader(Path path)throws IOException{return Files.newBufferedReader(path,StandardCharsets.UTF_8);}
    static BufferedWriter writer(Path path)throws IOException{return Files.newBufferedWriter(path,StandardCharsets.UTF_8);}

    void read(Path archive)throws Exception {
        List<Path> initialRuns=new ArrayList<>();List<String[]> batch=new ArrayList<>();int[] chars={0},count={0};boolean[] settings={false};
        // A one-record ledger applies exactly the shared protocol's metadata validation.
        SyncLedger validator=new SyncLedger();
        try(InputStream input=Files.newInputStream(archive);
            Reader in=new BufferedReader(new InputStreamReader(new CloudSnapshot.LimitedInput(
                new GZIPInputStream(new CloudSnapshot.LimitedInput(input,CloudSnapshot.MAX_GZIP)),CloudSnapshot.MAX_RAW),
                StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)))) {
            header=SyncJSON.readEnvelope(in,"records",Arrays.asList("format","archiveID","device","createdAt","serverID","revision"),row->{
                if(++count[0]>MAX_RECORDS)throw new CapacityException();
                if(row.has("modifiedAt")&&!(row.get("modifiedAt") instanceof Number))throw new IOException("修改时间无效");
                validator.records().clear();validator.mergeRecord(row);row.getBoolean("deleted");
                clock=Math.max(clock,row.getLong("version"));
                if(row.getString("kind").equals("settings")&&!row.getBoolean("deleted"))settings[0]=true;
                String line=row.toString();batch.add(new String[]{SyncLedger.key(row),line});chars[0]+=line.length();
                if(batch.size()>=RUN_ROWS||chars[0]>=RUN_CHARS){initialRuns.add(flush(batch));chars[0]=0;}
            });
        }
        if(header.getInt("format")!=1||!CloudSnapshot.validID(header.getString("archiveID"))||
            header.getString("device").isEmpty()||header.getString("device").length()>64||header.getLong("createdAt")<0||!settings[0])
            throw new IOException("云端完整数据包无效");
        if(!batch.isEmpty())initialRuns.add(flush(batch));
        List<Path> runs=initialRuns;
        // Pairwise passes keep only two records open, even for maximum-size payloads.
        while(runs.size()>1){
            List<Path> next=new ArrayList<>();
            for(int i=0;i<runs.size();i+=2){
                if(i+1==runs.size()){next.add(runs.get(i));continue;}
                Path combined=temporary();merge(runs.get(i),runs.get(i+1),combined,true);
                Files.delete(runs.get(i));Files.delete(runs.get(i+1));next.add(combined);
            }
            runs=next;
        }
        rows=runs.get(0);
    }

    Path flush(List<String[]> batch)throws Exception {
        batch.sort(Comparator.comparing(item->item[0]));Path path=temporary();String previous=null;
        try(Writer out=writer(path)){
            for(String[] item:batch){if(item[0].equals(previous))throw new IOException("重复同步记录");
                out.write(item[1]);out.write('\n');previous=item[0];}
        }
        batch.clear();return path;
    }

    static final class RowReader implements AutoCloseable {
        final BufferedReader in;String line,key;JSONObject row;
        RowReader(Path path)throws Exception{in=reader(path);advance();}
        void advance()throws Exception{line=in.readLine();row=line==null?null:new JSONObject(line);key=row==null?null:SyncLedger.key(row);}
        public void close()throws IOException{in.close();}
    }

    /** Sorted union. A conflicting record uses the same timestamp/version/device rule as both clients. */
    static boolean merge(Path old,Path incoming,Path output,boolean rejectDuplicates)throws Exception {
        boolean changed=false;int count=0;
        try(RowReader a=new RowReader(old);RowReader b=new RowReader(incoming);Writer out=writer(output)){
            while(a.row!=null||b.row!=null){
                if(++count>MAX_RECORDS)throw new CapacityException();
                int order=a.row==null?1:b.row==null?-1:a.key.compareTo(b.key);
                if(order<0){out.write(a.line);a.advance();}
                else if(order>0){out.write(b.line);b.advance();changed=true;}
                else {
                    if(rejectDuplicates)throw new IOException("重复同步记录");
                    boolean wins=SyncLedger.wins(b.row,a.row);out.write(wins?b.line:a.line);changed|=wins;a.advance();b.advance();
                }
                out.write('\n');
            }
        }
        return changed;
    }

    void combine(DiskSnapshot old)throws Exception {
        Path merged=temporary();changed=merge(old.rows,rows,merged,false);Files.delete(rows);rows=merged;clock=Math.max(clock,old.clock);
    }

    static final class WorkingSet {
        final SyncLedger ledger=new SyncLedger();int chars;
        WorkingSet(String device,long clock)throws Exception{ledger.value.put("device",device).put("clock",clock);}
        void add(JSONObject row,int length)throws Exception {
            if(ledger.records().has(SyncLedger.key(row)))return;
            if(ledger.records().length()>=ACTIVE_ROWS||(chars+=length)>ACTIVE_CHARS)throw new CapacityException();
            ledger.mergeRecord(row);
        }
    }

    WorkingSet workingSet(String device)throws Exception {
        WorkingSet result=new WorkingSet(device,clock);Set<String> confirmedTasks=new HashSet<>(),completionKeys=new HashSet<>();
        try(RowReader r=new RowReader(rows)){
            while(r.row!=null){JSONObject row=r.row;String kind=row.getString("kind");
                if(!row.getBoolean("deleted")||kind.equals("courses")){
                    result.add(row,r.line.length());
                    if(kind.equals("completions"))confirmedTasks.add(SyncLedger.payload(row).getString("taskID"));
                    if(kind.equals("tasks"))completionKeys.add("completions/"+Planner.stableID("completion|"+row.getString("id")));
                }
                r.advance();
            }
        }
        for(String id:confirmedTasks)completionKeys.add("completions/"+Planner.stableID("completion|"+id));
        try(RowReader r=new RowReader(rows)){
            while(r.row!=null){
                if(r.row.getBoolean("deleted")&&((r.row.getString("kind").equals("tasks")&&confirmedTasks.contains(r.row.getString("id")))||completionKeys.contains(r.key)))
                    result.add(r.row,r.line.length());
                r.advance();
            }
        }
        return result;
    }

    JSONObject planningState(String device)throws Exception {
        JSONObject state=workingSet(device).ledger.materialize();
        // Keep only the comparison fields, not a second complete materialized task graph.
        return new JSONObject().put("courses",state.get("courses")).put("fixedEvents",state.get("fixedEvents")).put("settings",state.get("settings"));
    }

    void normalize(String device,JSONObject before)throws Exception {
        WorkingSet work=workingSet(device);JSONObject state=work.ledger.materialize();double now=Planner.now();
        if((before!=null&&SyncExchange.needsReplan(before,state,now))||SyncExchange.invalidPending(state,now))Planner.replan(state,now);
        Planner.validate(state);
        // Replanning can reuse a historical task ID. Load those tombstones before capture so
        // the new edit keeps its logical clock and modifiedAt monotonic, including clock skew.
        Set<String> desired=new HashSet<>();
        for(String kind:SyncLedger.KINDS){
            if(kind.equals("settings")){desired.add("settings/settings");continue;}
            for(JSONObject row:Planner.list(state.getJSONArray(kind)))desired.add(kind+"/"+(kind.equals("completions")?Planner.stableID("completion|"+row.getString("taskID")):row.getString("id")));
        }
        try(RowReader r=new RowReader(rows)){while(r.row!=null){if(desired.contains(r.key))work.add(r.row,r.line.length());r.advance();}}
        long previous=work.ledger.sequence();work.ledger.capture(state);
        List<String[]> edits=new ArrayList<>();JSONArray changes=work.ledger.changes(previous);
        for(int i=0;i<changes.length();i++){JSONObject row=changes.getJSONObject(i);edits.add(new String[]{SyncLedger.key(row),row.toString()});}
        if(!edits.isEmpty()){
            Path overlay=flush(edits),merged=temporary();merge(rows,overlay,merged,false);Files.delete(rows);Files.delete(overlay);rows=merged;
        }
    }

    void write(Path destination,JSONObject envelope)throws Exception {
        try(Writer out=new BufferedWriter(new OutputStreamWriter(new CloudSnapshot.LimitedOutput(
            new GZIPOutputStream(new CloudSnapshot.LimitedOutput(Files.newOutputStream(destination),CloudSnapshot.MAX_GZIP)),CloudSnapshot.MAX_RAW),StandardCharsets.UTF_8));
            RowReader r=new RowReader(rows)){
            String text=envelope.toString();out.write(text,0,text.length()-1);out.write(",\"records\":[");long sequence=0;
            while(r.row!=null){if(sequence>0)out.write(',');r.row.put("sequence",++sequence);SyncJSON.write(out,r.row);r.advance();}
            out.write("]}");
        }
    }

    public void close()throws IOException{remove(directory);}
    static void remove(Path directory)throws IOException {
        try(java.util.stream.Stream<Path> paths=Files.walk(directory)){
            for(Path path:(Iterable<Path>)paths.sorted(Comparator.reverseOrder())::iterator)Files.deleteIfExists(path);
        }
    }
}
