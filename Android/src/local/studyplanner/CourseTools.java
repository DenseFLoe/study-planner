package local.studyplanner;

import org.json.*;
import java.text.Normalizer;
import java.util.*;
import java.util.regex.*;

/** Course/lesson operations use the same Codable fields as the Mac. */
public final class CourseTools {
    static JSONObject copy(JSONObject value)throws Exception{
        JSONObject result=new JSONObject();Iterator<String> keys=value.keys();
        while(keys.hasNext()){String key=keys.next();result.put(key,copyValue(value.get(key)));}return result;
    }
    static Object copyValue(Object value)throws Exception{
        if(value instanceof JSONObject)return copy((JSONObject)value);
        if(value instanceof JSONArray){JSONArray source=(JSONArray)value,result=new JSONArray();for(int i=0;i<source.length();i++)result.put(copyValue(source.get(i)));return result;}
        return value;
    }
    static int chinese(String text){String digits="零一二三四五六七八九";int total=0,pending=0;for(char c:text.toCharArray()){int n=digits.indexOf(c);if(c=='〇')n=0;if(c=='两')n=2;if(n>=0)pending=n;else{total+=Math.max(1,pending)*(c=='百'?100:10);pending=0;}}return total+pending;}
    static class SortKey {
        // Start a numeric scan once per run; \G also permits adjacent metadata tags.
        static final Pattern VIDEO_TAGS=Pattern.compile("(?<![0-9])(?:2160|1440|1080|720|480)[pi]|[248]k|[hx]26[45]|(?:(?<![0-9])|\\G)[0-9]++fps");
        static final Pattern CHINESE_COUNTER=Pattern.compile("第?(?<![零〇一二三四五六七八九十百两])([零〇一二三四五六七八九十百两]++)([章节讲课集部分])");
        List<String> numbers=new ArrayList<>();String text;int part;
        SortKey(String raw){String value=VIDEO_TAGS.matcher(Normalizer.normalize(raw,Normalizer.Form.NFKC).toLowerCase(Locale.ROOT).replaceAll("\\.(mp4|mkv|mov|avi|flv|webm|m4v|ts|mp3|pdf)$","")).replaceAll("");
            Matcher chinese=CHINESE_COUNTER.matcher(value);StringBuffer converted=new StringBuffer();while(chinese.find())chinese.appendReplacement(converted,Matcher.quoteReplacement(chinese.group().replace(chinese.group(1),String.valueOf(chinese(chinese.group(1))))));chinese.appendTail(converted);value=converted.toString();
            for(int i=0;i<3;i++){Matcher marker=Pattern.compile("[（(【\\[]"+"上中下".charAt(i)+"[）)】\\]]|"+"上中下".charAt(i)+"[篇部集]$").matcher(value);if(marker.find()){part=i+1;value=marker.replaceFirst("");break;}}
            text=value.replaceAll("[0-9]+|[\\s._\\-—、()\\[\\]]","");int tail=0;Matcher counters=Pattern.compile("第\\s*([0-9]+)\\s*[章节讲课集]").matcher(value);while(counters.find()){numbers.add(clean(counters.group(1)));tail=counters.end();}Matcher other=Pattern.compile("[0-9]+").matcher(value.substring(tail));while(other.find())numbers.add(clean(other.group()));
        }
        static String clean(String n){String clean=n.replaceFirst("^0+","");return clean.isEmpty()?"0":clean;}
        int compare(SortKey other){for(int i=0;i<Math.min(numbers.size(),other.numbers.size());i++){String a=numbers.get(i),b=other.numbers.get(i);int v=Integer.compare(a.length(),b.length());if(v==0)v=a.compareTo(b);if(v!=0)return v;}int v=Integer.compare(numbers.size(),other.numbers.size());if(v==0)v=natural(text,other.text);return v!=0?v:Integer.compare(part,other.part);}
    }
    public static int natural(String a,String b){Matcher left=Pattern.compile("[0-9]+|[^0-9]+").matcher(Normalizer.normalize(a,Normalizer.Form.NFKC).toLowerCase(Locale.ROOT)),right=Pattern.compile("[0-9]+|[^0-9]+").matcher(Normalizer.normalize(b,Normalizer.Form.NFKC).toLowerCase(Locale.ROOT));while(true){boolean x=left.find(),y=right.find();if(!x||!y)return Boolean.compare(x,y);String p=left.group(),q=right.group();int v;if(Character.isDigit(p.charAt(0))&&Character.isDigit(q.charAt(0))){int pl=p.length(),ql=q.length();p=SortKey.clean(p);q=SortKey.clean(q);v=Integer.compare(p.length(),q.length());if(v==0)v=p.compareTo(q);if(v==0)v=Integer.compare(pl,ql);}else v=p.compareTo(q);if(v!=0)return v;}}
    public static List<JSONObject> intelligent(List<JSONObject> lessons){List<JSONObject> sorted=new ArrayList<>(lessons);Map<JSONObject,List<SortKey>> keys=new IdentityHashMap<>();Map<String,SortKey> cache=new HashMap<>();for(JSONObject lesson:sorted){List<SortKey> values=new ArrayList<>();for(String field:new String[]{"subject","stage","chapter","name"})values.add(cache.computeIfAbsent(lesson.optString(field),SortKey::new));keys.put(lesson,values);}sorted.sort((a,b)->{for(int i=0;i<4;i++){int v=keys.get(a).get(i).compare(keys.get(b).get(i));if(v!=0)return v;}return a.optString("id").compareTo(b.optString("id"));});return sorted;}
    public static List<JSONObject> lessons(JSONObject course)throws Exception {
        List<JSONObject> result=new ArrayList<>();JSONArray sources=course.optJSONArray("mergedSources");
        if(sources!=null){for(JSONObject source:Planner.list(sources)){List<JSONObject> items=lessons(source);if(items.isEmpty())items.add(new JSONObject().put("id","whole").put("name",source.getString("name")).put("durationMinutes",source.getInt("totalMinutes")));for(JSONObject raw:items){JSONObject lesson=copy(raw);lesson.put("id",source.getString("id")+"/"+raw.getString("id"));if(lesson.optString("subject").isEmpty())lesson.put("subject",source.getString("name"));result.add(lesson);}}return intelligent(result);}
        JSONObject web=course.optJSONObject("webCourse");JSONArray raw=web==null?course.optJSONArray("manualLessons"):web.optJSONArray("lessons");if(raw!=null)for(JSONObject item:Planner.list(raw))if(web==null||item.optBoolean("published")&&item.optBoolean("requiresDuration"))result.add(copy(item));return result;
    }
    public static List<String> order(JSONObject course)throws Exception {List<String> ids=new ArrayList<>();for(JSONObject lesson:lessons(course))ids.add(lesson.getString("id"));List<String> result=new ArrayList<>();JSONArray preferred=course.optJSONArray("lessonOrder");if(preferred!=null)for(int i=0;i<preferred.length();i++){String id=preferred.getString(i);if(ids.contains(id)&&!result.contains(id))result.add(id);}for(String id:ids)if(!result.contains(id))result.add(id);return result;}
    public static JSONObject merge(JSONObject state,Set<String> ids,String name)throws Exception {
        String title=name.trim();List<JSONObject> sources=new ArrayList<>();for(JSONObject c:Planner.list(state.getJSONArray("courses")))if(ids.contains(c.getString("id"))&&!c.optBoolean("isArchived"))sources.add(copy(c));sources.sort((a,b)->{int v=natural(a.optString("name"),b.optString("name"));return v!=0?v:a.optString("id").compareTo(b.optString("id"));});
        if(sources.size()<2||sources.size()!=ids.size()||title.isEmpty())throw new IllegalArgumentException("请选择至少两门现有课程，并填写合并后的名称。");
        Set<String> taskIDs=new HashSet<>();for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(ids.contains(task.getString("courseID")))taskIDs.add(task.getString("id"));for(JSONObject record:Planner.list(state.getJSONArray("completions")))if(ids.contains(record.getString("courseID"))&&!taskIDs.contains(record.getString("taskID")))throw new IllegalArgumentException("部分完成记录缺少关联任务，暂不能安全合并这些课程。");
        int total=0,initial=0,priority=0;double start=Double.POSITIVE_INFINITY,deadline=start;boolean auto=false;for(JSONObject c:sources){total+=c.getInt("totalMinutes");initial+=c.optInt("initialCompletedMinutes");priority=Math.max(priority,c.optInt("priority",2));start=Math.min(start,c.getDouble("startDate"));deadline=Math.min(deadline,c.getDouble("deadline"));auto|=c.optBoolean("autoScheduleEnabled",true);}
        if(total<=0||total>600000)throw new IllegalArgumentException("合并后的总时长须在 10,000 小时以内。");
        JSONObject merged=new JSONObject().put("id",Planner.id()).put("name",title).put("type","不定时录播课程").put("totalMinutes",total).put("initialCompletedMinutes",initial).put("startDate",start).put("deadline",deadline).put("priority",priority).put("color",sources.get(0).optString("color","blue")).put("minimumBlockMinutes",60).put("autoScheduleEnabled",auto).put("isArchived",false).put("notes","").put("mergedSources",new JSONArray(sources));
        List<String> order=new ArrayList<>();for(JSONObject lesson:lessons(merged))order.add(lesson.getString("id"));merged.put("lessonOrder",new JSONArray(order));
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(ids.contains(task.getString("courseID")))task.put("lessonID",task.getString("courseID")+"/"+task.optString("lessonID","whole")).put("courseID",merged.getString("id"));for(JSONObject record:Planner.list(state.getJSONArray("completions")))if(ids.contains(record.getString("courseID")))record.put("courseID",merged.getString("id"));
        JSONArray courses=new JSONArray();for(JSONObject course:Planner.list(state.getJSONArray("courses")))if(!ids.contains(course.getString("id")))courses.put(course);courses.put(merged);state.put("courses",courses);return merged;
    }
    static Set<String> deletedIDs(JSONObject course)throws Exception {
        Set<String> ids=new HashSet<>();JSONArray raw=course.optJSONArray("deletedLessonIDs");
        if(raw!=null)for(int i=0;i<raw.length();i++)ids.add(raw.getString(i));return ids;
    }
    public static void removeLessons(JSONObject state,String courseID,Set<String> ids)throws Exception {
        JSONObject next=copy(state),course=Planner.course(next,courseID);
        if(course==null||course.optBoolean("isArchived"))throw new IllegalArgumentException("课程已不存在，请重新打开。");
        Set<String> known=new HashSet<>(order(course));
        if(!"不定时录播课程".equals(course.optString("type"))||ids.isEmpty()||!known.containsAll(ids))throw new IllegalArgumentException("请选择现有课节后重试。");
        if(ids.equals(known))throw new IllegalArgumentException("请至少保留一节课；删除整门课程请使用「删除课程」。");
        Map<String,JSONObject> taskByID=new HashMap<>();for(JSONObject task:Planner.list(next.getJSONArray("tasks")))if(task.optString("courseID").equals(courseID))taskByID.put(task.getString("id"),task);
        for(JSONObject record:Planner.list(next.getJSONArray("completions")))if(record.optString("courseID").equals(courseID)){
            JSONObject task=taskByID.get(record.optString("taskID"));if(task==null||!known.contains(task.optString("lessonID")))throw new IllegalArgumentException("部分旧完成记录没有课节标识，暂不能安全删除部分课节。");
        }
        Planner.put(next.getJSONArray("courses"),removingLessons(next,course,ids));purgeDeletedLessonRecords(next,Collections.emptyList());
        for(String key:new String[]{"courses","tasks","completions"})state.put(key,next.get(key));
    }
    static JSONObject sourceState(JSONObject state,JSONObject source,JSONObject parent)throws Exception {
        JSONObject subset=copy(state);JSONArray tasks=new JSONArray(),records=new JSONArray();Set<String> taskIDs=new HashSet<>();String prefix=source.getString("id")+"/";
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(task.optString("courseID").equals(parent.getString("id"))&&task.optString("lessonID").startsWith(prefix)){
            JSONObject t=copy(task);t.put("courseID",source.getString("id")).put("lessonID",task.getString("lessonID").substring(prefix.length()));tasks.put(t);taskIDs.add(t.getString("id"));
        }
        for(JSONObject record:Planner.list(state.getJSONArray("completions")))if(record.optString("courseID").equals(parent.getString("id"))&&taskIDs.contains(record.optString("taskID")))records.put(copy(record).put("courseID",source.getString("id")));
        return subset.put("tasks",tasks).put("completions",records).put("courses",new JSONArray().put(copy(source)));
    }
    static JSONObject removingLessons(JSONObject state,JSONObject course,Set<String> ids)throws Exception {
        JSONObject updated=copy(course);JSONArray sources=course.optJSONArray("mergedSources"),manual=course.optJSONArray("manualLessons");JSONObject web=course.optJSONObject("webCourse");
        if(sources!=null){
            JSONArray retained=new JSONArray();int total=0,initial=0;
            for(JSONObject source:Planner.list(sources)){
                String prefix=source.getString("id")+"/";Set<String> selected=new HashSet<>();for(String id:ids)if(id.startsWith(prefix))selected.add(id.substring(prefix.length()));
                JSONObject keep=copy(source);if(!selected.isEmpty()){
                    Set<String> known=new HashSet<>(order(source));if(known.isEmpty())known.add("whole");if(selected.equals(known))continue;
                    keep=removingLessons(sourceState(state,source,course),source,selected);
                }
                retained.put(keep);total+=keep.getInt("totalMinutes");initial+=keep.optInt("initialCompletedMinutes");
            }
            updated.put("mergedSources",retained).put("totalMinutes",total).put("initialCompletedMinutes",initial);
        }else if(web!=null){
            JSONObject snapshot=copy(web),subset=copy(state);JSONArray lessons=new JSONArray();for(JSONObject lesson:Planner.list(snapshot.getJSONArray("lessons")))if(!ids.contains(lesson.getString("id")))lessons.put(lesson);snapshot.put("lessons",lessons);snapshot.remove("netdisk");
            JSONArray tasks=new JSONArray(),records=new JSONArray();Set<String> removed=new HashSet<>();for(JSONObject task:Planner.list(subset.getJSONArray("tasks")))if(task.optString("courseID").equals(course.getString("id"))&&ids.contains(task.optString("lessonID")))removed.add(task.getString("id"));else tasks.put(task);
            for(JSONObject record:Planner.list(subset.getJSONArray("completions")))if(!removed.contains(record.optString("taskID")))records.put(record);
            subset.put("tasks",tasks).put("completions",records).put("courses",new JSONArray().put(copy(course)));double now=Planner.now();WebCourseImport.save(subset,Collections.singletonList(snapshot),Math.max(now,course.getDouble("deadline")),now);updated=subset.getJSONArray("courses").getJSONObject(0);
        }else if(manual!=null){
            int baseline=Math.max(0,course.optInt("initialCompletedMinutes")),removedBaseline=0,total=0;JSONArray retained=new JSONArray();
            for(JSONObject lesson:Planner.list(manual)){int credit=Math.min(baseline,lesson.getInt("durationMinutes"));baseline-=credit;if(ids.contains(lesson.getString("id")))removedBaseline+=credit;else{retained.put(lesson);total+=lesson.getInt("durationMinutes");}}
            updated.put("manualLessons",retained).put("totalMinutes",total).put("initialCompletedMinutes",Math.max(0,course.optInt("initialCompletedMinutes")-removedBaseline));
        }else throw new IllegalArgumentException("这门课程没有可删除的独立课节。");
        Set<String> deleted=deletedIDs(course);deleted.addAll(ids);updated.put("deletedLessonIDs",new JSONArray(new TreeSet<>(deleted)));
        JSONArray order=updated.optJSONArray("lessonOrder");if(order!=null){JSONArray retained=new JSONArray();for(int i=0;i<order.length();i++)if(!ids.contains(order.getString(i)))retained.put(order.getString(i));updated.put("lessonOrder",retained);}
        for(String key:new String[]{"netdiskLessons","webCompletionOverlaps"}){JSONObject values=updated.optJSONObject(key);if(values!=null)for(String id:ids)values.remove(id);}
        return updated;
    }
    static Set<String> allDeletedIDs(JSONObject course)throws Exception {
        Set<String> ids=deletedIDs(course);JSONArray sources=course.optJSONArray("mergedSources");if(sources!=null)for(JSONObject source:Planner.list(sources))for(String id:allDeletedIDs(source))ids.add(source.getString("id")+"/"+id);return ids;
    }
    static void purgeDeletedLessonRecords(JSONObject state,Collection<JSONObject> additionalTasks)throws Exception {
        Map<String,Set<String>> deleted=new HashMap<>();for(JSONObject course:Planner.list(state.getJSONArray("courses")))deleted.put(course.getString("id"),allDeletedIDs(course));
        List<JSONObject> all=new ArrayList<>(Planner.list(state.getJSONArray("tasks")));all.addAll(additionalTasks);Set<String> removed=new HashSet<>();
        for(JSONObject task:all)if(deleted.getOrDefault(task.optString("courseID"),Collections.emptySet()).contains(task.optString("lessonID")))removed.add(task.getString("id"));
        for(String key:new String[]{"tasks","completions"}){JSONArray retained=new JSONArray();for(JSONObject row:Planner.list(state.getJSONArray(key)))if(!removed.contains(row.optString(key.equals("tasks")?"id":"taskID")))retained.put(row);state.put(key,retained);}
    }
    public static List<JSONObject> preview(JSONObject state,JSONObject course,double now)throws Exception {JSONObject next=copy(state);Planner.put(next.getJSONArray("courses"),copy(course));Planner.replan(next,now);List<JSONObject> tasks=new ArrayList<>();for(JSONObject task:Planner.list(next.getJSONArray("tasks")))if(task.optString("courseID").equals(course.getString("id"))&&Planner.pending(task))tasks.add(task);return tasks;}
}
