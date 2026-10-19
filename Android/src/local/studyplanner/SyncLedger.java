package local.studyplanner;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Pure protocol engine, shared JSON schema with Swift SyncLedger. */
public final class SyncLedger {
    public static final String[] KINDS={"courses","fixedEvents","tasks","completions","settings"};
    public final JSONObject value;
    public SyncLedger(JSONObject value)throws Exception{this.value=value;}
    public SyncLedger()throws Exception{this(new JSONObject().put("device",Planner.id()).put("clock",0).put("sequence",0).put("peerCursor",0).put("sentCursor",0).put("records",new JSONObject()).put("lastAutoDate","").put("lastSuccess",0).put("lastAttempt",0));}
    JSONObject records()throws Exception{return value.getJSONObject("records");}
    public long sequence(){return value.optLong("sequence");}
    public static String key(JSONObject r)throws Exception{return r.getString("kind")+"/"+r.getString("id");}
    public static boolean wins(JSONObject a,JSONObject b)throws Exception{if(a.optLong("modifiedAt")!=b.optLong("modifiedAt"))return a.optLong("modifiedAt")>b.optLong("modifiedAt");return a.getLong("version")!=b.getLong("version")?a.getLong("version")>b.getLong("version"):a.getString("device").compareTo(b.getString("device"))>0;}
    static String canonical(Object o)throws Exception{
        if(o instanceof JSONObject){JSONObject j=(JSONObject)o;List<String> ks=new ArrayList<>();Iterator<String> it=j.keys();while(it.hasNext())ks.add(it.next());Collections.sort(ks);StringBuilder s=new StringBuilder("{");for(String k:ks)s.append(JSONObject.quote(k)).append(':').append(canonical(j.get(k))).append(',');return s.append('}').toString();}
        if(o instanceof JSONArray){JSONArray j=(JSONArray)o;StringBuilder s=new StringBuilder("[");for(int i=0;i<j.length();i++)s.append(canonical(j.get(i))).append(',');return s.append(']').toString();}
        if(o instanceof Number)return new java.math.BigDecimal(o.toString()).stripTrailingZeros().toPlainString();
        return o instanceof String ? JSONObject.quote((String)o) : String.valueOf(o);
    }
    static JSONObject payload(JSONObject row)throws Exception{return new JSONObject(new String(Base64.getDecoder().decode(row.getString("payload")),StandardCharsets.UTF_8));}
    // Preserve payload strings when copying headers or rows; never serialize the whole ledger.
    static JSONObject shallowCopy(JSONObject object)throws Exception{
        JSONObject copy=new JSONObject();Iterator<String> keys=object.keys();
        while(keys.hasNext()){String key=keys.next();copy.put(key,object.get(key));}return copy;
    }
    public JSONObject metadata()throws Exception{
        JSONObject result=new JSONObject();Iterator<String> keys=value.keys();
        while(keys.hasNext()){String key=keys.next();if(!key.equals("records"))result.put(key,value.get(key));}return result;
    }
    static boolean equivalent(Object left,Object right)throws Exception{
        if(left==right)return true;
        if(left instanceof JSONObject&&right instanceof JSONObject){
            JSONObject a=(JSONObject)left,b=(JSONObject)right;if(a.length()!=b.length())return false;
            Iterator<String> keys=a.keys();while(keys.hasNext()){String key=keys.next();if(!b.has(key)||!equivalent(a.get(key),b.get(key)))return false;}return true;
        }
        if(left instanceof JSONArray&&right instanceof JSONArray){
            JSONArray a=(JSONArray)left,b=(JSONArray)right;if(a.length()!=b.length())return false;
            for(int i=0;i<a.length();i++)if(!equivalent(a.get(i),b.get(i)))return false;return true;
        }
        if(left instanceof Number&&right instanceof Number)return new java.math.BigDecimal(left.toString()).compareTo(new java.math.BigDecimal(right.toString()))==0;
        return Objects.equals(left,right);
    }
    public void capture(JSONObject state)throws Exception{capture(state,System.currentTimeMillis());}
    public void capture(JSONObject state,long nowMillis)throws Exception{
        Set<String> archived=new HashSet<>(),desired=new HashSet<>();
        for(JSONObject course:Planner.list(state.getJSONArray("courses")))if(course.optBoolean("isArchived"))archived.add(course.getString("id"));
        JSONObject records=records();List<JSONObject> changes=new ArrayList<>();
        for(String kind:KINDS){List<JSONObject> values=kind.equals("settings")?Collections.singletonList(state.getJSONObject(kind)):Planner.list(state.getJSONArray(kind));
            for(JSONObject source:values){
                if(archived.contains(source.optString(kind.equals("courses")?"id":"courseID")))continue;
                JSONObject data=shallowCopy(source);
                if(kind.equals("completions"))data.put("id",Planner.stableID("completion|"+data.getString("taskID")));
                if(kind.equals("fixedEvents"))for(String field:new String[]{"weekdays","excludedDates"}){JSONArray a=data.optJSONArray(field);if(a!=null){List<Double> items=new ArrayList<>();for(int i=0;i<a.length();i++)items.add(a.getDouble(i));Collections.sort(items);data.put(field,new JSONArray(items));}}
                String id=kind.equals("settings")?"settings":data.getString("id"),k=kind+"/"+id;desired.add(k);
                JSONObject old=records.optJSONObject(k);
                if(old!=null&&!old.getBoolean("deleted")&&equivalent(payload(old),data))continue;
                changes.add(new JSONObject().put("kind",kind).put("id",id).put("deleted",false).put("payload",Base64.getEncoder().encodeToString(data.toString().getBytes(StandardCharsets.UTF_8))));
            }
        }
        Iterator<String> it=records.keys();while(it.hasNext()){String k=it.next();JSONObject old=records.getJSONObject(k);if(!desired.contains(k)&&!old.getBoolean("deleted"))changes.add(shallowCopy(old).put("deleted",true));}
        if(changes.isEmpty())return;long clock=value.getLong("clock")+1;value.put("clock",clock);changes.sort(Comparator.comparing(r->r.optString("kind")+"/"+r.optString("id")));
        for(JSONObject r:changes){long seq=sequence()+1;value.put("sequence",seq);r.put("version",clock).put("device",value.getString("device")).put("sequence",seq);JSONObject old=records.optJSONObject(key(r));r.put("modifiedAt",Math.max(nowMillis,(old==null?0:old.optLong("modifiedAt"))+1));records.put(key(r),r);}
    }
    public JSONArray changes(long after)throws Exception{if(after<0||after>sequence())throw new IllegalArgumentException("游标无效，请重新配对");List<JSONObject> out=new ArrayList<>();Iterator<String> it=records().keys();while(it.hasNext()){JSONObject r=records().getJSONObject(it.next());if(r.getLong("sequence")>after)out.add(r);}out.sort(Comparator.comparingLong(r->r.optLong("sequence")));return new JSONArray(out);}
    public void merge(JSONArray incoming)throws Exception{for(int i=0;i<incoming.length();i++)mergeRecord(incoming.getJSONObject(i));}
    void mergeRecord(JSONObject item)throws Exception{
        JSONObject r=shallowCopy(item);String kind=r.getString("kind"),id=r.getString("id");long v=r.getLong("version");
        if(!Arrays.asList(KINDS).contains(kind)||v<=0||v>Long.MAX_VALUE-1000000||r.optLong("modifiedAt")<0||r.optLong("modifiedAt")>Long.MAX_VALUE-1000000||r.getString("device").isEmpty()||r.getString("device").length()>64||r.getString("payload").length()>1400000)throw new IllegalArgumentException("同步记录无效");
        if(kind.equals("settings")?!id.equals("settings"):!UUID.fromString(id).toString().toUpperCase(Locale.ROOT).equals(id))throw new IllegalArgumentException("同步 ID 无效");
        value.put("clock",Math.max(value.getLong("clock"),v));JSONObject old=records().optJSONObject(key(r));if(old!=null&&!wins(r,old))return;long seq=sequence()+1;value.put("sequence",seq);r.put("sequence",seq);records().put(key(r),r);
    }
    public JSONObject materialize()throws Exception{
        JSONObject s=new JSONObject().put("schemaVersion",1);for(String kind:KINDS)if(!kind.equals("settings"))s.put(kind,new JSONArray());
        List<String> keys=new ArrayList<>();Iterator<String> it=records().keys();while(it.hasNext())keys.add(it.next());Collections.sort(keys);
        for(String k:keys){JSONObject r=records().getJSONObject(k);if(r.getBoolean("deleted"))continue;String kind=r.getString("kind");JSONObject p=payload(r);if(kind.equals("settings"))s.put(kind,p);else{if(!r.getString("id").equals(p.getString("id")))throw new IllegalArgumentException("记录 ID 不匹配");s.getJSONArray(kind).put(p);}}
        Set<String> deletedIDs=new HashSet<>();for(String k:keys){JSONObject r=records().getJSONObject(k);if(r.getString("kind").equals("courses")&&r.getBoolean("deleted"))deletedIDs.add(r.getString("id"));}
        for(JSONObject course:Planner.list(s.getJSONArray("courses")))if(course.optBoolean("isArchived"))deletedIDs.add(course.getString("id"));
        Set<String> confirmationTasks=new HashSet<>();for(JSONObject record:Planner.list(s.getJSONArray("completions")))confirmationTasks.add(record.getString("taskID"));
        Map<String,JSONObject> deletedTasks=new HashMap<>();for(String k:keys){JSONObject row=records().getJSONObject(k);if(row.getString("kind").equals("tasks")&&row.getBoolean("deleted")&&confirmationTasks.contains(row.getString("id")))deletedTasks.put(row.getString("id"),payload(row));}
        Planner.reconcileMergedCourseProgress(s,deletedIDs,deletedTasks);
        reconcileConfirmations(s);
        CourseTools.purgeDeletedLessonRecords(s,deletedTasks.values());
        Planner.removeArchivedCourses(s);Planner.removeCourses(s,deletedIDs);
        Planner.validate(s);return s;
    }
    void reconcileConfirmations(JSONObject state)throws Exception{
        Map<String,JSONObject> tasks=new TreeMap<>(),completions=new HashMap<>();
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))tasks.put(task.getString("id"),task);
        for(JSONObject record:Planner.list(state.getJSONArray("completions"))){
            String id=record.getString("taskID");completions.put(id,record);
            JSONObject row=records().optJSONObject("tasks/"+id);
            if(!tasks.containsKey(id)&&row!=null&&row.getBoolean("deleted")){
                JSONObject old=payload(row);if(!old.has("confirmedAt"))tasks.put(id,old);
            }
        }
        for(JSONObject task:tasks.values()){
            String id=task.getString("id");JSONObject row=records().optJSONObject("completions/"+Planner.stableID("completion|"+id));
            JSONObject record=completions.get(id);
            if(row!=null&&row.getBoolean("deleted")){
                if(task.has("confirmedAt"))task.put("status","planned");task.remove("confirmedAt");task.put("completedMinutes",0);
            }else if(record!=null&&record.getString("courseID").equals(task.getString("courseID"))){
                int minutes=record.getInt("minutes");if(minutes<0||minutes>task.getInt("durationMinutes"))throw new IllegalArgumentException("确认时长无效");
                task.put("confirmedAt",record.getDouble("recordedAt")).put("completedMinutes",minutes)
                    .put("status",minutes==0?"missed":minutes==task.getInt("durationMinutes")?"completed":"partial");
            }
        }
        state.put("tasks",new JSONArray(tasks.values()));
        SyncExchange.reconcileTasks(this,state);
        Set<String> kept=new HashSet<>();for(JSONObject task:Planner.list(state.getJSONArray("tasks")))kept.add(task.getString("id"));
        JSONArray result=new JSONArray();for(JSONObject record:completions.values())if(!tasks.containsKey(record.getString("taskID"))||kept.contains(record.getString("taskID")))result.put(record);
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(task.has("confirmedAt")&&!completions.containsKey(task.getString("id")))
            result.put(new JSONObject().put("id",Planner.stableID("completion|"+task.getString("id"))).put("taskID",task.getString("id")).put("courseID",task.getString("courseID"))
                .put("minutes",task.getInt("completedMinutes")).put("recordedAt",task.getDouble("confirmedAt")));
        // Stable order prevents no-op captures from appearing as new edits.
        List<JSONObject> sorted=Planner.list(result);sorted.sort(Comparator.comparing(r->r.optString("id")));state.put("completions",new JSONArray(sorted));
    }

}
