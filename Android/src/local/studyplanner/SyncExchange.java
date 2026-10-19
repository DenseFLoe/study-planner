package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;

/** Pure exchange logic; callers commit only after parsing, validation and response staging succeed. */
final class SyncExchange {
    interface Input { JSONObject read(SyncJSON.RecordConsumer consumer)throws Exception; }
    static final class Result {
        JSONObject header,reply;long after;int received;
    }
    static Result apply(SyncLedger ledger,Input input,double now)throws Exception {
        byte[][] before=signature(ledger.materialize());long originalSequence=ledger.sequence();
        int[] counts=new int[4];
        JSONObject header=input.read(row->{
            counts[3]++;JSONObject old=ledger.records().optJSONObject(SyncLedger.key(row));
            if(old==null||SyncLedger.wins(row,old)){
                if(row.getBoolean("deleted"))counts[2]++;else if(old==null||old.getBoolean("deleted"))counts[0]++;else counts[1]++;
            }
            ledger.mergeRecord(row);
        });
        if(header.getInt("protocol")!=1)throw new IllegalArgumentException("协议版本不兼容");
        long cursor=header.getLong("cursor");if(cursor<0||cursor>originalSequence)throw new IllegalArgumentException("同步游标无效，请重新配对");
        header.getBoolean("automatic");if(!header.getString("date").matches("[0-9]{4}-[0-9]{2}-[0-9]{2}"))throw new IOException("日期无效");
        JSONObject state=ledger.materialize();
        byte[][] after=signature(state);boolean changed=false;
        for(int i=0;i<before.length;i++)changed|=!Arrays.equals(before[i],after[i]);
        if(changed||invalidPending(state,now))Planner.replan(state,now);
        ledger.capture(state);
        Result result=new Result();result.header=header;result.after=cursor;result.received=counts[3];
        result.reply=new JSONObject().put("protocol",1).put("device",ledger.value.getString("device")).put("cursor",ledger.sequence())
            .put("applied","新增 "+counts[0]+"，修改 "+counts[1]+"，删除 "+counts[2]);
        return result;
    }
    private static byte[][] signature(JSONObject state)throws Exception {
        byte[][] result=new byte[3][];int index=0;
        for(String kind:new String[]{"courses","fixedEvents","settings"}){
            MessageDigest digest=MessageDigest.getInstance("SHA-256");
            try(Writer out=new BufferedWriter(new OutputStreamWriter(new DigestOutputStream(new OutputStream(){public void write(int b){}public void write(byte[] b,int o,int n){}},digest),StandardCharsets.UTF_8))){SyncJSON.write(out,state.get(kind));}
            result[index++]=digest.digest();
        }
        return result;
    }
    // A legacy random ID and a newly generated stable ID can describe the same block.
    // Resolve exact duplicates before they become two active/history entries or two credits.
    static void reconcileTasks(SyncLedger ledger,JSONObject state)throws Exception {
        java.util.Map<String,JSONObject> winners=new java.util.TreeMap<>();
        for(JSONObject task:Planner.list(state.getJSONArray("tasks"))){
            String key=new JSONArray().put(task.getString("courseID")).put(task.optString("lessonID")).put(task.getDouble("start")).put(task.getInt("durationMinutes"))
                .put(task.opt("floatingWindowStart")).put(task.opt("floatingWindowEnd")).toString();
            JSONObject old=winners.get(key);
            if(old==null){winners.put(key,task);continue;}
            if(task.has("confirmedAt")!=old.has("confirmedAt")){if(task.has("confirmedAt"))winners.put(key,task);continue;}
            JSONObject a=ledger.records().optJSONObject("completions/"+Planner.stableID("completion|"+task.getString("id"))),b=ledger.records().optJSONObject("completions/"+Planner.stableID("completion|"+old.getString("id")));
            if(a==null)a=ledger.records().getJSONObject("tasks/"+task.getString("id"));if(b==null)b=ledger.records().getJSONObject("tasks/"+old.getString("id"));
            if(SyncLedger.wins(a,b)||(!SyncLedger.wins(b,a)&&task.getString("id").compareTo(old.getString("id"))>0))winners.put(key,task);
        }
        state.put("tasks",new JSONArray(winners.values()));
    }
    static boolean needsReplan(JSONObject previous,JSONObject state,double now)throws Exception {
        for(String kind:new String[]{"courses","fixedEvents","settings"})if(!SyncLedger.equivalent(previous.get(kind),state.get(kind)))return true;
        return invalidPending(state,now);
    }
    static boolean invalidPending(JSONObject state,double now)throws Exception {
        java.util.List<JSONObject> pending=new java.util.ArrayList<>();java.util.Map<String,Integer> totals=new java.util.HashMap<>();
        for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(t)&&Planner.end(t)>now){pending.add(t);String id=t.getString("courseID");totals.put(id,totals.getOrDefault(id,0)+t.getInt("durationMinutes"));}
        pending.sort(java.util.Comparator.comparingDouble(t->t.optDouble("start")));for(int i=1;i<pending.size();i++)if(Planner.end(pending.get(i-1))>pending.get(i).getDouble("start"))return true;
        for(JSONObject c:Planner.list(state.getJSONArray("courses")))if(totals.getOrDefault(c.getString("id"),0)>Planner.remaining(state,c))return true;
        return false;
    }
}
