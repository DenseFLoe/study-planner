package local.studyplanner;

import org.json.*;
import java.net.*;
import java.util.*;

/** Only explicitly bound, complete provider courses may be updated unattended. */
final class WebsiteUpdatePolicy {
    static String site(String text){try{
        URI u=new URI(text);if(!"https".equals(u.getScheme())||u.getUserInfo()!=null||u.getPort()!=-1&&u.getPort()!=443)return "";
        String host=u.getHost();if("www.kaoyanvip.cn".equals(host)||"kaoyanvip.cn".equals(host))return "yantu";
        if("www.ixuecheng.cn".equals(host)||"ixuecheng.cn".equals(host))return "xuecheng";
    }catch(Exception ignored){}return "";}
    static String sourceURL(String text,JSONObject course)throws Exception{
        JSONObject web=course.optJSONObject("webCourse");String provider=web==null?"":site(web.optString("sourceURL"));
        if(provider.isEmpty()||course.optJSONArray("mergedSources")!=null||course.optBoolean("isArchived"))throw new IllegalArgumentException("仅研途和学丞的独立网站课程支持自动更新。");
        URI u=new URI(text.trim());String id=web.getString("packageID");
        if(!provider.equals(site(text.trim())))throw new IllegalArgumentException("请输入原课程网站的 HTTPS 地址。");
        if(provider.equals("yantu")){
            if(!id.matches("[0-9]+")||!u.getPath().equals("/appmanage/my/mycourse/delivery-packages/"+id+"/outline")||u.getQuery()!=null)throw new IllegalArgumentException("研途网址须为原课程包的大纲地址。");
        }else{
            Map<String,String> values=new HashMap<>();if(u.getRawQuery()!=null)for(String part:u.getRawQuery().split("&")){
                String[] p=part.split("=",2);if(p.length!=2||!p[0].matches("id|type")||!p[1].matches("[A-Za-z0-9_-]{1,128}")||values.put(p[0],p[1])!=null)throw new IllegalArgumentException("学丞网址只接受唯一的课程编号和类型。");
            }
            if(!"/detail".equals(u.getPath())||!id.equals("generic:"+values.get("id")))throw new IllegalArgumentException("学丞网址须对应原课程编号。");
        }
        return new URI(u.getScheme(),null,u.getHost(),u.getPort(),u.getPath(),u.getQuery(),null).toString();
    }
    static String suggested(JSONObject course)throws Exception{
        JSONObject web=course.getJSONObject("webCourse");String id=web.getString("packageID"),url=web.getString("sourceURL");
        if(site(url).equals("yantu"))return "https://www.kaoyanvip.cn/appmanage/my/mycourse/delivery-packages/"+id+"/outline";
        return "https://www.ixuecheng.cn/detail?id="+id.replaceFirst("^generic:","");
    }
    static boolean liveID(String id,String name,String packageID){
        String prefix=packageID+":live:"+name+":";
        return !name.isEmpty()&&id.startsWith(prefix)&&id.substring(prefix.length()).matches("(?:[0-9]+|(?:[0-9]+(?:\\.[0-9]+)*)?:[0-9]+)");
    }
    static JSONObject validate(JSONObject raw,JSONObject course)throws Exception{
        JSONObject old=course.getJSONObject("webCourse"),next=WebCourseImport.sanitize(raw);
        if(!WebCourseImport.sameIdentity(old,next)||!site(old.optString("sourceURL")).equals(site(next.optString("sourceURL")))||site(next.optString("sourceURL")).isEmpty()||WebCourseImport.problem(next)!=null||next.getDouble("fetchedAt")<old.getDouble("fetchedAt"))throw new IllegalArgumentException("课程不匹配、结果较旧或目录不完整，原数据已保留。");
        Set<String> deleted=CourseTools.deletedIDs(course),incoming=new HashSet<>(),known=new HashSet<>(deleted);
        Map<String,JSONObject> oldByID=new HashMap<>();Map<String,Set<String>> knownNames=new HashMap<>();Map<String,Integer> counts=new HashMap<>();
        for(JSONObject lesson:Planner.list(old.getJSONArray("lessons"))){String id=lesson.getString("id");known.add(id);oldByID.put(id,lesson);knownNames.computeIfAbsent(lesson.getString("name"),k->new HashSet<>()).add(id);}
        for(JSONObject lesson:Planner.list(next.getJSONArray("lessons"))){incoming.add(lesson.getString("id"));counts.merge(lesson.getString("name"),1,Integer::sum);}
        if(site(next.optString("sourceURL")).equals("xuecheng")){
            for(String id:deleted)if(!oldByID.containsKey(id)){List<String> names=new ArrayList<>();for(String name:counts.keySet())if(liveID(id,name,old.getString("packageID")))names.add(name);if(names.size()>1)throw ambiguous();if(names.size()==1)knownNames.computeIfAbsent(names.get(0),k->new HashSet<>()).add(id);}
            for(JSONObject lesson:Planner.list(next.getJSONArray("lessons"))){String id=lesson.getString("id"),name=lesson.getString("name");Set<String> candidates=knownNames.get(name);
                if(known.contains(id)||!"living".equals(lesson.optString("kind"))||!liveID(id,name,next.getString("packageID"))||candidates==null||candidates.isEmpty())continue;
                if(candidates.size()!=1||counts.get(name)!=1)throw ambiguous();String previous=candidates.iterator().next();if(incoming.contains(previous))throw ambiguous();
                if(!liveID(previous,name,old.getString("packageID")))continue;JSONObject before=oldByID.get(previous);boolean same=before==null||"living".equals(before.optString("kind"));
                if(before!=null)for(String key:new String[]{"subject","stage","chapter"})same&=before.optString(key).equals(lesson.optString(key));
                if(same)lesson.put("id",previous);
            }
        }
        Set<String> updated=new HashSet<>();for(JSONObject lesson:Planner.list(next.getJSONArray("lessons")))if(!updated.add(lesson.getString("id")))throw ambiguous();
        for(String id:oldByID.keySet())if(!deleted.contains(id)&&!updated.contains(id))throw new IllegalArgumentException("已有课节未能完整对应，可能目录缺失或编号变化；原课程已保留。");
        return next;
    }
    private static IllegalArgumentException ambiguous(){return new IllegalArgumentException("直播课节编号变化且无法唯一对应，请人工核对；学习记录和删除标记已保留。");}
    static void apply(JSONObject state,String courseID,JSONObject snapshot,double now)throws Exception{
        JSONObject course=Planner.course(state,courseID);if(course==null||course.optBoolean("isArchived")||course.optJSONArray("mergedSources")!=null)throw new IllegalArgumentException("课程已删除或合并，本次更新取消。");
        JSONObject next=CourseTools.copy(state),validated=validate(snapshot,course);String type=course.getString("type");
        WebCourseImport.save(next,Collections.singletonList(validated),Math.max(course.getDouble("deadline"),Planner.at(Planner.day(now),0)),now);
        Planner.course(next,courseID).put("type",type);Planner.replan(next,now);Planner.validate(next);
        Iterator<String> keys=next.keys();while(keys.hasNext()){String key=keys.next();state.put(key,next.get(key));}
    }
}
