package local.studyplanner;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.*;
import java.util.*;

/** Wire display data only. This class intentionally contains no compression/search algorithm. */
final class CompressedPreview {
    static final String FIELD="compressedSchedulePreview";
    static List<JSONObject> sorted(JSONObject state,String key)throws Exception {List<JSONObject> rows=Planner.list(state.optJSONArray(key));rows.sort(Comparator.comparing(v->v.optString("id")));return rows;}
    static String signature(JSONObject state)throws Exception {
        JSONArray tasks=new JSONArray(),windows=new JSONArray();
        for(JSONObject t:sorted(state,"tasks"))if(t.has("confirmedAt")){JSONObject row=new JSONObject();for(String k:new String[]{"id","courseID","lessonID"})if(t.has(k))row.put(k,t.get(k));tasks.put(row);}
        JSONObject settings=state.getJSONObject("settings");List<JSONObject> availability=Planner.list(settings.getJSONArray("availability"));
        availability.sort(Comparator.comparingInt((JSONObject w)->w.optInt("weekday")).thenComparingInt(w->w.optInt("startMinute")).thenComparingInt(w->w.optInt("endMinute")));
        for(JSONObject w:availability)windows.put(new JSONObject().put("weekday",w.getInt("weekday")).put("startMinute",w.getInt("startMinute")).put("endMinute",w.getInt("endMinute")));
        JSONObject input=new JSONObject().put("courses",new JSONArray(sorted(state,"courses"))).put("fixedEvents",new JSONArray(sorted(state,"fixedEvents"))).put("completions",new JSONArray(sorted(state,"completions"))).put("tasks",tasks).put("availability",windows).put("minimumScheduleUnit",settings.getInt("minimumScheduleUnit"));
        byte[] hash=MessageDigest.getInstance("SHA-256").digest(canonical(input,"").getBytes(StandardCharsets.UTF_8));StringBuilder out=new StringBuilder();for(byte b:hash)out.append(String.format(Locale.ROOT,"%02x",b&255));return out.toString();
    }
    static String canonical(Object value,String field)throws Exception {
        if(value instanceof JSONObject){JSONObject o=(JSONObject)value;List<String> keys=new ArrayList<>();Iterator<String> it=o.keys();while(it.hasNext())keys.add(it.next());Collections.sort(keys);StringBuilder s=new StringBuilder("{");for(String key:keys)s.append(canonical(key,"")).append(canonical(o.get(key),key));return s.append('}').toString();}
        if(value instanceof JSONArray){JSONArray a=(JSONArray)value;List<String> parts=new ArrayList<>();for(int i=0;i<a.length();i++)parts.add(canonical(a.get(i),""));if(Arrays.asList("weekdays","excludedDates","deletedLessonIDs").contains(field))Collections.sort(parts);return "["+String.join("",parts)+"]";}
        if(value instanceof String){String s=(String)value;return "s"+s.getBytes(StandardCharsets.UTF_8).length+":"+s;}
        if(value instanceof Boolean)return value.toString();
        if(value instanceof Number)return "n"+new java.math.BigDecimal(value.toString()).stripTrailingZeros().toPlainString()+";";
        if(value==JSONObject.NULL||value==null)return "null";
        throw new IllegalArgumentException("压缩结果来源数据无效");
    }
    static void validate(JSONObject p)throws Exception {
        if(p.getInt("format")!=1||!p.getString("sourceSignature").matches("[a-f0-9]{64}")||p.getJSONArray("rows").length()>2000||p.getJSONArray("courses").length()>1000||p.getInt("totalRows")<p.getJSONArray("rows").length())throw new IllegalArgumentException("压缩结果格式无效");
        LocalDate.parse(p.getString("inputDay"));if(!Double.isFinite(p.getDouble("capturedAt"))||(p.has("finish")&&!Double.isFinite(p.getDouble("finish"))))throw new IllegalArgumentException("压缩结果日期无效");
        for(JSONObject row:Planner.list(p.getJSONArray("rows")))if(!Double.isFinite(row.getDouble("start"))||!Double.isFinite(row.getDouble("end"))||row.getDouble("end")<=row.getDouble("start")||row.getString("title").length()>480)throw new IllegalArgumentException("压缩预览时间无效");
        for(JSONObject course:Planner.list(p.getJSONArray("courses")))if(course.getInt("remainingMinutes")<0||course.getString("name").length()>240||(course.has("finish")&&!Double.isFinite(course.getDouble("finish"))))throw new IllegalArgumentException("压缩预览课程无效");
    }
    static boolean current(JSONObject p,JSONObject state,double now)throws Exception {validate(p);return p.getString("inputDay").equals(Planner.day(now).toString())&&p.getString("sourceSignature").equals(signature(state));}
}
