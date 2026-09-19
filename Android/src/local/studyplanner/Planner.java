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
    public static double now(){return System.currentTimeMillis()/1000.0-EPOCH;}
    public static LocalDate day(double s){return Instant.ofEpochMilli((long)((s+EPOCH)*1000)).atZone(ZONE).toLocalDate();}
    public static double at(LocalDate d,int m){return d.atStartOfDay(ZONE).plusMinutes(m).toEpochSecond()-EPOCH;}
    public static String date(double s){return day(s).toString();}
    public static String clock(double s){return Instant.ofEpochMilli((long)((s+EPOCH)*1000)).atZone(ZONE).format(DateTimeFormatter.ofPattern("HH:mm"));}
    public static String time(int m){return String.format(Locale.ROOT,"%02d:%02d",m/60,m%60);}
    public static int minute(String t){String[] a=t.trim().split(":"); if(a.length!=2)throw new IllegalArgumentException("时间格式为 HH:mm");int h=Integer.parseInt(a[0]),m=Integer.parseInt(a[1]);if(h<0||h>24||m<0||m>59||(h==24&&m!=0))throw new IllegalArgumentException("时间超出范围");return h*60+m;}
    public static int weekday(LocalDate d){return d.getDayOfWeek().getValue()%7+1;}
    public static double end(JSONObject t){return t.optDouble("start")+60*t.optInt("durationMinutes");}
    public static boolean pending(JSONObject t){return !t.has("confirmedAt")&&(t.optString("status").equals("planned")||t.optString("status").equals("future"));}
    public static JSONObject course(JSONObject s,String id){for(JSONObject c:list(s.optJSONArray("courses")))if(c.optString("id").equals(id))return c;return null;}
    public static int completed(JSONObject s,JSONObject c){int v=Math.max(0,c.optInt("initialCompletedMinutes"));for(JSONObject r:list(s.optJSONArray("completions")))if(r.optString("courseID").equals(c.optString("id")))v+=r.optInt("minutes");return Math.min(c.optInt("totalMinutes"),v);}
    public static int remaining(JSONObject s,JSONObject c){return Math.max(0,c.optInt("totalMinutes")-completed(s,c));}
    public static boolean occurs(JSONObject e,LocalDate d){if(d.isBefore(day(e.optDouble("startDate")))||d.isAfter(day(e.optDouble("endDate"))))return false;JSONArray excluded=e.optJSONArray("excludedDates");if(excluded!=null)for(int i=0;i<excluded.length();i++)if(day(excluded.optDouble(i)).equals(d))return false;JSONArray w=e.optJSONArray("weekdays");if(w==null||w.length()==0)return d.equals(day(e.optDouble("startDate")));for(int i=0;i<w.length();i++)if(w.optInt(i)==weekday(d))return true;return false;}
    public static List<JSONObject> review(JSONObject s,double now){List<JSONObject> out=new ArrayList<>();LocalDate today=day(now);int m=(int)((now-at(today,0))/60);for(JSONObject t:list(s.optJSONArray("tasks"))){JSONObject c=course(s,t.optString("courseID"));if(pending(t)&&c!=null&&!c.optBoolean("isArchived")&&(end(t)<=at(today,0)||(m>=s.optJSONObject("settings").optInt("notificationMinute")&&end(t)<=now)))out.add(t);}return out;}
    public static void confirm(JSONObject s,String taskID,int actual,double now)throws Exception{JSONObject t=null;for(JSONObject v:list(s.getJSONArray("tasks")))if(v.getString("id").equals(taskID))t=v;if(t==null||!pending(t))throw new IllegalArgumentException("该任务已确认，请刷新后重试");if(actual<0||actual>t.getInt("durationMinutes"))throw new IllegalArgumentException("实际时长必须在 0 与计划时长之间");JSONObject c=course(s,t.getString("courseID"));if(c==null)throw new IllegalArgumentException("找不到课程");int credit=Math.min(actual,remaining(s,c));t.put("completedMinutes",credit).put("confirmedAt",now).put("status",actual==0?"missed":actual==t.getInt("durationMinutes")?"completed":"partial");s.getJSONArray("completions").put(new JSONObject().put("id",stableID("completion|"+taskID)).put("courseID",c.getString("id")).put("taskID",taskID).put("minutes",credit).put("recordedAt",now));}
    public static void undoConfirmation(JSONObject s,String taskID,double now)throws Exception{JSONObject t=null;for(JSONObject v:list(s.getJSONArray("tasks")))if(v.getString("id").equals(taskID))t=v;if(t==null||!t.has("confirmedAt"))throw new IllegalArgumentException("该任务尚未确认，无需撤销");JSONArray records=s.getJSONArray("completions");boolean removed=false;for(int i=records.length()-1;i>=0;i--)if(records.getJSONObject(i).optString("taskID").equals(taskID)){records.remove(i);removed=true;}if(!removed)throw new IllegalArgumentException("找不到该任务的完成记录");t.remove("confirmedAt");t.put("completedMinutes",0).put("status",day(t.getDouble("start")).equals(day(now))?"planned":"future");}
    public static void put(JSONArray a,JSONObject v)throws Exception{for(int i=0;i<a.length();i++)if(a.getJSONObject(i).getString("id").equals(v.getString("id"))){a.put(i,v);return;}a.put(v);}
    public static void validate(JSONObject s)throws Exception{if(s.getInt("schemaVersion")!=1)throw new IllegalArgumentException("不支持此备份版本");for(String key:new String[]{"courses","fixedEvents","tasks","completions"}){Set<String> ids=new HashSet<>();for(JSONObject o:list(s.getJSONArray(key)))if(o==null||!ids.add(o.getString("id")))throw new IllegalArgumentException("数据缺少 ID 或重复");}JSONObject settings=s.getJSONObject("settings");if(settings.getInt("minimumScheduleUnit")<1)throw new IllegalArgumentException("最小时间块无效");settings.getJSONArray("availability");for(JSONObject t:list(s.getJSONArray("tasks")))if(course(s,t.getString("courseID"))==null||t.getInt("durationMinutes")<=0)throw new IllegalArgumentException("任务数据不完整");}
    public static void saveEvent(JSONObject s,JSONObject event,double now)throws Exception{
        int start=event.getInt("startMinute"),end=event.getInt("endMinute");if(start<0||end>1440||start>=end)throw new IllegalArgumentException("结束时间必须晚于开始时间");
        JSONObject old=null;JSONArray events=s.getJSONArray("fixedEvents");for(JSONObject e:list(events))if(e.getString("id").equals(event.getString("id")))old=e;
        LocalDate today=day(now),boundary=today;if(old!=null&&occurs(old,today)&&at(today,old.getInt("startMinute"))<=now)boundary=today.plusDays(1);
        LocalDate first=day(event.getDouble("startDate"));if(first.isBefore(boundary))first=boundary;LocalDate last=day(event.getDouble("endDate"));if(last.isBefore(first))throw new IllegalArgumentException("历史事项不可修改，请添加未来事项");if(last.isAfter(today.plusYears(10)))throw new IllegalArgumentException("固定事项最多支持未来十年");event.put("startDate",at(first,0));
        for(JSONObject e:list(events))if(!e.getString("id").equals(event.getString("id"))&&e.getInt("startMinute")<end&&e.getInt("endMinute")>start)for(LocalDate d=first;!d.isAfter(last);d=d.plusDays(1))if(occurs(e,d)&&occurs(event,d))throw new IllegalArgumentException(d+" 与「"+e.getString("title")+"」冲突；请调整时间或填写跳过日期");
        if(occurs(event,today))for(JSONObject t:list(s.getJSONArray("tasks")))if(pending(t)&&t.getDouble("start")<now&&end(t)>now&&t.getDouble("start")<at(today,end)&&end(t)>at(today,start))throw new IllegalArgumentException("与正在进行的学习任务冲突，请先确认任务");
        if(old!=null&&day(old.getDouble("startDate")).isBefore(boundary)){old.put("endDate",Math.min(old.getDouble("endDate"),at(boundary.minusDays(1),0)));event.put("id",id());}put(events,event);
    }
    public static void removeEvent(JSONObject s,String id,double now)throws Exception{JSONArray a=s.getJSONArray("fixedEvents");for(int i=0;i<a.length();i++){JSONObject e=a.getJSONObject(i);if(!e.getString("id").equals(id))continue;LocalDate today=day(now);LocalDate b=occurs(e,today)&&at(today,e.getInt("startMinute"))<=now?today.plusDays(1):today;if(day(e.getDouble("startDate")).isBefore(b))e.put("endDate",Math.min(e.getDouble("endDate"),at(b.minusDays(1),0)));else a.remove(i);return;}}
    static class Span{double a,b;Span(double a,double b){this.a=a;this.b=b;}int minutes(){return Math.max(0,(int)((b-a)/60));}}
    static class Day{LocalDate d;List<Span> free;Day(LocalDate d,List<Span> f){this.d=d;free=f;}}
    static List<Span> merge(List<Span> a){List<Span> r=new ArrayList<>();a=new ArrayList<>(a);a.sort(Comparator.comparingDouble(v->v.a));for(Span s:a)if(s.b>s.a){if(!r.isEmpty()&&s.a<=r.get(r.size()-1).b)r.get(r.size()-1).b=Math.max(r.get(r.size()-1).b,s.b);else r.add(new Span(s.a,s.b));}return r;}
    static List<Span> subtract(List<Span> available,List<Span> blocks){List<Span> r=merge(available);for(Span b:merge(blocks)){List<Span> n=new ArrayList<>();for(Span s:r){if(b.a>=s.b||b.b<=s.a)n.add(s);else{if(s.a<b.a)n.add(new Span(s.a,b.a));if(b.b<s.b)n.add(new Span(b.b,s.b));}}r=n;}return r;}
    static boolean eligible(JSONObject c,LocalDate d){return !d.isBefore(day(c.optDouble("startDate")))&&!d.isAfter(day(c.optDouble("deadline")));}
    static int unit(JSONObject s,JSONObject c){return Math.max(1,c.optInt("minimumBlockMinutes")>0?c.optInt("minimumBlockMinutes"):s.optJSONObject("settings").optInt("minimumScheduleUnit"));}
    static Double take(List<Day> ds,int i,int n){List<Span> f=ds.get(i).free;for(int j=0;j<f.size();j++)if(f.get(j).minutes()>=n){Span v=f.get(j);double start=v.a;v.a+=n*60;if(v.minutes()==0)f.remove(j);return start;}return null;}
    static JSONObject task(String c,double start,int size)throws Exception{return new JSONObject().put("id",id()).put("courseID",c).put("start",start).put("durationMinutes",size).put("completedMinutes",0).put("status","future");}
    static List<Day> copyDays(List<Day> d){List<Day> out=new ArrayList<>();for(Day v:d)out.add(new Day(v.d,merge(v.free)));return out;}
    /** Deadline first allocation, bounded fragmentation repair, load balancing and interleaving. */
    public static List<String> replan(JSONObject s,double now)throws Exception{
        List<String> warnings=new ArrayList<>();LocalDate today=day(now),horizon=today;
        List<JSONObject> courses=new ArrayList<>(),active=new ArrayList<>(),history=new ArrayList<>();
        for(JSONObject c:list(s.getJSONArray("courses")))if(!c.optBoolean("isArchived")&&c.optBoolean("autoScheduleEnabled",true)&&remaining(s,c)>0){courses.add(c);if(day(c.getDouble("deadline")).isAfter(horizon))horizon=day(c.getDouble("deadline"));}
        if(horizon.isAfter(today.plusYears(10))){horizon=today.plusYears(10);warnings.add("仅生成未来十年的计划");}
        for(JSONObject t:list(s.getJSONArray("tasks"))){if(t.getDouble("start")<now||!pending(t))history.add(t);if(t.getDouble("start")<now&&end(t)>now&&pending(t))active.add(t);}
        List<Day> days=new ArrayList<>();for(LocalDate d=today;!d.isAfter(horizon);d=d.plusDays(1)){
            List<Span> windows=new ArrayList<>(),blocks=new ArrayList<>();for(JSONObject a:list(s.getJSONObject("settings").getJSONArray("availability")))if(a.getInt("weekday")==weekday(d))windows.add(new Span(Math.max(Math.ceil(now/60)*60,at(d,a.getInt("startMinute"))),at(d,a.getInt("endMinute"))));
            for(JSONObject e:list(s.getJSONArray("fixedEvents")))if(occurs(e,d))blocks.add(new Span(at(d,e.getInt("startMinute")),at(d,e.getInt("endMinute"))));for(JSONObject t:active)blocks.add(new Span(t.getDouble("start"),end(t)));days.add(new Day(d,subtract(windows,blocks)));
        }
        List<Day> original=copyDays(days);Map<String,Integer> required=new HashMap<>(),missing=new HashMap<>();Map<String,Double> demand=new HashMap<>();
        for(JSONObject c:courses){String id=c.getString("id");int r=remaining(s,c);for(JSONObject t:active)if(t.getString("courseID").equals(id))r-=t.getInt("durationMinutes");r=Math.max(0,r);required.put(id,r);int count=0;for(Day d:days)if(eligible(c,d.d))for(Span f:d.free)if(r>0&&f.minutes()>=Math.min(unit(s,c),r)){count++;break;}demand.put(id,count>0?(double)r/count:0);}
        courses.sort((a,b)->{int v=day(a.optDouble("deadline")).compareTo(day(b.optDouble("deadline")));if(v==0)v=Double.compare(demand.get(b.optString("id")),demand.get(a.optString("id")));if(v==0)v=Integer.compare(b.optInt("priority"),a.optInt("priority"));if(v==0)v=Integer.compare(unit(s,b),unit(s,a));return v!=0?v:a.optString("id").compareTo(b.optString("id"));});
        List<JSONObject> tasks=new ArrayList<>();for(JSONObject c:courses){String id=c.getString("id");int r=required.get(id);for(int i=0;i<days.size();i++)if(eligible(c,days.get(i).d))while(r>0){int n=Math.min(unit(s,c),r);Double start=take(days,i,n);if(start==null)break;tasks.add(task(id,start,n));r-=n;}missing.put(id,r);}
        int attempts=0;
        for(JSONObject c:courses){String cid=c.getString("id");int r=missing.get(cid);while(r>0&&attempts<200){int size=Math.min(unit(s,c),r);boolean repaired=false;
            search:for(int di=0;di<original.size();di++)if(eligible(c,original.get(di).d))for(Span span:original.get(di).free)if(span.minutes()>=size){List<Double> starts=new ArrayList<>();starts.add(span.a);for(JSONObject t:tasks)if(t.getDouble("start")>=span.a&&end(t)<span.b)starts.add(end(t));Collections.sort(starts);
                for(double start:starts){if(++attempts>200)break search;Span reserved=new Span(start,start+size*60);if(reserved.b>span.b)continue;List<JSONObject> blockers=new ArrayList<>();for(JSONObject t:tasks)if(t.getDouble("start")<reserved.b&&end(t)>reserved.a)blockers.add(t);
                    boolean immovable=false;for(JSONObject t:blockers){boolean found=false;JSONObject owner=course(s,t.getString("courseID"));for(Day d:days)if(eligible(owner,d.d))for(Span f:d.free)if(f.minutes()>=t.getInt("durationMinutes"))found=true;if(!found){immovable=true;break;}}if(immovable)continue;
                    List<Day> oldDays=copyDays(days);Map<String,Double> oldStarts=new HashMap<>();for(JSONObject t:blockers)oldStarts.put(t.getString("id"),t.getDouble("start"));
                    for(int di2=0;di2<days.size();di2++){List<Span> occupied=new ArrayList<>();occupied.add(reserved);for(JSONObject t:tasks)if(!blockers.contains(t)&&day(t.getDouble("start")).equals(days.get(di2).d))occupied.add(new Span(t.getDouble("start"),end(t)));days.get(di2).free=subtract(original.get(di2).free,occupied);}
                    blockers.sort((a,b)->Integer.compare(b.optInt("durationMinutes"),a.optInt("durationMinutes")));boolean ok=true;
                    for(JSONObject t:blockers){JSONObject owner=course(s,t.getString("courseID"));Double replacement=null;for(int i=0;i<days.size();i++)if(eligible(owner,days.get(i).d)){replacement=take(days,i,t.getInt("durationMinutes"));if(replacement!=null)break;}if(replacement==null){ok=false;break;}t.put("start",replacement);}
                    if(ok){tasks.add(task(cid,start,size));r-=size;repaired=true;break search;}days=oldDays;for(JSONObject t:blockers)t.put("start",oldStarts.get(t.getString("id")));
                }
            }if(!repaired)break;
        }missing.put(cid,r);}
        Map<LocalDate,Integer> indices=new HashMap<>();for(int i=0;i<days.size();i++)indices.put(days.get(i).d,i);int[] totals=new int[days.size()];Map<String,int[]> loads=new HashMap<>();for(JSONObject c:courses)loads.put(c.getString("id"),new int[days.size()]);for(JSONObject t:tasks){int i=indices.get(day(t.getDouble("start")));totals[i]+=t.getInt("durationMinutes");loads.get(t.getString("courseID"))[i]+=t.getInt("durationMinutes");}
        boolean changed=true;while(changed){changed=false;for(JSONObject t:tasks){String id=t.getString("courseID");JSONObject c=course(s,id);int src=indices.get(day(t.getDouble("start"))),size=t.getInt("durationMinutes"),target=-1;int[] load=loads.get(id);for(int i=0;i<days.size();i++)if(i!=src&&eligible(c,days.get(i).d)&&load[src]-load[i]>size){boolean fits=false;for(Span f:days.get(i).free)if(f.minutes()>=size)fits=true;if(fits&&(target<0||load[i]<load[target]||(load[i]==load[target]&&totals[i]<totals[target])))target=i;}
            if(target>=0){Double start=take(days,target,size);List<Span> f=days.get(src).free;f.add(new Span(t.getDouble("start"),end(t)));days.get(src).free=merge(f);t.put("start",start);totals[src]-=size;totals[target]+=size;load[src]-=size;load[target]+=size;changed=true;}
        }}
        List<JSONObject> packed=new ArrayList<>();for(Day d:original)for(Span span:d.free){List<JSONObject> pool=new ArrayList<>();for(JSONObject t:tasks)if(t.getDouble("start")>=span.a&&end(t)<=span.b)pool.add(t);pool.sort(Comparator.comparingDouble(t->t.optDouble("start")));double time=span.a;String previous="";while(!pool.isEmpty()){int pick=0;for(int i=0;i<pool.size();i++)if(!pool.get(i).getString("courseID").equals(previous)){pick=i;break;}JSONObject t=pool.remove(pick);t.put("start",time).put("status",d.d.equals(today)?"planned":"future");time=end(t);previous=t.getString("courseID");packed.add(t);}}
        for(JSONObject c:courses)if(missing.get(c.getString("id"))>0)warnings.add(c.getString("name")+"：截止 "+date(c.getDouble("deadline"))+"，仍有 "+missing.get(c.getString("id"))+" 分钟未排入，请增加可用时间或调整时间块。");
        for(JSONObject t:packed){String base="task|"+t.getString("courseID")+"|"+(long)t.getDouble("start")+"|"+t.getInt("durationMinutes");String stable=stableID(base);
            List<String> confirmed=new ArrayList<>();boolean collision=false;for(JSONObject old:list(s.getJSONArray("tasks")))if(!pending(old)&&old.getString("courseID").equals(t.getString("courseID"))){confirmed.add(old.getString("id"));if(old.getString("id").equals(stable))collision=true;}Collections.sort(confirmed);if(collision)stable=stableID(base+"|confirmed|"+String.join(",",confirmed));
            for(JSONObject old:list(s.getJSONArray("tasks")))if(pending(old)&&old.getString("courseID").equals(t.getString("courseID"))&&old.getDouble("start")==t.getDouble("start")&&old.getInt("durationMinutes")==t.getInt("durationMinutes")){stable=old.getString("id");break;}
            t.put("id",stable);
        }
        history.addAll(packed);history.sort(Comparator.comparingDouble(t->t.optDouble("start")));s.put("tasks",array(history));s.put("androidWarnings",new JSONArray(warnings));return warnings;
    }
}
