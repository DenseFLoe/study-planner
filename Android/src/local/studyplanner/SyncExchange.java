package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.time.LocalDate;
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
    static String taskSlot(JSONObject task)throws Exception {
        return new JSONArray().put(task.getString("courseID")).put(task.optString("lessonID")).put(task.getDouble("start")).put(task.getInt("durationMinutes"))
            .put(task.opt("floatingWindowStart")).put(task.opt("floatingWindowEnd")).toString();
    }
    static void reconcileTasks(SyncLedger ledger,JSONObject state)throws Exception {
        Map<String,JSONObject> winners=new TreeMap<>();List<JSONObject> tasks=Planner.list(state.getJSONArray("tasks"));
        Map<String,Integer> counts=new HashMap<>();for(JSONObject task:tasks){String slot=taskSlot(task);counts.put(slot,counts.getOrDefault(slot,0)+1);}
        for(JSONObject task:tasks){
            String id=task.getString("id"),slot=taskSlot(task),generation="";
            if(task.optBoolean("replacesConfirmedBlock"))generation=id;
            else if(counts.get(slot)>1&&UUID.fromString(id).version()==5){
                // Recognize older salted IDs only for colliding slots, keeping normal reads linear.
                String base="task|"+task.getString("courseID")+"|"+(long)task.getDouble("start")+"|"+task.getInt("durationMinutes")+(Planner.hasLessonID(task)?"|"+task.optString("lessonID"):"");
                if(!id.equals(Planner.stableID(base))){
                    List<String> confirmed=new ArrayList<>();for(JSONObject other:tasks)if(Planner.hasConfirmationTime(other)&&other.getString("courseID").equals(task.getString("courseID"))&&!other.getString("id").equals(id))confirmed.add(other.getString("id"));Collections.sort(confirmed);
                    if(id.equals(Planner.stableID(base+"|confirmed|"+String.join(",",confirmed))))generation=id;
                }
            }
            String key=new JSONArray().put(slot).put(generation).toString();
            JSONObject old=winners.get(key);
            if(old==null){winners.put(key,task);continue;}
            if(Planner.hasConfirmationTime(task)!=Planner.hasConfirmationTime(old)){if(Planner.hasConfirmationTime(task))winners.put(key,task);continue;}
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
    /** Cloud downloads use the same draft validation as hotspot exchange. */
    static JSONObject repairMergedSchedule(SyncLedger ledger,double now)throws Exception {
        JSONObject state=ledger.materialize();
        if(invalidPending(state,now))Planner.replan(state,now);
        ledger.capture(state);
        return state;
    }
    static boolean invalidPending(JSONObject state,double now)throws Exception {
        List<JSONObject> pending=new ArrayList<>();Map<String,Integer> totals=new HashMap<>();
        Map<String,Map<String,Integer>> lessons=new HashMap<>();
        Map<String,JSONObject> courses=new HashMap<>();
        for(JSONObject course:Planner.list(state.getJSONArray("courses")))courses.put(course.getString("id"),course);
        List<Planner.Span> history=new ArrayList<>();Double actualStart=Planner.actualStudyStart(state,now);
        for(JSONObject task:Planner.list(state.getJSONArray("tasks"))){
            if(Planner.pending(task)&&Planner.planningEnd(task)>now){
                String id=task.getString("courseID");JSONObject course=courses.get(id);
                // A peer can generate new task IDs from old inputs after our newer
                // course row has already won. Input signatures alone miss those drafts.
                if(course==null||!course.optBoolean("autoScheduleEnabled",true)
                    ||!Planner.eligible(course,Planner.day(task.getDouble("start"))))return true;
                pending.add(task);totals.put(id,totals.getOrDefault(id,0)+task.getInt("durationMinutes"));
                if(actualStart!=null&&Planner.day(task.getDouble("start")).equals(Planner.day(now))&&task.getDouble("start")<actualStart)return true;
                if(Planner.hasLessonID(task))lessons.computeIfAbsent(id,key->new HashMap<>()).merge(task.getString("lessonID"),task.getInt("durationMinutes"),Integer::sum);
            }
            // Use the same retained-history and early-confirmation boundaries as replan.
            boolean retained=!Planner.pending(task)||(Planner.planningEnd(task)<=now&&!(actualStart!=null&&Planner.day(task.getDouble("start")).equals(Planner.day(now))));
            if(retained&&Planner.planningStart(task)<now&&(Planner.pending(task)||task.optInt("completedMinutes")>0))
                history.add(Planner.buffered(Planner.retainedHistoryStart(task),Planner.retainedHistoryEnd(task)));
        }
        pending.sort(Comparator.comparingDouble(t->t.optDouble("start")));
        for(int i=1;i<pending.size();i++)if(Planner.end(pending.get(i-1))+Planner.BREAK_SECONDS>pending.get(i).getDouble("start"))return true;
        // Sweep merged history intervals instead of comparing every task with every record.
        List<Planner.Span> blocked=Planner.merge(history);int index=0;
        for(JSONObject task:pending){
            double start=task.getDouble("start");
            while(index<blocked.size()&&blocked.get(index).b<=start)index++;
            if(index<blocked.size()&&blocked.get(index).a<Planner.end(task))return true;
        }
        for(JSONObject course:courses.values()){
            String id=course.getString("id");
            if(totals.getOrDefault(id,0)>Planner.remaining(state,course))return true;
            Map<String,Integer> remaining=new HashMap<>();for(Planner.Work work:Planner.lessonWorkAll(state,course))remaining.put(work.lessonID,work.minutes);
            for(Map.Entry<String,Integer> entry:lessons.getOrDefault(id,Collections.emptyMap()).entrySet())if(entry.getValue()>remaining.getOrDefault(entry.getKey(),0))return true;
        }
        return invalidWindows(state,pending);
    }
    private static boolean invalidWindows(JSONObject state,List<JSONObject> pending)throws Exception {
        Map<LocalDate,List<JSONObject>> days=new TreeMap<>();
        for(JSONObject task:pending)days.computeIfAbsent(Planner.day(task.getDouble("start")),day->new ArrayList<>()).add(task);
        List<JSONObject> windows=Planner.list(state.getJSONObject("settings").getJSONArray("availability"));
        List<JSONObject> events=Planner.list(state.getJSONArray("fixedEvents"));
        for(Map.Entry<LocalDate,List<JSONObject>> entry:days.entrySet()){
            LocalDate day=entry.getKey();List<Planner.Span> available=new ArrayList<>(),exact=new ArrayList<>();
            List<JSONObject> floating=new ArrayList<>();
            for(JSONObject window:windows)if(window.getInt("weekday")==Planner.weekday(day))
                available.add(new Planner.Span(Planner.at(day,window.getInt("startMinute")),Planner.at(day,window.getInt("endMinute"))));
            for(JSONObject event:events)if(Planner.occurs(event,day)){
                if(Planner.floating(event))floating.add(event);
                else exact.add(new Planner.Span(Planner.at(day,event.getInt("startMinute")),Planner.at(day,event.getInt("endMinute"))));
            }
            available=Planner.subtract(available,exact);
            List<Planner.Span> occupied=new ArrayList<>(exact),moving=new ArrayList<>();
            for(JSONObject task:entry.getValue()){
                double start=task.getDouble("start"),end=Planner.end(task);boolean fits=false;
                for(Planner.Span window:available)if(start>=window.a&&end<=window.b){fits=true;break;}
                if(!fits)return true;
                Planner.Span span=new Planner.Span(start,end);occupied.add(span);moving.add(span);
            }
            // An optimistic per-event check proves only that a continuous slot is
            // impossible. Do not invalidate a saved plan on a search-budget limit
            // or pin a feasible floating event to one arbitrary witness position.
            for(JSONObject event:floating){
                Planner.Span window=new Planner.Span(Planner.at(day,event.getInt("startMinute")),Planner.at(day,event.getInt("endMinute")));
                if(!overlapsAny(window,moving))continue;
                boolean fits=false;for(Planner.Span free:Planner.subtract(Collections.singletonList(window),occupied))
                    if(free.minutes()>=Planner.occupied(event)){fits=true;break;}
                if(!fits)return true;
            }
            // Overlapping floating windows also share capacity: each event fitting
            // individually cannot justify booking the same free minutes twice.
            floating.sort(Comparator.comparingInt(event->event.optInt("startMinute")));
            Planner.Span component=null;int required=0;
            for(JSONObject event:floating){
                double start=Planner.at(day,event.getInt("startMinute")),end=Planner.at(day,event.getInt("endMinute"));
                if(component==null||start>component.b){
                    if(component!=null&&overlapsAny(component,moving)&&freeMinutes(component,occupied)<required)return true;
                    component=new Planner.Span(start,end);required=Planner.occupied(event);
                }else{component.b=Math.max(component.b,end);required+=Planner.occupied(event);}
            }
            if(component!=null&&overlapsAny(component,moving)&&freeMinutes(component,occupied)<required)return true;
        }
        return false;
    }
    private static int freeMinutes(Planner.Span window,List<Planner.Span> occupied){
        int total=0;for(Planner.Span free:Planner.subtract(Collections.singletonList(window),occupied))total+=free.minutes();
        return total;
    }
    private static boolean overlapsAny(Planner.Span window,List<Planner.Span> tasks){
        // Existing event conflicts must not repeatedly replan unrelated study slots.
        for(Planner.Span task:tasks)if(window.a<task.b&&window.b>task.a)return true;
        return false;
    }
}
