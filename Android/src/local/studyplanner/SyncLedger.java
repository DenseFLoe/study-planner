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
        Set<String> archived=new HashSet<>(),desired=new HashSet<>(),confirmationTasks=new HashSet<>();
        for(JSONObject course:Planner.list(state.getJSONArray("courses")))if(course.optBoolean("isArchived"))archived.add(course.getString("id"));
        Planner.validateCourseNumbers(state.getJSONArray("courses"),archived);
        for(JSONObject event:Planner.list(state.getJSONArray("fixedEvents")))Planner.validateEventWindow(event);
        // Check retained progress before archived task ownership is discarded.
        Map<String,String> taskCourses=new HashMap<>();
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))taskCourses.put(task.getString("id"),task.getString("courseID"));
        for(JSONObject record:Planner.list(state.getJSONArray("completions"))){
            String course=record.getString("courseID"),owner=taskCourses.get(record.getString("taskID"));
            if(archived.contains(course))continue;
            Planner.validateCompletionData(record);
            if(owner!=null&&!owner.equals(course))throw new IllegalArgumentException("完成记录与关联任务的课程不一致");
        }
        Planner.validateRecordedProgress(state,archived);
        JSONObject records=records();List<JSONObject> changes=new ArrayList<>();
        for(String kind:KINDS){List<JSONObject> values=kind.equals("settings")?Collections.singletonList(state.getJSONObject(kind)):Planner.list(state.getJSONArray(kind));
            for(JSONObject source:values){
                if(archived.contains(source.optString(kind.equals("courses")?"id":"courseID")))continue;
                if(kind.equals("tasks")){
                    Planner.validateTaskData(source);
                    if(!Planner.hasValidPlanningInterval(source))throw new IllegalArgumentException("任务时间区间无效");
                }
                // Detect conflicts before canonical IDs collapse rows or mutate the ledger.
                if(kind.equals("completions")&&!confirmationTasks.add(source.getString("taskID")))throw new IllegalArgumentException("同一任务存在多条完成记录");
                JSONObject data=shallowCopy(kind.equals("courses")?CourseSourcePrivacy.course(source):source);
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
        for(JSONObject r:changes){long seq=sequence()+1;value.put("sequence",seq);r.put("version",clock).put("device",value.getString("device")).put("sequence",seq);JSONObject old=records.optJSONObject(key(r));r.put("modifiedAt",Math.max(nowMillis,(old==null?0:old.optLong("modifiedAt"))+1));captureCourseFields(r,old);records.put(key(r),r);}
    }
    public JSONArray changes(long after)throws Exception{if(after<0||after>sequence())throw new IllegalArgumentException("游标无效，请重新配对");List<JSONObject> out=new ArrayList<>();Iterator<String> it=records().keys();while(it.hasNext()){JSONObject r=records().getJSONObject(it.next());if(r.getLong("sequence")>after)out.add(CourseSourcePrivacy.record(r));}out.sort(Comparator.comparingLong(r->r.optLong("sequence")));return new JSONArray(out);}
    public void merge(JSONArray incoming)throws Exception{for(int i=0;i<incoming.length();i++)mergeRecord(incoming.getJSONObject(i));}
    static long wireInteger(JSONObject row,String key)throws Exception{
        Object number=row.get(key);
        if(!(number instanceof Number))throw new IllegalArgumentException("同步整数类型无效");
        try{return new java.math.BigDecimal(number.toString()).longValueExact();}
        catch(NumberFormatException|ArithmeticException error){throw new IllegalArgumentException("同步整数超出范围或含小数",error);}
    }
    void mergeRecord(JSONObject item)throws Exception{
        JSONObject r=shallowCopy(item);
        // Android's JSONObject string getters coerce non-strings, unlike desktop JSON-java.
        for(String field:new String[]{"kind","id","device","payload"})if(!(r.get(field) instanceof String))throw new IllegalArgumentException("同步字符串类型无效");
        String kind=r.getString("kind"),id=r.getString("id"),encoded=r.getString("payload");
        long v=wireInteger(r,"version"),modified=r.has("modifiedAt")&&!r.isNull("modifiedAt")?wireInteger(r,"modifiedAt"):0;
        wireInteger(r,"sequence");
        if(!Arrays.asList(KINDS).contains(kind)||v<=0||v>=Long.MAX_VALUE-1000000||modified<0||modified>=Long.MAX_VALUE-1000000||!(r.get("deleted") instanceof Boolean)||r.getString("device").isEmpty()||r.getString("device").length()>64||encoded.length()>1400000)throw new IllegalArgumentException("同步记录无效");
        if(kind.equals("settings")?!id.equals("settings"):!UUID.fromString(id).toString().toUpperCase(Locale.ROOT).equals(id))throw new IllegalArgumentException("同步 ID 无效");
        // Swift decodes every payload as Data, even for unrelated historical tombstones.
        // Java's decoder alone also accepts missing padding, which Swift rejects.
        if(encoded.length()%4!=0||Base64.getDecoder().decode(encoded).length>1_000_000)throw new IllegalArgumentException("同步负载编码或大小无效");
        validateFieldVersions(r);value.put("clock",Math.max(value.getLong("clock"),v));JSONObject old=records().optJSONObject(key(r));if(old!=null){if(kind.equals("courses")&&!r.getBoolean("deleted")&&!old.getBoolean("deleted")&&(r.optJSONObject("fieldVersions")!=null||old.optJSONObject("fieldVersions")!=null)){r=mergeCourseFields(r,old);if(equivalent(payload(r),payload(old))&&equivalent(r.opt("fieldVersions"),old.opt("fieldVersions"))&&!wins(r,old))return;}else if(!wins(r,old))return;}value.put("clock",Math.max(value.getLong("clock"),r.getLong("version")));long seq=sequence()+1;value.put("sequence",seq);r.put("sequence",seq);records().put(key(r),r);
    }

    static JSONObject fieldVersion(JSONObject row)throws Exception {
        return new JSONObject().put("modifiedAt",row.optLong("modifiedAt")).put("version",row.getLong("version")).put("device",row.getString("device"));
    }
    static String fieldGroup(String key){
        return Arrays.asList("totalMinutes","initialCompletedMinutes","webCourse","webCompletionOverlaps","netdisk","netdiskLessons","manualLessons","lessonOrder","lessonOrderCustomized","deletedLessonIDs","mergedSources","type").contains(key)?"$lessons":key;
    }
    static Map<String,JSONObject> fieldGroups(JSONObject object)throws Exception {
        Map<String,JSONObject> result=new TreeMap<>();Iterator<String> keys=object.keys();
        while(keys.hasNext()){String key=keys.next();if(!key.equals("id"))result.computeIfAbsent(fieldGroup(key),k->new JSONObject()).put(key,object.get(key));}return result;
    }
    static JSONObject fieldStamp(JSONObject row,String key)throws Exception {
        JSONObject fields=row.optJSONObject("fieldVersions");return fields!=null&&fields.has(key)?fields.getJSONObject(key):fieldVersion(row);
    }
    static void validateFieldVersions(JSONObject row)throws Exception {
        if(!row.has("fieldVersions")||row.isNull("fieldVersions"))return;
        JSONObject fields=row.getJSONObject("fieldVersions");
        if(!row.getString("kind").equals("courses")||fields.length()>128)throw new IllegalArgumentException("课程字段版本无效");
        Iterator<String> keys=fields.keys();while(keys.hasNext()){
            String key=keys.next();JSONObject stamp=fields.getJSONObject(key);long modified=wireInteger(stamp,"modifiedAt"),version=wireInteger(stamp,"version");
            if(key.isEmpty()||key.length()>128||modified<0||modified>row.optLong("modifiedAt")||version<=0||version>row.getLong("version")||!(stamp.get("device") instanceof String)||stamp.getString("device").isEmpty()||stamp.getString("device").length()>64)throw new IllegalArgumentException("课程字段版本无效");
        }
    }
    static void captureCourseFields(JSONObject row,JSONObject previous)throws Exception {
        if(!row.getString("kind").equals("courses")||row.getBoolean("deleted")){row.remove("fieldVersions");return;}
        Map<String,JSONObject> current=fieldGroups(payload(row));JSONObject stamps=new JSONObject();
        if(previous==null||previous.getBoolean("deleted")){for(String key:current.keySet())stamps.put(key,fieldVersion(row));}
        else {
            Map<String,JSONObject> old=fieldGroups(payload(previous));JSONObject prior=previous.optJSONObject("fieldVersions");
            if(prior!=null)stamps=shallowCopy(prior);
            Set<String> keys=new TreeSet<>(current.keySet());keys.addAll(old.keySet());
            for(String key:keys)stamps.put(key,equivalent(current.get(key),old.get(key))?fieldStamp(previous,key):fieldVersion(row));
        }
        row.put("fieldVersions",stamps);
    }
    static JSONObject mergeCourseFields(JSONObject a,JSONObject b)throws Exception {
        JSONObject winner=wins(a,b)?a:b;
        if(!a.getString("kind").equals("courses")||a.getBoolean("deleted")||b.getBoolean("deleted")||(a.optJSONObject("fieldVersions")==null&&b.optJSONObject("fieldVersions")==null))return shallowCopy(winner);
        JSONObject ap=payload(a),bp=payload(b);if(!a.getString("id").equals(ap.opt("id"))||!b.getString("id").equals(bp.opt("id")))throw new IllegalArgumentException("课程记录 ID 不匹配");
        Map<String,JSONObject> ag=fieldGroups(ap),bg=fieldGroups(bp);Set<String> keys=new TreeSet<>(ag.keySet());keys.addAll(bg.keySet());
        for(JSONObject row:new JSONObject[]{a,b}){JSONObject stamps=row.optJSONObject("fieldVersions");if(stamps!=null)stamps.keys().forEachRemaining(keys::add);}
        JSONObject object=new JSONObject().put("id",a.getString("id")),stamps=new JSONObject();
        for(String key:keys){JSONObject av=fieldStamp(a,key),bv=fieldStamp(b,key);if(equivalent(av,bv)&&!equivalent(ag.get(key),bg.get(key)))throw new IllegalArgumentException("同一课程字段版本对应不同内容");boolean useA=wins(av,bv);stamps.put(key,useA?av:bv);JSONObject selected=(useA?ag:bg).get(key);if(selected!=null){Iterator<String> names=selected.keys();while(names.hasNext()){String name=names.next();object.put(name,selected.get(name));}}}
        if(equivalent(object,payload(winner))&&equivalent(stamps,winner.opt("fieldVersions")))return shallowCopy(winner);
        JSONObject result=shallowCopy(winner).put("payload",Base64.getEncoder().encodeToString(object.toString().getBytes(StandardCharsets.UTF_8))).put("fieldVersions",stamps);
        result.put("version",Math.max(a.getLong("version"),b.getLong("version"))+1).put("modifiedAt",Math.max(a.optLong("modifiedAt"),b.optLong("modifiedAt"))+1);
        return result;
    }


    void mergeCloudSnapshot(SyncLedger remote,double now)throws Exception {
        JSONObject localState=materialize(),remoteState=remote.materialize();
        SyncLedger combined=new SyncLedger(shallowCopy(value).put("records",shallowCopy(records())));
        combined.merge(remote.changes(0));JSONObject state=combined.materialize();
        // Confirmation alone changes pending membership, not the plan revision.
        Set<String> confirmed=new HashSet<>();
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(!Planner.pending(task))confirmed.add(task.getString("id"));
        Set<String> localCourses=new HashSet<>(),remoteCourses=new HashSet<>();
        for(JSONObject c:Planner.list(localState.getJSONArray("courses")))localCourses.add(c.getString("id"));
        for(JSONObject c:Planner.list(remoteState.getJSONArray("courses")))remoteCourses.add(c.getString("id"));
        Map<String,Set<String>> a=pendingPlans(localState),b=pendingPlans(remoteState);
        for(Map<String,Set<String>> plans:Arrays.asList(a,b))for(Set<String> tasks:plans.values())tasks.removeAll(confirmed);
        Set<String> shared=new HashSet<>(localCourses);shared.retainAll(remoteCourses);
        Set<String> differing=new HashSet<>();for(String course:shared)if(!a.getOrDefault(course,Collections.emptySet()).equals(b.getOrDefault(course,Collections.emptySet())))differing.add(course);
        Map<String,JSONObject> av=planVersions(differing),bv=remote.planVersions(differing);Set<String> keep=new HashSet<>();
        for(JSONObject task:Planner.list(localState.getJSONArray("tasks")))if(!remoteCourses.contains(task.getString("courseID")))keep.add(task.getString("id"));
        for(JSONObject task:Planner.list(remoteState.getJSONArray("tasks")))if(!localCourses.contains(task.getString("courseID")))keep.add(task.getString("id"));
        for(String course:shared){
            boolean useRemote=false;
            if(differing.contains(course)){
                JSONObject left=av.get(course),right=bv.get(course);
                if(left!=null&&right!=null){if(equivalent(left,right)||!((left.optLong("modifiedAt")>0&&right.optLong("modifiedAt")>0)||(left.optLong("modifiedAt")>0&&left.getLong("version")>right.getLong("version"))||(right.optLong("modifiedAt")>0&&right.getLong("version")>left.getLong("version"))))throw new IllegalStateException("两端旧课表缺少修改时间，未上传或覆盖；请从备份核对日程。");useRemote=wins(right,left);}
                else useRemote=left==null;
            }
            keep.addAll((useRemote?b:a).getOrDefault(course,Collections.emptySet()));
        }
        JSONArray tasks=new JSONArray();
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(!Planner.pending(task)||keep.contains(task.getString("id")))tasks.put(task);
        state.put("tasks",tasks);if(SyncExchange.invalidPending(state,now))Planner.replan(state,now);combined.capture(state);
        Iterator<String> names=combined.value.keys();while(names.hasNext()){String name=names.next();value.put(name,combined.value.get(name));}
    }
    static Map<String,Set<String>> pendingPlans(JSONObject state)throws Exception{
        Map<String,Set<String>> result=new HashMap<>();for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(task))result.computeIfAbsent(task.getString("courseID"),k->new HashSet<>()).add(task.getString("id"));return result;
    }
    Map<String,JSONObject> planVersions(Set<String> courses)throws Exception{
        Map<String,JSONObject> result=new HashMap<>();if(courses.isEmpty())return result;
        List<JSONObject> tasks=new ArrayList<>();Iterator<String> keys=records().keys();while(keys.hasNext()){JSONObject row=records().getJSONObject(keys.next());if(row.getString("kind").equals("tasks"))tasks.add(row);}
        tasks.sort((a,b)->{try{return wins(a,b)?-1:wins(b,a)?1:0;}catch(Exception error){throw new IllegalArgumentException(error);}});
        for(JSONObject row:tasks){try{JSONObject task=payload(row);String course=task.getString("courseID");if(Planner.pending(task)&&courses.contains(course)&&!result.containsKey(course))result.put(course,fieldVersion(row));}catch(Exception error){if(!row.getBoolean("deleted"))throw error;}if(result.size()==courses.size())break;}return result;
    }

    public JSONObject materialize()throws Exception{
        JSONObject s=new JSONObject().put("schemaVersion",1);for(String kind:KINDS)if(!kind.equals("settings"))s.put(kind,new JSONArray());
        List<String> keys=new ArrayList<>();Iterator<String> it=records().keys();while(it.hasNext())keys.add(it.next());Collections.sort(keys);
        for(String k:keys){JSONObject r=records().getJSONObject(k);if(r.getBoolean("deleted"))continue;String kind=r.getString("kind");JSONObject p=payload(r);if(kind.equals("settings"))s.put(kind,p);else{if(!r.getString("id").equals(p.getString("id")))throw new IllegalArgumentException("记录 ID 不匹配");s.getJSONArray(kind).put(kind.equals("courses")?CourseSourcePrivacy.course(p):p);}}
        for(JSONObject task:Planner.list(s.getJSONArray("tasks")))Planner.validateTaskData(task);
        Planner.validateSettingsNumbers(s.getJSONObject("settings"));
        for(JSONObject event:Planner.list(s.getJSONArray("fixedEvents")))Planner.validateEventWindow(event);
        Planner.validateCourseNumbers(s.getJSONArray("courses"),Collections.emptySet());
        Set<String> deletedIDs=new HashSet<>();for(String k:keys){JSONObject r=records().getJSONObject(k);if(r.getString("kind").equals("courses")&&r.getBoolean("deleted"))deletedIDs.add(r.getString("id"));}
        for(JSONObject course:Planner.list(s.getJSONArray("courses")))if(course.optBoolean("isArchived"))deletedIDs.add(course.getString("id"));
        // Validate original numbers before merged-course recovery or task reconciliation
        // reads them through JSONObject's truncating integer getters.
        Set<String> confirmationTasks=new HashSet<>();for(JSONObject record:Planner.list(s.getJSONArray("completions"))){Planner.validateCompletionData(record);confirmationTasks.add(record.getString("taskID"));}
        Map<String,JSONObject> deletedTasks=new HashMap<>();
        for(String k:keys){
            JSONObject row=records().getJSONObject(k);
            if(row.getString("kind").equals("tasks")&&row.getBoolean("deleted")&&confirmationTasks.contains(row.getString("id"))){
                JSONObject task=payload(row);
                if(!row.getString("id").equals(task.getString("id")))throw new IllegalArgumentException("已删除任务的记录 ID 不匹配");
                Planner.validateTaskData(task);
                deletedTasks.put(row.getString("id"),task);
            }
        }
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
            String id=record.getString("taskID");
            if(completions.putIfAbsent(id,record)!=null)throw new IllegalArgumentException("同一任务存在多条完成记录");
            JSONObject row=records().optJSONObject("tasks/"+id);
            if(!tasks.containsKey(id)&&row!=null&&row.getBoolean("deleted")){
                JSONObject old=payload(row);
                if(!record.getString("courseID").equals(old.getString("courseID")))throw new IllegalArgumentException("完成记录与关联任务的课程不一致");
                if(!Planner.hasConfirmationTime(old))tasks.put(id,old);
            }
        }
        for(JSONObject task:tasks.values()){
            String id=task.getString("id");JSONObject row=records().optJSONObject("completions/"+Planner.stableID("completion|"+id));
            JSONObject record=completions.get(id);
            if(record!=null&&!record.getString("courseID").equals(task.getString("courseID")))throw new IllegalArgumentException("完成记录与关联任务的课程不一致");
            if(row!=null&&row.getBoolean("deleted")){
                if(Planner.hasConfirmationTime(task))task.put("status","planned");task.remove("confirmedAt");task.put("completedMinutes",0);
            }else if(record!=null){
                int minutes=record.getInt("minutes");if(minutes<0||minutes>task.getInt("durationMinutes"))throw new IllegalArgumentException("确认时长无效");
                task.put("confirmedAt",record.getDouble("recordedAt")).put("completedMinutes",minutes)
                    .put("status",minutes==0?"missed":minutes==task.getInt("durationMinutes")?"completed":"partial");
            }
        }
        state.put("tasks",new JSONArray(tasks.values()));
        SyncExchange.reconcileTasks(this,state);
        Set<String> kept=new HashSet<>();for(JSONObject task:Planner.list(state.getJSONArray("tasks")))kept.add(task.getString("id"));
        JSONArray result=new JSONArray();for(JSONObject record:completions.values())if(!tasks.containsKey(record.getString("taskID"))||kept.contains(record.getString("taskID")))result.put(record);
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(Planner.hasConfirmationTime(task)&&!completions.containsKey(task.getString("id"))){
            int minutes=task.getInt("completedMinutes");if(minutes<0||minutes>task.getInt("durationMinutes"))throw new IllegalArgumentException("确认时长无效");
            result.put(new JSONObject().put("id",Planner.stableID("completion|"+task.getString("id"))).put("taskID",task.getString("id")).put("courseID",task.getString("courseID"))
                .put("minutes",minutes).put("recordedAt",task.getDouble("confirmedAt")));
        }
        // Stable order prevents no-op captures from appearing as new edits.
        List<JSONObject> sorted=Planner.list(result);sorted.sort(Comparator.comparing(r->r.optString("id")));state.put("completions",new JSONArray(sorted));
    }

}
