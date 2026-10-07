package local.studyplanner;

import org.json.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;

/** Compatible with the desktop Codable data (seconds since 2001-01-01 UTC). */
public final class Planner {
    public static final long EPOCH = 978307200L;
    public static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");
    public static List<JSONObject> list(JSONArray a) { List<JSONObject> r=new ArrayList<>(); for(int i=0;i<a.length();i++)r.add(a.optJSONObject(i)); return r; }
    public static JSONArray array(Collection<JSONObject> a){return new JSONArray(a);}
    public static String stableID(String text) {
        try { byte[] b=java.security.MessageDigest.getInstance("SHA-256").digest(text.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            b[6]=(byte)((b[6]&15)|80);b[8]=(byte)((b[8]&63)|128);
            java.nio.ByteBuffer v=java.nio.ByteBuffer.wrap(b);return new UUID(v.getLong(),v.getLong()).toString().toUpperCase(Locale.ROOT);
        } catch(Exception e){throw new IllegalStateException(e);}
    }
    public static String id(){return UUID.randomUUID().toString().toUpperCase(Locale.ROOT);}
    static boolean canonicalID(String value){
        try{return UUID.fromString(value).toString().toUpperCase(Locale.ROOT).equals(value);}catch(Exception ignored){return false;}
    }
    /** 1.2 shipped seven readable default IDs that Swift's UUID decoder cannot accept. */
    static boolean migrateLegacyAvailabilityIDs(JSONObject state)throws Exception {
        boolean changed=false;JSONArray availability=state.getJSONObject("settings").getJSONArray("availability");
        for(int i=0;i<availability.length();i++){
            JSONObject item=availability.getJSONObject(i);String value=item.optString("id","");
            if(canonicalID(value))continue;
            if(!value.matches("default-availability-[1-7]"))throw new IllegalArgumentException("可学习时段 ID 无效");
            item.put("id",stableID("availability|legacy|"+value));changed=true;
        }
        return changed;
    }
    public static double now(){return System.currentTimeMillis()/1000.0-EPOCH;}
    public static LocalDate day(double s){return Instant.ofEpochMilli((long)((s+EPOCH)*1000)).atZone(ZONE).toLocalDate();}
    public static double at(LocalDate d,int m){return d.atStartOfDay(ZONE).plusMinutes(m).toEpochSecond()-EPOCH;}
    public static String date(double s){return day(s).toString();}
    public static String clock(double s){return Instant.ofEpochMilli((long)((s+EPOCH)*1000)).atZone(ZONE).format(DateTimeFormatter.ofPattern("HH:mm"));}
    public static String time(int m){return String.format(Locale.ROOT,"%02d:%02d",m/60,m%60);}
    public static int minute(String t){String[] a=t.trim().split(":"); if(a.length!=2)throw new IllegalArgumentException("时间格式为 HH:mm");int h=Integer.parseInt(a[0]),m=Integer.parseInt(a[1]);if(h<0||h>24||m<0||m>59||(h==24&&m!=0))throw new IllegalArgumentException("时间超出范围");return h*60+m;}
    public static int weekday(LocalDate d){return d.getDayOfWeek().getValue()%7+1;}
    public static double end(JSONObject t){return t.optDouble("start")+60*t.optInt("durationMinutes");}
    public static boolean floating(JSONObject e){return e.has("floatingDurationMinutes")&&!e.isNull("floatingDurationMinutes");}
    public static int occupied(JSONObject e){return floating(e)?e.optInt("floatingDurationMinutes"):e.optInt("endMinute")-e.optInt("startMinute");}
    public static double planningStart(JSONObject t){return t.optDouble("floatingWindowStart",t.optDouble("start"));}
    public static double planningEnd(JSONObject t){return t.optDouble("floatingWindowEnd",end(t));}
    public static double retainedHistoryStart(JSONObject t){return Math.min(planningStart(t),t.optDouble("confirmedAt",planningStart(t)));}
    public static double retainedHistoryEnd(JSONObject t){return Math.min(planningEnd(t),t.optDouble("confirmedAt",planningEnd(t)));}
    public static boolean floatingTask(JSONObject t){return t.has("floatingWindowStart")&&t.has("floatingWindowEnd");}
    static Map<String,Integer> reserve(List<JSONObject> events){return reserve(events,new boolean[1440]);}
    static Map<String,Integer> reserve(List<JSONObject> events,boolean[] study){
        boolean[] busy=new boolean[1440];List<JSONObject> floats=new ArrayList<>();
        for(JSONObject e:events){int a=e.optInt("startMinute"),b=e.optInt("endMinute"),n=occupied(e);if(a<0||b>1440||a>=b||n<=0||n>b-a)return null;
            if(floating(e))floats.add(e);else for(int m=a;m<b;m++)busy[m]=true;}
        floats.sort((a,b)->{int x=a.optInt("endMinute")-a.optInt("startMinute")-occupied(a),y=b.optInt("endMinute")-b.optInt("startMinute")-occupied(b);return x!=y?Integer.compare(x,y):a.optString("id").compareTo(b.optString("id"));});
        int[] prefix=new int[1441];for(int m=0;m<1440;m++)prefix[m+1]=prefix[m]+(study[m]&&!busy[m]?1:0);
        List<List<int[]>> candidates=new ArrayList<>();
        for(JSONObject e:floats){List<int[]> choices=new ArrayList<>();int n=occupied(e);
            for(int start=e.optInt("startMinute");start<=e.optInt("endMinute")-n;start++)choices.add(new int[]{start,prefix[start+n]-prefix[start]});
            choices.sort((a,b)->a[1]!=b[1]?Integer.compare(a[1],b[1]):Integer.compare(b[0],a[0]));candidates.add(choices);}
        int[] lower=new int[floats.size()+1];for(int i=floats.size()-1;i>=0;i--)lower[i]=lower[i+1]+candidates.get(i).get(0)[1];
        PlacementSearch search=new PlacementSearch();
        reserveSearch(floats,candidates,lower,0,0,busy,new HashMap<>(),search);return search.best;
    }
    static class PlacementSearch {int attempts=0,cost=Integer.MAX_VALUE;Map<String,Integer> best;}
    static void reserveSearch(List<JSONObject> events,List<List<int[]>> candidates,int[] lower,int index,int cost,boolean[] busy,Map<String,Integer> placements,PlacementSearch search){
        if(cost+lower[index]>=search.cost||search.attempts>=20000)return;
        if(index==events.size()){search.best=new HashMap<>(placements);search.cost=cost;return;}
        JSONObject e=events.get(index);int n=occupied(e);
        for(int[] candidate:candidates.get(index)){if(cost+candidate[1]+lower[index+1]>=search.cost||search.attempts>=20000)break;
            search.attempts++;int a=candidate[0];boolean free=true;for(int m=a;m<a+n;m++)if(busy[m]){free=false;break;}if(!free)continue;
            for(int m=a;m<a+n;m++)busy[m]=true;placements.put(e.optString("id"),a);
            reserveSearch(events,candidates,lower,index+1,cost+candidate[1],busy,placements,search);
            placements.remove(e.optString("id"));for(int m=a;m<a+n;m++)busy[m]=false;
        }
    }
    public static boolean pending(JSONObject t){return !t.has("confirmedAt")&&(t.optString("status").equals("planned")||t.optString("status").equals("future"));}
    public static JSONObject course(JSONObject s,String id){for(JSONObject c:list(s.optJSONArray("courses")))if(c.optString("id").equals(id))return c;return null;}
    public static void removeCourse(JSONObject s,String id)throws Exception{removeCourses(s,Collections.singleton(id));}
    public static void removeCourses(JSONObject s,Set<String> ids)throws Exception{
        for(String kind:new String[]{"courses","tasks","completions"}){
            JSONArray rows=s.getJSONArray(kind);
            for(int i=rows.length()-1;i>=0;i--)if(ids.contains(rows.getJSONObject(i).getString(kind.equals("courses")?"id":"courseID")))rows.remove(i);
        }
    }
    public static void removeArchivedCourses(JSONObject s)throws Exception{
        Set<String> ids=new HashSet<>();for(JSONObject c:list(s.getJSONArray("courses")))if(c.optBoolean("isArchived"))ids.add(c.getString("id"));
        removeCourses(s,ids);
    }
    public static int completed(JSONObject s,JSONObject c){int v=Math.max(0,c.optInt("initialCompletedMinutes"));for(JSONObject r:list(s.optJSONArray("completions")))if(r.optString("courseID").equals(c.optString("id")))v+=r.optInt("minutes");return Math.min(c.optInt("totalMinutes"),v);}
    public static int remaining(JSONObject s,JSONObject c){return Math.max(0,c.optInt("totalMinutes")-completed(s,c));}
    public static boolean occurs(JSONObject e,LocalDate d){return occurs(e,d,false);}
    public static boolean occurs(JSONObject e,LocalDate d,boolean includingExcluded){if(d.isBefore(day(e.optDouble("startDate")))||d.isAfter(day(e.optDouble("endDate"))))return false;JSONArray excluded=e.optJSONArray("excludedDates");if(!includingExcluded&&excluded!=null)for(int i=0;i<excluded.length();i++)if(day(excluded.optDouble(i)).equals(d))return false;JSONArray w=e.optJSONArray("weekdays");if(w==null||w.length()==0)return d.equals(day(e.optDouble("startDate")));for(int i=0;i<w.length();i++)if(w.optInt(i)==weekday(d))return true;return false;}
    public static List<JSONObject> review(JSONObject s,double now){List<JSONObject> out=new ArrayList<>();LocalDate today=day(now);int m=(int)((now-at(today,0))/60);for(JSONObject t:list(s.optJSONArray("tasks"))){JSONObject c=course(s,t.optString("courseID"));if(pending(t)&&c!=null&&!c.optBoolean("isArchived")&&(planningEnd(t)<=at(today,0)||(m>=s.optJSONObject("settings").optInt("notificationMinute")&&planningEnd(t)<=now)))out.add(t);}return out;}
    // Ended work may already be redistributed; floating work stays reserved until its window ends.
    public static boolean confirmationRequiresReplan(JSONObject task,int actual,double now){return actual!=task.optInt("durationMinutes")||planningEnd(task)<=now;}
    public static void confirm(JSONObject s,String taskID,int actual,double now)throws Exception{JSONObject t=null;for(JSONObject v:list(s.getJSONArray("tasks")))if(v.getString("id").equals(taskID))t=v;if(t==null||!pending(t))throw new IllegalArgumentException("该任务已确认，请刷新后重试");if(actual<0||actual>t.getInt("durationMinutes"))throw new IllegalArgumentException("实际时长必须在 0 与计划时长之间");JSONObject c=course(s,t.getString("courseID"));if(c==null)throw new IllegalArgumentException("找不到课程");int credit=Math.min(actual,remaining(s,c));t.put("completedMinutes",credit).put("confirmedAt",now).put("status",actual==0?"missed":actual==t.getInt("durationMinutes")?"completed":"partial");s.getJSONArray("completions").put(new JSONObject().put("id",stableID("completion|"+taskID)).put("courseID",c.getString("id")).put("taskID",taskID).put("minutes",credit).put("recordedAt",now));}
    public static void undoConfirmation(JSONObject s,String taskID,double now)throws Exception{JSONObject t=null;for(JSONObject v:list(s.getJSONArray("tasks")))if(v.getString("id").equals(taskID))t=v;if(t==null||!t.has("confirmedAt"))throw new IllegalArgumentException("该任务尚未确认，无需撤销");JSONArray records=s.getJSONArray("completions");boolean removed=false;for(int i=records.length()-1;i>=0;i--)if(records.getJSONObject(i).optString("taskID").equals(taskID)){records.remove(i);removed=true;}if(!removed)throw new IllegalArgumentException("找不到该任务的完成记录");t.remove("confirmedAt");t.put("completedMinutes",0).put("status",day(t.getDouble("start")).equals(day(now))?"planned":"future");JSONObject c=course(s,t.getString("courseID"));if(c!=null)reconcileWebsiteBaseline(s,c);}

    static void reconcileWebsiteBaseline(JSONObject state,JSONObject course)throws Exception {
        JSONArray sources=course.optJSONArray("mergedSources");
        if(sources!=null){
            int initial=0;
            for(JSONObject source:list(sources)){
                String prefix=source.getString("id")+"/";JSONArray tasks=new JSONArray(),records=new JSONArray();Set<String> ids=new HashSet<>();
                for(JSONObject task:list(state.optJSONArray("tasks")))if(task.optString("courseID").equals(course.optString("id"))&&task.optString("lessonID").startsWith(prefix)){
                    JSONObject copy=new JSONObject(task.toString());copy.put("courseID",source.getString("id")).put("lessonID",task.getString("lessonID").substring(prefix.length()));tasks.put(copy);ids.add(task.getString("id"));
                }
                for(JSONObject record:list(state.optJSONArray("completions")))if(record.optString("courseID").equals(course.optString("id"))&&ids.contains(record.optString("taskID"))){
                    JSONObject copy=new JSONObject(record.toString());copy.put("courseID",source.getString("id"));records.put(copy);
                }
                reconcileWebsiteBaseline(new JSONObject().put("tasks",tasks).put("completions",records),source);initial+=source.optInt("initialCompletedMinutes");
            }
            course.put("initialCompletedMinutes",initial);return;
        }
        JSONObject snapshot=course.optJSONObject("webCourse"),overlaps=course.optJSONObject("webCompletionOverlaps");
        if(snapshot==null||overlaps==null||snapshot.optJSONArray("lessons")==null)return;
        double total=0,left=0;Set<String> known=new HashSet<>();
        for(JSONObject lesson:list(snapshot.getJSONArray("lessons")))if(lesson.optBoolean("published")&&lesson.optBoolean("requiresDuration")){
            double seconds=lesson.optDouble("durationSeconds",0),percent=lesson.optDouble("watchedPercent",0);
            if(!Double.isFinite(seconds)||seconds<=0||!Double.isFinite(percent)||percent<0||percent>100)return;
            total+=seconds;left+=seconds*(1-percent/100.0);known.add(lesson.optString("id"));
        }
        if(ceilMinutes(total)!=course.optInt("totalMinutes"))return;
        int website=ceilMinutes(total)-ceilMinutes(left),logged=0,unidentified=0,identified=0;
        Map<String,JSONObject> tasks=new HashMap<>();for(JSONObject task:list(state.optJSONArray("tasks")))if(task.optString("courseID").equals(course.optString("id")))tasks.put(task.optString("id"),task);
        Map<String,Integer> earlier=new HashMap<>();
        for(JSONObject record:list(state.optJSONArray("completions")))if(record.optString("courseID").equals(course.optString("id"))){
            int minutes=record.optInt("minutes");logged+=minutes;if(record.optDouble("recordedAt")>snapshot.optDouble("fetchedAt"))continue;
            JSONObject task=tasks.get(record.optString("taskID"));String id=task==null?"":task.optString("lessonID");
            if(known.contains(id))earlier.merge(id,minutes,Integer::sum);else unidentified+=minutes;
        }
        JSONObject remaining=new JSONObject();for(Iterator<String> keys=overlaps.keys();keys.hasNext();){String id=keys.next();int amount=Math.min(Math.max(0,overlaps.optInt(id)),earlier.getOrDefault(id,0));remaining.put(id,amount);identified+=amount;}
        int overlap=identified+Math.min(unidentified,Math.max(0,website-identified));
        course.put("webCompletionOverlaps",remaining).put("initialCompletedMinutes",Math.max(0,Math.min(course.optInt("totalMinutes")-logged,website-overlap)));
    }
    public static void put(JSONArray a,JSONObject v)throws Exception{for(int i=0;i<a.length();i++)if(a.getJSONObject(i).getString("id").equals(v.getString("id"))){a.put(i,v);return;}a.put(v);}
    static final class MergedDestination {
        final String courseID,prefix;
        MergedDestination(String courseID,String prefix){this.courseID=courseID;this.prefix=prefix;}
    }
    static void collectMergedSources(JSONArray sources,String destination,String prefix,Map<String,MergedDestination> targets)throws Exception {
        if(sources==null)return;
        for(JSONObject source:list(sources)){
            String id=source.getString("id"),path=prefix+id+"/";MergedDestination old=targets.get(id);
            if(old!=null&&(!old.courseID.equals(destination)||!old.prefix.equals(path)))throw new IllegalArgumentException("同一来源课程被并发合并到不同课程，请先核对合并结果");
            targets.put(id,new MergedDestination(destination,path));collectMergedSources(source.optJSONArray("mergedSources"),destination,path,targets);
        }
    }
    static void redirectMergedTask(JSONObject task,Set<String> deleted,Map<String,MergedDestination> targets)throws Exception {
        MergedDestination target=targets.get(task.getString("courseID"));
        if(deleted.contains(task.getString("courseID"))&&target!=null)task.put("lessonID",target.prefix+task.optString("lessonID","whole")).put("courseID",target.courseID);
    }
    public static void reconcileMergedCourseProgress(JSONObject state,Set<String> deleted,Map<String,JSONObject> deletedTasks)throws Exception {
        Map<String,MergedDestination> targets=new HashMap<>();
        for(JSONObject course:list(state.getJSONArray("courses")))if(!course.optBoolean("isArchived")&&!deleted.contains(course.getString("id")))collectMergedSources(course.optJSONArray("mergedSources"),course.getString("id"),"",targets);
        Set<String> mergedIDs=new HashSet<>();for(MergedDestination target:targets.values())mergedIDs.add(target.courseID);
        Map<String,JSONObject> tasks=new HashMap<>();for(JSONObject task:list(state.getJSONArray("tasks"))){redirectMergedTask(task,deleted,targets);tasks.put(task.getString("id"),task);}
        for(JSONObject record:list(state.getJSONArray("completions"))){
            MergedDestination target=targets.get(record.getString("courseID"));
            if(deleted.contains(record.getString("courseID"))&&target!=null)record.put("courseID",target.courseID);
            if(!mergedIDs.contains(record.getString("courseID")))continue;
            String id=record.getString("taskID");JSONObject task=tasks.get(id);
            if(task==null&&deletedTasks.containsKey(id)){
                JSONObject recovered=new JSONObject(deletedTasks.get(id).toString());redirectMergedTask(recovered,deleted,targets);
                if(recovered.getString("courseID").equals(record.getString("courseID"))){task=recovered;state.getJSONArray("tasks").put(task);tasks.put(id,task);}
            }
            if(task!=null&&task.getString("courseID").equals(record.getString("courseID"))){
                int minutes=record.getInt("minutes");if(minutes<0||minutes>task.getInt("durationMinutes"))throw new IllegalArgumentException("合并课程的确认时长无效");
                if(task.has("confirmedAt")&&task.getDouble("confirmedAt")==record.getDouble("recordedAt")&&task.optInt("completedMinutes")==minutes)continue;
                task.put("completedMinutes",minutes).put("confirmedAt",record.getDouble("recordedAt")).put("status",minutes==0?"missed":minutes==task.getInt("durationMinutes")?"completed":"partial");
            }
        }
    }
    public static void prepareForOpen(JSONObject state,double now)throws Exception {
        validate(state);removeArchivedCourses(state);replan(state,now);validate(state);
    }
    public static boolean isManualLessonCourse(JSONObject course,String type){
        return "不定时录播课程".equals(type)&&course.optJSONObject("webCourse")==null&&course.optJSONArray("mergedSources")==null;
    }
    public static JSONArray parseManualLessons(String lines,JSONObject course)throws Exception {
        List<JSONObject> rows=new ArrayList<>(),old=course.optJSONArray("manualLessons")==null?new ArrayList<>():list(course.optJSONArray("manualLessons"));
        for(String line:lines.split("\n")){line=line.trim();if(line.isEmpty())continue;int colon=line.lastIndexOf(':');
            if(colon<=0)throw new IllegalArgumentException("课节格式为：名称:分钟，每行一节");
            String name=line.substring(0,colon).trim();int minutes=Integer.parseInt(line.substring(colon+1).trim());
            if(name.isEmpty()||minutes<1||minutes>1440)throw new IllegalArgumentException("课节名称不能为空，时长须为 1–1440 分钟");
            rows.add(new JSONObject().put("name",name).put("durationMinutes",minutes));
        }
        if(rows.isEmpty())throw new IllegalArgumentException("请至少录入一节课");
        Set<String> used=new HashSet<>();
        // Match identity before considering row position, so inserts/deletes/reorders are safe.
        for(JSONObject row:rows)for(JSONObject previous:old)if(!used.contains(previous.getString("id"))&&row.getString("name").equals(previous.getString("name"))&&row.getInt("durationMinutes")==previous.getInt("durationMinutes")){
            row.put("id",previous.getString("id"));used.add(previous.getString("id"));break;
        }
        for(JSONObject row:rows)if(!row.has("id")){
            List<JSONObject> matches=new ArrayList<>();for(JSONObject previous:old)if(!used.contains(previous.getString("id"))&&row.getString("name").equals(previous.getString("name")))matches.add(previous);
            if(matches.size()==1){row.put("id",matches.get(0).getString("id"));used.add(matches.get(0).getString("id"));}
        }
        List<JSONObject> unmatched=new ArrayList<>(),remaining=new ArrayList<>();
        for(JSONObject row:rows)if(!row.has("id"))unmatched.add(row);
        for(JSONObject previous:old)if(!used.contains(previous.getString("id")))remaining.add(previous);
        if(rows.size()==old.size()&&unmatched.size()==1&&remaining.size()==1)unmatched.get(0).put("id",remaining.get(0).getString("id"));
        else if(!unmatched.isEmpty()&&!remaining.isEmpty())throw new IllegalArgumentException("无法确定修改后的课节对应关系。请先单独修改一节名称，再添加或删除课节。");
        for(JSONObject row:rows)if(!row.has("id"))row.put("id",id());
        return new JSONArray(rows);
    }
    public static void updateManualLessons(JSONObject course,JSONArray parsed)throws Exception {
        JSONArray old=course.optJSONArray("manualLessons"),preferred=course.optJSONArray("lessonOrder");
        Map<String,Integer> ranks=new HashMap<>();List<String> original=new ArrayList<>(),incoming=new ArrayList<>();
        if(old!=null)for(JSONObject lesson:list(old)){String id=lesson.getString("id");ranks.put(id,ranks.size());original.add(id);}
        Set<String> ids=new HashSet<>();int total=0;for(JSONObject lesson:list(parsed)){String id=lesson.getString("id");ids.add(id);if(ranks.containsKey(id))incoming.add(id);total+=lesson.getInt("durationMinutes");}
        original.removeIf(id->!ids.contains(id));
        List<String> order=new ArrayList<>();
        if(preferred!=null&&original.equals(incoming))for(int i=0;i<preferred.length();i++){String id=preferred.getString(i);if(ids.contains(id)&&!order.contains(id))order.add(id);}
        for(JSONObject lesson:list(parsed)){String id=lesson.getString("id");if(!order.contains(id))order.add(id);}
        // Baseline progress follows source order; changing study order must not move that credit.
        List<JSONObject> source=list(parsed);source.sort(Comparator.comparingInt(lesson->ranks.getOrDefault(lesson.optString("id"),Integer.MAX_VALUE)));
        course.put("manualLessons",new JSONArray(source)).put("lessonOrder",new JSONArray(order)).put("totalMinutes",total);
    }
    public static void validateCourseEdit(JSONObject state,JSONObject course,double now)throws Exception {
        int total=course.getInt("totalMinutes"),initial=course.getInt("initialCompletedMinutes"),logged=0;
        for(JSONObject record:list(state.getJSONArray("completions")))if(record.optString("courseID").equals(course.getString("id")))logged+=record.getInt("minutes");
        if(total<=0||total>600000||initial<0||initial>(long)total-logged)throw new IllegalArgumentException("总时长须在 10,000 小时以内，基础量与已确认进度不能超过总时长");
        LocalDate start=day(course.getDouble("startDate")),deadline=day(course.getDouble("deadline"));
        if(deadline.isBefore(start)||deadline.isAfter(day(now).plusYears(10)))throw new IllegalArgumentException("截止日期须晚于或等于开始日期，且在未来十年以内");
        if(course.optInt("minimumBlockMinutes")<0||course.optInt("minimumBlockMinutes")>1440)throw new IllegalArgumentException("最小时间块无效");
    }
    public static void validate(JSONObject s)throws Exception{if(s.getInt("schemaVersion")!=1)throw new IllegalArgumentException("不支持此备份版本");for(String key:new String[]{"courses","fixedEvents","tasks","completions"}){Set<String> ids=new HashSet<>();for(JSONObject o:list(s.getJSONArray(key)))if(o==null||!ids.add(o.getString("id")))throw new IllegalArgumentException("数据缺少 ID 或重复");}JSONObject settings=s.getJSONObject("settings");if(settings.getInt("minimumScheduleUnit")<1)throw new IllegalArgumentException("最小时间块无效");migrateLegacyAvailabilityIDs(s);Set<String> availabilityIDs=new HashSet<>();for(JSONObject a:list(settings.getJSONArray("availability")))if(a==null||!canonicalID(a.optString("id"))||!availabilityIDs.add(a.getString("id"))||a.getInt("weekday")<1||a.getInt("weekday")>7||a.getInt("startMinute")<0||a.getInt("endMinute")>1440||a.getInt("startMinute")>=a.getInt("endMinute"))throw new IllegalArgumentException("可学习时段数据无效");for(JSONObject t:list(s.getJSONArray("tasks")))if(course(s,t.getString("courseID"))==null||t.getInt("durationMinutes")<=0)throw new IllegalArgumentException("任务数据不完整");}
    public static final class EventConflict {
        public final String eventID,title,reason;
        public final LocalDate date;
        public final int start,end,requestedStart,requestedEnd;
        public final Integer floatingMinutes;
        EventConflict(String id,String title,LocalDate date,int start,int end,int requestedStart,int requestedEnd,Integer minutes,String reason){
            this.eventID=id;this.title=title;this.date=date;this.start=start;this.end=end;this.requestedStart=requestedStart;this.requestedEnd=requestedEnd;this.floatingMinutes=minutes;this.reason=reason;
        }
        public String timeDescription(){return time(start)+"–"+time(end)+(floatingMinutes==null?"":" · 浮动占用 "+floatingMinutes+" 分钟");}
        public String explanation(){
            if(reason.equals("active"))return "该学习任务正在进行或处于已开始的浮动窗口，不能自动移动。";
            if(reason.equals("capacity"))return "这些事项的连续时长无法在重叠窗口内排入；请调整时段或跳过此日。";
            int a=Math.max(start,requestedStart),b=Math.min(end,requestedEnd);
            return "重叠 "+time(a)+"–"+time(b)+"（"+Math.max(0,b-a)+" 分钟）";
        }
    }
    public static final class EventConflictException extends IllegalArgumentException {
        public final List<EventConflict> conflicts;
        EventConflictException(List<EventConflict> conflicts){super(conflictMessage(conflicts));this.conflicts=Collections.unmodifiableList(new ArrayList<>(conflicts));}
    }
    static String conflictMessage(List<EventConflict> conflicts){
        StringBuilder out=new StringBuilder();for(EventConflict c:conflicts){if(out.length()>0)out.append("\n");out.append(c.date).append(" · 「").append(c.title).append("」").append(c.timeDescription()).append("；").append(c.explanation());}return out.toString();
    }
    public static void saveEvent(JSONObject s,JSONObject event,double now)throws Exception{saveEvent(s,event,now,Collections.emptySet());}
    public static void saveEvent(JSONObject s,JSONObject event,double now,Set<LocalDate> skippingDates)throws Exception{
        JSONObject input=event; event=new JSONObject(event.toString());
        Set<LocalDate> excluded=new TreeSet<>(skippingDates);JSONArray oldExcluded=event.optJSONArray("excludedDates");
        if(oldExcluded!=null)for(int i=0;i<oldExcluded.length();i++)excluded.add(day(oldExcluded.getDouble(i)));
        JSONArray updatedExcluded=new JSONArray();for(LocalDate date:excluded)updatedExcluded.put(at(date,0));event.put("excludedDates",updatedExcluded);
        int start=event.getInt("startMinute"),end=event.getInt("endMinute");if(start<0||end>1440||start>=end||occupied(event)<=0||occupied(event)>end-start)throw new IllegalArgumentException("结束时间必须晚于开始时间");
        JSONObject old=null;JSONArray events=s.getJSONArray("fixedEvents");for(JSONObject e:list(events))if(e.getString("id").equals(event.getString("id")))old=e;
        LocalDate today=day(now),boundary=today;if(old!=null&&occurs(old,today)&&at(today,old.getInt("startMinute"))<=now)boundary=today.plusDays(1);
        LocalDate first=day(event.getDouble("startDate"));if(first.isBefore(boundary))first=boundary;LocalDate last=day(event.getDouble("endDate"));if(last.isBefore(first))throw new IllegalArgumentException("历史事项不可修改，请添加未来事项");if(last.isAfter(today.plusYears(10)))throw new IllegalArgumentException("固定事项最多支持未来十年");event.put("startDate",at(first,0));
        List<EventConflict> conflicts=new ArrayList<>();
        for(LocalDate d=first;!d.isAfter(last);d=d.plusDays(1))if(occurs(event,d)){
            List<JSONObject> others=new ArrayList<>();
            for(JSONObject e:list(events))if(!e.getString("id").equals(event.getString("id"))&&occurs(e,d))others.add(e);
            List<JSONObject> component=new ArrayList<>();int lower=start,upper=end;boolean changed=true;
            while(changed){component.clear();for(JSONObject e:others)if(e.getInt("startMinute")<upper&&e.getInt("endMinute")>lower)component.add(e);
                int nextLower=lower,nextUpper=upper;for(JSONObject e:component){nextLower=Math.min(nextLower,e.getInt("startMinute"));nextUpper=Math.max(nextUpper,e.getInt("endMinute"));}
                changed=lower!=nextLower||upper!=nextUpper;lower=nextLower;upper=nextUpper;}
            List<JSONObject> combined=new ArrayList<>(component);combined.add(event);boolean capacity=reserve(combined)==null;
            for(JSONObject e:component){
                boolean exact=!floating(event)&&!floating(e)&&e.getInt("startMinute")<end&&e.getInt("endMinute")>start;
                if(capacity||exact)conflicts.add(new EventConflict(e.getString("id"),e.getString("title"),d,e.getInt("startMinute"),e.getInt("endMinute"),start,end,floating(e)?occupied(e):null,exact?"overlap":"capacity"));
            }
            if(capacity&&component.isEmpty())throw new IllegalArgumentException("请检查浮动事项的时段和占用时长");
        }
        if(!conflicts.isEmpty()){conflicts.sort(Comparator.comparing((EventConflict c)->c.date).thenComparingInt(c->c.start).thenComparing(c->c.eventID));throw new EventConflictException(conflicts);}
        if(old!=null&&day(old.getDouble("startDate")).isBefore(boundary)){old.put("endDate",Math.min(old.getDouble("endDate"),at(boundary.minusDays(1),0)));event.put("id",id());}put(events,event);
        input.put("id",event.get("id")).put("startDate",event.get("startDate")).put("excludedDates",event.get("excludedDates"));
    }
    public static void removeEvent(JSONObject s,String id,double now)throws Exception{JSONArray a=s.getJSONArray("fixedEvents");for(int i=0;i<a.length();i++){JSONObject e=a.getJSONObject(i);if(!e.getString("id").equals(id))continue;LocalDate today=day(now);LocalDate b=occurs(e,today)&&at(today,e.getInt("startMinute"))<=now?today.plusDays(1):today;if(day(e.getDouble("startDate")).isBefore(b))e.put("endDate",Math.min(e.getDouble("endDate"),at(b.minusDays(1),0)));else a.remove(i);return;}}
    public static void setEventSkipped(JSONObject s,String id,LocalDate date,boolean skipped,double now)throws Exception{
        if(date.isBefore(day(now)))throw new IllegalArgumentException("只能临时移除或恢复今天及未来的固定事项，往日记录保留。");
        JSONObject event=null;for(JSONObject e:list(s.getJSONArray("fixedEvents")))if(e.getString("id").equals(id)){event=e;break;}
        if(event==null||!occurs(event,date,true))throw new IllegalArgumentException("该事项在所选日期没有安排，请刷新日程后重试。");
        if(!occurs(event,date)==skipped)return;
        Set<LocalDate> exclusions=new TreeSet<>();JSONArray old=event.optJSONArray("excludedDates");
        if(old!=null)for(int i=0;i<old.length();i++)exclusions.add(day(old.getDouble(i)));
        if(skipped)exclusions.add(date);else exclusions.remove(date);
        JSONArray updated=new JSONArray();for(LocalDate d:exclusions)updated.put(at(d,0));
        if(!skipped){
            JSONObject validation=new JSONObject(s.toString()),occurrence=new JSONObject(event.toString());
            occurrence.put("startDate",at(date,0)).put("endDate",at(date,0)).put("weekdays",new JSONArray()).put("excludedDates",updated);
            saveEvent(validation,occurrence,at(day(now),0));
        }
        event.put("excludedDates",updated);
    }
    public static final int BREAK_MINUTES=15;
    static final double BREAK_SECONDS=BREAK_MINUTES*60;
    // Repair and balancing can insert tasks before or after an existing task.
    static Span buffered(double start,double end){return new Span(start-BREAK_SECONDS,end+BREAK_SECONDS);}
    static class Span{double a,b;Span(double a,double b){this.a=a;this.b=b;}int minutes(){return Math.max(0,(int)((b-a)/60));}}
    static class Day{LocalDate d;List<Span> free;Day(LocalDate d,List<Span> f){this.d=d;free=f;}}
    static List<Span> merge(List<Span> a){List<Span> r=new ArrayList<>();a=new ArrayList<>(a);a.sort(Comparator.comparingDouble(v->v.a));for(Span s:a)if(s.b>s.a){if(!r.isEmpty()&&s.a<=r.get(r.size()-1).b)r.get(r.size()-1).b=Math.max(r.get(r.size()-1).b,s.b);else r.add(new Span(s.a,s.b));}return r;}
    static List<Span> subtract(List<Span> available,List<Span> blocks){List<Span> r=merge(available);for(Span b:merge(blocks)){List<Span> n=new ArrayList<>();for(Span s:r){if(b.a>=s.b||b.b<=s.a)n.add(s);else{if(s.a<b.a)n.add(new Span(s.a,b.a));if(b.b<s.b)n.add(new Span(b.b,s.b));}}r=n;}return r;}
    static boolean eligible(JSONObject c,LocalDate d){return !d.isBefore(day(c.optDouble("startDate")))&&!d.isAfter(day(c.optDouble("deadline")));}
    static int unit(JSONObject s,JSONObject c){return Math.max(1,c.optInt("minimumBlockMinutes")>0?c.optInt("minimumBlockMinutes"):s.optJSONObject("settings").optInt("minimumScheduleUnit"));}
    static class Work{int minutes;String lessonID,lessonName;Work(int n,String id,String name){minutes=n;lessonID=id;lessonName=name;}}
    static int ceilMinutes(double seconds){return (int)Math.ceil(seconds/60.0);}
    static List<Work> lessonWork(JSONObject s,JSONObject c){List<Work> items=lessonWorkAll(s,c);items.removeIf(w->w.minutes<=0);return items;}
    static List<Work> lessonWorkAll(JSONObject s,JSONObject c){
        List<Work> out=new ArrayList<>();if(!"不定时录播课程".equals(c.optString("type")))return out;
        JSONArray sources=c.optJSONArray("mergedSources");
        if(sources!=null){
            try {
                for(JSONObject source:list(sources)){
                    String prefix=source.getString("id")+"/";
                    JSONObject subset=new JSONObject();JSONArray tasks=new JSONArray(),records=new JSONArray();Set<String> taskIDs=new HashSet<>();
                    for(JSONObject t:list(s.optJSONArray("tasks")))if(t.optString("courseID").equals(c.optString("id"))&&t.optString("lessonID").startsWith(prefix)){
                        JSONObject copy=new JSONObject(t.toString());copy.put("courseID",source.getString("id")).put("lessonID",t.getString("lessonID").substring(prefix.length()));tasks.put(copy);taskIDs.add(t.getString("id"));
                    }
                    for(JSONObject r:list(s.optJSONArray("completions")))if(r.optString("courseID").equals(c.optString("id"))&&taskIDs.contains(r.optString("taskID"))){
                        JSONObject copy=new JSONObject(r.toString());copy.put("courseID",source.getString("id"));records.put(copy);
                    }
                    subset.put("tasks",tasks).put("completions",records);
                    List<Work> lessons=lessonWorkAll(subset,source);
                    if(lessons.isEmpty())lessons.add(new Work(source.optInt("totalMinutes")-completed(subset,source),"whole",source.optString("name")));
                    for(Work w:lessons){w.lessonID=prefix+w.lessonID;out.add(w);}
                }
                JSONArray preferred=c.optJSONArray("lessonOrder");
                if(preferred!=null){Map<String,Integer> rank=new HashMap<>();for(int i=0;i<preferred.length();i++)rank.putIfAbsent(preferred.optString(i),i);out.sort(Comparator.comparingInt(w->rank.getOrDefault(w.lessonID,Integer.MAX_VALUE)));}
                return out;
            }catch(org.json.JSONException error){throw new IllegalArgumentException("无法读取合并课程",error);}
        }
        JSONObject snapshot=c.optJSONObject("webCourse");JSONArray manual=c.optJSONArray("manualLessons");
        int baseline=0;
        List<Integer> websiteCredits=new ArrayList<>();
        if(snapshot!=null){
            double total=0,left=0;JSONArray lessons=snapshot.optJSONArray("lessons");if(lessons==null)return out;
            for(JSONObject l:list(lessons))if(l.optBoolean("published")&&l.optBoolean("requiresDuration")){
                double seconds=l.optDouble("durationSeconds",0),percent=l.optDouble("watchedPercent",0);
                if(seconds<=0||!Double.isFinite(seconds)||percent<0||percent>100)return new ArrayList<>();
                int previous=ceilMinutes(left),previousTotal=ceilMinutes(total);total+=seconds;left+=seconds*(1-percent/100.0);
                int remaining=ceilMinutes(left)-previous;
                websiteCredits.add(Math.max(0,ceilMinutes(total)-previousTotal-remaining));
                out.add(new Work(remaining,l.optString("id"),l.optString("name")));
            }
            if(ceilMinutes(total)!=c.optInt("totalMinutes"))return new ArrayList<>();
            baseline=Math.max(0,completed(s,c)-(ceilMinutes(total)-ceilMinutes(left)));
        }else if(manual!=null&&manual.length()>0){
            int total=0;for(JSONObject l:list(manual)){int n=l.optInt("durationMinutes");if(n<=0)return new ArrayList<>();total+=n;out.add(new Work(n,l.optString("id"),l.optString("name")));}
            if(total!=c.optInt("totalMinutes"))return new ArrayList<>();
            baseline=Math.max(0,c.optInt("initialCompletedMinutes"));
        }else return out;
        if(snapshot==null)for(Work w:out){int credit=Math.min(baseline,w.minutes);w.minutes-=credit;baseline-=credit;}
        int extra=snapshot==null?0:baseline;
        Map<String,JSONObject> taskByID=new HashMap<>();
        for(JSONObject t:list(s.optJSONArray("tasks")))if(t.optString("courseID").equals(c.optString("id")))taskByID.put(t.optString("id"),t);
        Map<String,Work> workByID=new HashMap<>();
        for(Work w:out)workByID.putIfAbsent(w.lessonID,w);
        Map<String,Integer> earlierCredits=new HashMap<>();
        for(JSONObject record:list(s.optJSONArray("completions"))){
            if(!record.optString("courseID").equals(c.optString("id")))continue;
            JSONObject task=taskByID.get(record.optString("taskID"));
            if(snapshot!=null&&record.optDouble("recordedAt")<=snapshot.optDouble("fetchedAt")){
                if(task!=null)earlierCredits.merge(task.optString("lessonID"),record.optInt("minutes"),Integer::sum);
                continue;
            }
            int amount=record.optInt("minutes");if(snapshot!=null&&extra<=0)continue;
            Work target=task==null?null:workByID.get(task.optString("lessonID"));
            if(target!=null){int credit=Math.min(amount,target.minutes);if(snapshot!=null)credit=Math.min(credit,extra);target.minutes-=credit;amount-=credit;if(snapshot!=null)extra-=credit;}
            if(snapshot==null)extra+=amount;
        }
        // A newer website snapshot may still lag local confirmations. Preserve their
        // lesson identity, subtracting only credit not already represented online.
        if(snapshot!=null)for(int i=0;i<out.size()&&extra>0;i++){
            Work w=out.get(i);
            JSONObject overlaps=c.optJSONObject("webCompletionOverlaps");
            int overlap=overlaps==null?websiteCredits.get(i):overlaps.optInt(w.lessonID,0);
            int outstanding=Math.max(0,earlierCredits.getOrDefault(w.lessonID,0)-overlap);
            int credit=Math.min(extra,Math.min(outstanding,w.minutes));w.minutes-=credit;extra-=credit;
        }
        for(Work w:out){int credit=Math.min(extra,w.minutes);w.minutes-=credit;extra-=credit;}
        JSONArray preferred=c.optJSONArray("lessonOrder");if(preferred!=null){Map<String,Integer> rank=new HashMap<>();for(int i=0;i<preferred.length();i++)rank.putIfAbsent(preferred.optString(i),i);out.sort(Comparator.comparingInt(w->rank.getOrDefault(w.lessonID,Integer.MAX_VALUE)));}
        return out;
    }
    static Double take(List<Day> ds,int i,int n){return take(ds,i,n,Double.NEGATIVE_INFINITY);}
    static Double take(List<Day> ds,int i,int n,double earliest){
        for(Span v:ds.get(i).free){double start=Math.max(v.a,earliest);if(v.b-start<n*60.0)continue;
            Span occupied=buffered(start,start+n*60.0);for(Day d:ds)d.free=subtract(d.free,Collections.singletonList(occupied));return start;}
        return null;
    }
    static boolean preservesLessonOrder(JSONObject state,List<JSONObject> tasks){
        for(JSONObject course:list(state.optJSONArray("courses"))){
            Map<String,Integer> ranks=new HashMap<>();List<Work> lessons=lessonWork(state,course);
            for(int i=0;i<lessons.size();i++)ranks.put(lessons.get(i).lessonID,i);
            List<JSONObject> booked=new ArrayList<>();for(JSONObject t:tasks)if(t.optString("courseID").equals(course.optString("id"))&&t.has("lessonID"))booked.add(t);
            booked.sort(Comparator.comparingDouble(t->t.optDouble("start")));
            for(int i=1;i<booked.size();i++){JSONObject a=booked.get(i-1),b=booked.get(i);Integer first=ranks.get(a.optString("lessonID")),next=ranks.get(b.optString("lessonID"));
                if(first==null||next==null||first>=next||end(a)+BREAK_SECONDS>b.optDouble("start"))return false;}
        }
        return true;
    }
    static JSONObject task(String c,double start,int size)throws Exception{return new JSONObject().put("id",id()).put("courseID",c).put("start",start).put("durationMinutes",size).put("completedMinutes",0).put("status","future");}
    static JSONObject task(String c,double start,Work work)throws Exception{JSONObject t=task(c,start,work.minutes);if(work.lessonID!=null)t.put("lessonID",work.lessonID).put("lessonName",work.lessonName);return t;}
    static List<Day> copyDays(List<Day> d){List<Day> out=new ArrayList<>();for(Day v:d)out.add(new Day(v.d,merge(v.free)));return out;}
    /** Deadline first allocation, bounded fragmentation repair, load balancing and interleaving. */
    public static Double actualStudyStart(JSONObject s,double now){
        double start=s.optJSONObject("settings").optDouble("actualStudyStart",Double.NaN);
        return Double.isFinite(start)&&day(start).equals(day(now))?start:null;
    }
    static List<String> studyWindows(JSONObject settings)throws Exception{
        List<String> windows=new ArrayList<>();
        for(JSONObject window:list(settings.getJSONArray("availability")))
            windows.add(window.getInt("weekday")+"|"+window.getInt("startMinute")+"|"+window.getInt("endMinute"));
        Collections.sort(windows);return windows;
    }
    /** Match the desktop: changed windows replace today's draft and retain its latest start. */
    public static void updateStudySettings(JSONObject s,JSONObject updated,double now)throws Exception{
        JSONObject previous=s.getJSONObject("settings"),next=new JSONObject(updated.toString());
        boolean changedWindows=!studyWindows(previous).equals(studyWindows(next));
        if(previous.has("actualStudyStart"))next.put("actualStudyStart",previous.get("actualStudyStart"));
        else next.remove("actualStudyStart");
        if(changedWindows&&actualStudyStart(s,now)==null)next.put("actualStudyStart",now);
        s.put("settings",next);
    }
    public static void recordActualStudyStart(JSONObject s,int minute,double now)throws Exception{
        if(minute<0||minute>=1440)throw new IllegalArgumentException("实际开课时间须为当天的 00:00–23:59");
        s.getJSONObject("settings").put("actualStudyStart",at(day(now),minute));
        JSONArray tasks=s.getJSONArray("tasks");
        for(int i=tasks.length()-1;i>=0;i--){JSONObject task=tasks.getJSONObject(i);
            if(pending(task)&&day(task.getDouble("start")).equals(day(now)))tasks.remove(i);
        }
    }
    public static List<String> replan(JSONObject s,double now)throws Exception{
        List<String> warnings=new ArrayList<>();LocalDate today=day(now),horizon=today;
        Double actualStart=actualStudyStart(s,now);double scheduleStart=Math.ceil((actualStart==null?now:actualStart)/60)*60;
        List<JSONObject> courses=new ArrayList<>(),history=new ArrayList<>();
        for(JSONObject c:list(s.getJSONArray("courses")))if(!c.optBoolean("isArchived")&&c.optBoolean("autoScheduleEnabled",true)&&remaining(s,c)>0){courses.add(c);if(day(c.getDouble("deadline")).isAfter(horizon))horizon=day(c.getDouble("deadline"));}
        if(horizon.isAfter(today.plusYears(10))){horizon=today.plusYears(10);warnings.add("仅生成未来十年的计划");}
        for(JSONObject t:list(s.getJSONArray("tasks"))){if(!pending(t)||(planningEnd(t)<=now&&!(actualStart!=null&&day(t.getDouble("start")).equals(today))))history.add(t);}
        List<Span> floatingRegions=new ArrayList<>();
        List<Day> days=new ArrayList<>();for(LocalDate d=today;!d.isAfter(horizon);d=d.plusDays(1)){
            List<Span> windows=new ArrayList<>(),blocks=new ArrayList<>();for(JSONObject a:list(s.getJSONObject("settings").getJSONArray("availability")))if(a.getInt("weekday")==weekday(d))windows.add(new Span(Math.max(scheduleStart,at(d,a.getInt("startMinute"))),at(d,a.getInt("endMinute"))));
            List<JSONObject> events=new ArrayList<>();List<Span> regions=new ArrayList<>();
            for(JSONObject e:list(s.getJSONArray("fixedEvents")))if(occurs(e,d)){
                events.add(e);Span span=new Span(at(d,e.getInt("startMinute")),at(d,e.getInt("endMinute")));
                if(floating(e))regions.add(span);else blocks.add(span);
            }
            regions=merge(regions);
            for(Span span:subtract(windows,blocks))for(Span region:regions){Span clipped=new Span(Math.max(span.a,region.a),Math.min(span.b,region.b));if(clipped.minutes()>0)floatingRegions.add(clipped);}
            boolean[] study=new boolean[1440];
            for(JSONObject a:list(s.getJSONObject("settings").getJSONArray("availability")))if(a.optInt("weekday")==weekday(d))
                for(int m=Math.max(0,a.optInt("startMinute"));m<Math.min(1440,a.optInt("endMinute"));m++)study[m]=true;
            Map<String,Integer> placements=reserve(events,study);
            if(placements==null){warnings.add("浮动事项的连续时长无法排入，或组合过于复杂；请调整时段。");blocks.addAll(regions);}
            else for(JSONObject e:events)if(floating(e)){int start=placements.get(e.getString("id"));blocks.add(new Span(at(d,start),at(d,start+occupied(e))));}
            for(JSONObject t:history)if(planningStart(t)<now&&(pending(t)||t.optInt("completedMinutes")>0))blocks.add(buffered(retainedHistoryStart(t),retainedHistoryEnd(t)));
            days.add(new Day(d,subtract(windows,blocks)));
        }
        List<Day> original=copyDays(days);Map<String,Integer> required=new HashMap<>(),missing=new HashMap<>();Map<String,Double> demand=new HashMap<>();Map<String,List<Work>> pendingWork=new HashMap<>();
        for(JSONObject c:courses){String id=c.getString("id");int r=remaining(s,c);r=Math.max(0,r);required.put(id,r);
            List<Work> work=lessonWork(s,c);
            work.removeIf(w->w.minutes<=0);int workTotal=0;for(Work w:work)workTotal+=w.minutes;if(workTotal!=r){work.clear();if("不定时录播课程".equals(c.optString("type")))warnings.add(c.optString("name")+"：课节进度与总进度不一致，请重新抓取或检查课节。");}
            if(work.isEmpty()){int left=r;while(left>0){int size=Math.min(unit(s,c),left);work.add(new Work(size,null,null));left-=size;}}
            pendingWork.put(id,work);int shortest=Integer.MAX_VALUE;for(Work w:work)shortest=Math.min(shortest,w.minutes);
            int count=0;for(Day d:days)if(eligible(c,d.d))for(Span f:d.free)if(shortest!=Integer.MAX_VALUE&&f.minutes()>=shortest){count++;break;}demand.put(id,count>0?(double)r/count:0);}
        courses.sort((a,b)->{int v=day(a.optDouble("deadline")).compareTo(day(b.optDouble("deadline")));if(v==0)v=Double.compare(demand.get(b.optString("id")),demand.get(a.optString("id")));if(v==0)v=Integer.compare(b.optInt("priority"),a.optInt("priority"));if(v==0)v=Integer.compare(unit(s,b),unit(s,a));return v!=0?v:a.optString("id").compareTo(b.optString("id"));});
        List<JSONObject> tasks=new ArrayList<>();for(JSONObject c:courses){String id=c.getString("id");List<Work> work=pendingWork.get(id);double lessonStart=Double.NEGATIVE_INFINITY;
            for(int i=0;i<days.size();i++)if(eligible(c,days.get(i).d))while(!work.isEmpty()){Work next=work.get(0);Double start=take(days,i,next.minutes,next.lessonID==null?Double.NEGATIVE_INFINITY:lessonStart);if(start==null)break;tasks.add(task(id,start,next));if(next.lessonID!=null)lessonStart=start+next.minutes*60.0+BREAK_SECONDS;work.remove(0);}int left=0;for(Work w:work)left+=w.minutes;missing.put(id,left);}
        int attempts=0;
        for(JSONObject c:courses){String cid=c.getString("id");List<Work> work=pendingWork.get(cid);while(!work.isEmpty()&&attempts<200){Work next=work.get(0);int size=next.minutes;boolean repaired=false;
            search:for(int di=0;di<original.size();di++)if(eligible(c,original.get(di).d))for(Span span:original.get(di).free)if(span.minutes()>=size){List<Double> starts=new ArrayList<>();starts.add(span.a);for(JSONObject t:tasks)if(t.getDouble("start")>=span.a&&end(t)<span.b)starts.add(end(t)+BREAK_SECONDS);Collections.sort(starts);
                for(double start:starts){if(next.lessonID!=null){boolean earlier=false;for(JSONObject t:tasks)if(t.optString("courseID").equals(cid)&&start<end(t)+BREAK_SECONDS){earlier=true;break;}if(earlier)continue;}if(++attempts>200)break search;Span reserved=new Span(start,start+size*60);if(reserved.b>span.b)continue;Span reservation=buffered(reserved.a,reserved.b);List<JSONObject> blockers=new ArrayList<>();for(JSONObject t:tasks)if(t.getDouble("start")<reservation.b&&end(t)>reservation.a)blockers.add(t);
                    boolean immovable=false;for(JSONObject t:blockers){boolean found=false;JSONObject owner=course(s,t.getString("courseID"));for(Day d:days)if(eligible(owner,d.d))for(Span f:d.free)if(f.minutes()>=t.getInt("durationMinutes"))found=true;if(!found){immovable=true;break;}}if(immovable)continue;
                    List<Day> oldDays=copyDays(days);Map<String,Double> oldStarts=new HashMap<>();for(JSONObject t:blockers)oldStarts.put(t.getString("id"),t.getDouble("start"));
                    for(int di2=0;di2<days.size();di2++){List<Span> occupied=new ArrayList<>();occupied.add(reservation);for(JSONObject t:tasks)if(!blockers.contains(t))occupied.add(buffered(t.getDouble("start"),end(t)));days.get(di2).free=subtract(original.get(di2).free,occupied);}
                    blockers.sort((a,b)->Integer.compare(b.optInt("durationMinutes"),a.optInt("durationMinutes")));boolean ok=true;
                    for(JSONObject t:blockers){JSONObject owner=course(s,t.getString("courseID"));Double replacement=null;for(int i=0;i<days.size();i++)if(eligible(owner,days.get(i).d)){replacement=take(days,i,t.getInt("durationMinutes"));if(replacement!=null)break;}if(replacement==null){ok=false;break;}t.put("start",replacement);}
                    if(ok){JSONObject added=task(cid,start,next);List<JSONObject> candidate=new ArrayList<>(tasks);candidate.add(added);if(preservesLessonOrder(s,candidate)){tasks.add(added);work.remove(0);repaired=true;break search;}}days=oldDays;for(JSONObject t:blockers)t.put("start",oldStarts.get(t.getString("id")));
                }
            }if(!repaired)break;
        }int left=0;for(Work w:work)left+=w.minutes;missing.put(cid,left);}
        // Try a day-by-day rotation, retaining the feasible allocation if any booked block fails to fit.
        Set<Integer> priorities=new HashSet<>();for(JSONObject c:courses)priorities.add(c.optInt("priority"));
        if(priorities.size()<courses.size()){
            Map<String,List<JSONObject>> queues=new HashMap<>();Map<String,Integer> positions=new HashMap<>(),left=new HashMap<>(),booked=new HashMap<>();Map<String,int[]> future=new HashMap<>();
            for(JSONObject c:courses){
                String id=c.getString("id");Map<String,Integer> ranks=new HashMap<>();List<Work> lessons=lessonWork(s,c);for(int i=0;i<lessons.size();i++)ranks.put(lessons.get(i).lessonID,i);
                List<JSONObject> queue=new ArrayList<>();for(JSONObject t:tasks)if(t.getString("courseID").equals(id))queue.add(t);
                queue.sort((a,b)->{Integer ra=ranks.get(a.optString("lessonID")),rb=ranks.get(b.optString("lessonID"));if(ra!=null&&rb!=null&&!ra.equals(rb))return Integer.compare(ra,rb);return Double.compare(a.optDouble("start"),b.optDouble("start"));});
                queues.put(id,queue);positions.put(id,0);int amount=0;for(JSONObject t:queue)amount+=t.getInt("durationMinutes");left.put(id,amount);booked.put(id,amount);
                int[] capacity=new int[original.size()+1];for(int i=original.size()-1;i>=0;i--){capacity[i]=capacity[i+1];if(eligible(c,original.get(i).d))for(Span span:original.get(i).free)capacity[i]+=span.minutes();}future.put(id,capacity);
            }
            List<JSONObject> mixed=new ArrayList<>();double nextStart=Double.NEGATIVE_INFINITY;
            for(int di=0;di<original.size();di++){
                Day d=original.get(di);Map<String,Integer> daily=new HashMap<>();String previous="";
                for(Span span:d.free){double time=Math.max(span.a,nextStart);while(time<span.b){
                    List<JSONObject> candidates=new ArrayList<>();for(JSONObject c:courses){String id=c.getString("id");int pos=positions.get(id);if(eligible(c,d.d)&&pos<queues.get(id).size()&&queues.get(id).get(pos).getInt("durationMinutes")<=(int)((span.b-time)/60))candidates.add(c);}
                    final int index=di;final String prev=previous;
                    candidates.sort((a,b)->{
                        String ai=a.optString("id"),bi=b.optString("id");boolean ua=left.get(ai)>future.get(ai)[index+1],ub=left.get(bi)>future.get(bi)[index+1];if(ua!=ub)return ua?-1:1;
                        int v=ua?day(a.optDouble("deadline")).compareTo(day(b.optDouble("deadline"))):0;if(v!=0)return v;
                        v=Integer.compare(b.optInt("priority"),a.optInt("priority"));if(v!=0)return v;
                        v=Integer.compare(daily.getOrDefault(ai,0),daily.getOrDefault(bi,0));if(v!=0)return v;
                        if(ai.equals(prev)!=bi.equals(prev))return ai.equals(prev)?1:-1;
                        return Double.compare((double)(booked.get(ai)-left.get(ai))/Math.max(1,booked.get(ai)),(double)(booked.get(bi)-left.get(bi))/Math.max(1,booked.get(bi)));
                    });
                    if(candidates.isEmpty())break;String id=candidates.get(0).getString("id");JSONObject t=new JSONObject(queues.get(id).get(positions.get(id)).toString());t.put("start",time);mixed.add(t);time=end(t)+BREAK_SECONDS;nextStart=time;
                    int size=t.getInt("durationMinutes");positions.put(id,positions.get(id)+1);left.put(id,left.get(id)-size);daily.put(id,daily.getOrDefault(id,0)+size);previous=id;
                }}
            }
            if(mixed.size()==tasks.size()){tasks=mixed;for(Day d:days){List<Span> occupied=new ArrayList<>();for(JSONObject t:tasks)occupied.add(buffered(t.getDouble("start"),end(t)));for(Day base:original)if(base.d.equals(d.d)){d.free=subtract(base.free,occupied);break;}}}
        }
        Map<LocalDate,Integer> indices=new HashMap<>();for(int i=0;i<days.size();i++)indices.put(days.get(i).d,i);int[] totals=new int[days.size()];Map<String,int[]> loads=new HashMap<>();for(JSONObject c:courses)loads.put(c.getString("id"),new int[days.size()]);for(JSONObject t:tasks){int i=indices.get(day(t.getDouble("start")));totals[i]+=t.getInt("durationMinutes");loads.get(t.getString("courseID"))[i]+=t.getInt("durationMinutes");}
        boolean changed=true;while(changed){changed=false;for(JSONObject t:tasks){if(t.has("lessonID"))continue;String id=t.getString("courseID");JSONObject c=course(s,id);int src=indices.get(day(t.getDouble("start"))),size=t.getInt("durationMinutes"),target=-1;int[] load=loads.get(id);for(int i=0;i<days.size();i++)if(i!=src&&eligible(c,days.get(i).d)&&load[src]-load[i]>size){boolean fits=false;for(Span f:days.get(i).free)if(f.minutes()>=size)fits=true;if(fits&&(target<0||load[i]<load[target]||(load[i]==load[target]&&totals[i]<totals[target])))target=i;}
            if(target>=0){Double start=take(days,target,size);t.put("start",start);List<Span> occupied=new ArrayList<>();for(JSONObject bookedTask:tasks)occupied.add(buffered(bookedTask.getDouble("start"),end(bookedTask)));for(int di=0;di<days.size();di++)days.get(di).free=subtract(original.get(di).free,occupied);totals[src]-=size;totals[target]+=size;load[src]-=size;load[target]+=size;changed=true;}
        }}
        List<JSONObject> packed=new ArrayList<>();double nextStart=Double.NEGATIVE_INFINITY;
        for(Day d:original){
            String previous="";
            for(Span span:d.free){List<JSONObject> pool=new ArrayList<>();for(JSONObject t:tasks)if(t.getDouble("start")>=span.a&&end(t)<=span.b)pool.add(t);pool.sort(Comparator.comparingDouble(t->t.optDouble("start")));double time=Math.max(span.a,nextStart);
                while(!pool.isEmpty()){int pick=0;int priority=course(s,pool.get(0).getString("courseID")).optInt("priority");for(int i=0;i<pool.size();i++)if(!pool.get(i).getString("courseID").equals(previous)&&course(s,pool.get(i).getString("courseID")).optInt("priority")==priority){pick=i;break;}
                    JSONObject t=pool.remove(pick);t.put("start",time).put("status",d.d.equals(today)?"planned":"future");time=end(t)+BREAK_SECONDS;nextStart=time;previous=t.getString("courseID");packed.add(t);
                }
            }
        }
        if(actualStart!=null&&!original.isEmpty()){
            double cursor=Double.NEGATIVE_INFINITY;
            for(JSONObject t:packed)if(day(t.getDouble("start")).equals(today)){
                double seconds=t.getInt("durationMinutes")*60.0;
                for(Span span:original.get(0).free){double start=Math.max(span.a,cursor);if(start+seconds<=span.b){t.put("start",start);cursor=end(t)+BREAK_SECONDS;break;}}
            }
        }
        for(JSONObject c:courses)if(missing.get(c.getString("id"))>0)warnings.add(c.getString("name")+"：截止 "+date(c.getDouble("deadline"))+"，仍有 "+missing.get(c.getString("id"))+" 分钟未排入，请增加可用时间或调整时间块。");
        for(JSONObject t:packed){
            double a=t.getDouble("start"),b=end(t);boolean affected=false;
            for(Span region:floatingRegions)if(region.a<end(t)&&region.b>t.getDouble("start")){a=Math.min(a,region.a);b=Math.max(b,region.b);affected=true;}
            if(affected)t.put("floatingWindowStart",a).put("floatingWindowEnd",b);
        }
        packed=DailyTaskOrdering.apply(s,packed,history);
        for(JSONObject t:packed){String base="task|"+t.getString("courseID")+"|"+(long)t.getDouble("start")+"|"+t.getInt("durationMinutes")+(t.has("lessonID")?"|"+t.optString("lessonID"):"");String stable=stableID(base);
            List<String> confirmed=new ArrayList<>();boolean collision=false;for(JSONObject old:list(s.getJSONArray("tasks")))if(!pending(old)&&old.getString("courseID").equals(t.getString("courseID"))){confirmed.add(old.getString("id"));if(old.getString("id").equals(stable))collision=true;}Collections.sort(confirmed);if(collision)stable=stableID(base+"|confirmed|"+String.join(",",confirmed));
            for(JSONObject old:list(s.getJSONArray("tasks")))if(pending(old)&&old.getString("courseID").equals(t.getString("courseID"))&&old.getDouble("start")==t.getDouble("start")&&old.getInt("durationMinutes")==t.getInt("durationMinutes")&&old.optString("lessonID").equals(t.optString("lessonID"))){stable=old.getString("id");break;}
            t.put("id",stable);
        }
        JSONArray risks=new JSONArray();Set<LocalDate> cutoffs=new TreeSet<>();for(JSONObject c:courses)cutoffs.add(day(c.getDouble("deadline")));for(LocalDate cutoff:cutoffs){List<JSONObject> group=new ArrayList<>();JSONArray names=new JSONArray();int requiredMinutes=0,absent=0,capacity=0;for(JSONObject c:courses)if(!day(c.getDouble("deadline")).isAfter(cutoff)){group.add(c);requiredMinutes+=required.get(c.getString("id"));absent+=missing.get(c.getString("id"));if(missing.get(c.getString("id"))>0)names.put(c.getString("name"));}if(absent==0)continue;for(Day d:original)if(!d.d.isAfter(cutoff)){boolean learnable=false;for(JSONObject c:group)if(eligible(c,d.d))learnable=true;if(learnable)for(Span span:d.free)capacity+=span.minutes();}risks.put(new JSONObject().put("deadline",at(cutoff,0)).put("requiredMinutes",requiredMinutes).put("availableMinutes",capacity).put("unscheduledMinutes",absent).put("courseNames",names));}s.put("androidRisks",risks);
        history.addAll(packed);history.sort(Comparator.comparingDouble(t->t.optDouble("start")));s.put("tasks",array(history));s.put("androidWarnings",new JSONArray(warnings));return warnings;
    }
}
