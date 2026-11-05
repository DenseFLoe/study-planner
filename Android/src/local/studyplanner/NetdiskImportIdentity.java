package local.studyplanner;

import org.json.*;
import java.util.*;

/** Repairs only legacy directory bindings supported by both source and lesson identities. */
public final class NetdiskImportIdentity {
    private static Set<String> lessonIDs(JSONObject snapshot)throws Exception {
        Set<String> ids=new HashSet<>();
        for(JSONObject lesson:Planner.list(snapshot.optJSONArray("lessons")))ids.add(lesson.getString("id"));
        return ids;
    }
    private static List<String> sources(JSONObject metadata,String fallback)throws Exception {
        JSONArray array=metadata.optJSONArray("sourcePackageIDs");
        if(array==null||array.length()==0)return Collections.singletonList(fallback);
        List<String> result=new ArrayList<>();for(int i=0;i<array.length();i++)result.add(array.getString(i));return result;
    }
    /** The caller supplies a disposable state copy; failed validation never reaches live data. */
    static void reconcile(JSONObject state,List<JSONObject> captures)throws Exception {
        List<JSONObject> courses=Planner.list(state.getJSONArray("courses"));
        for(JSONObject candidate:captures){
            JSONObject incoming=candidate.optJSONObject("netdisk");if(incoming==null)continue;
            String pwd=incoming.getString("pwdID"),prefix="quark:"+pwd+":",id=candidate.getString("packageID");
            Set<String> desired=new HashSet<>(sources(incoming,id));List<JSONObject> legacy=new ArrayList<>();
            for(JSONObject course:courses){
                JSONObject metadata=course.optJSONObject("netdisk"),previous=course.optJSONObject("webCourse");
                if(metadata==null||previous==null||!pwd.equals(metadata.optString("pwdID")))continue;
                String locator=metadata.optString("sourceURL"),folder=CourseSourcePrivacy.netdiskFolder(locator);
                if(folder.isEmpty()||!pwd.equals(CourseSourcePrivacy.netdiskShare(locator)))continue;
                List<String> old=sources(metadata,previous.getString("packageID")),corrected=new ArrayList<>();
                for(String source:old)corrected.add(source.equals(prefix+"root")?prefix+folder:
                    source.startsWith(prefix+":series:")?prefix+folder+source.substring(prefix.length()):source);
                if(!corrected.equals(old)&&new HashSet<>(corrected).equals(desired))legacy.add(course);
            }
            if(legacy.isEmpty())continue;
            boolean canonical=false;for(JSONObject course:courses){JSONObject web=course.optJSONObject("webCourse");if(web!=null&&id.equals(web.optString("packageID")))canonical=true;}
            if(legacy.size()!=1||canonical)throw new IllegalArgumentException("多个已有课程对应同一网盘子目录，请先核对重复课程；原课程和学习记录已保留。");
            JSONObject previous=legacy.get(0).getJSONObject("webCourse");Set<String> oldLessons=lessonIDs(previous);
            if(oldLessons.isEmpty()||!lessonIDs(candidate).containsAll(oldLessons))throw new IllegalArgumentException("旧子目录课程的课节无法完整对应，请重新核对目录；原课程和学习记录已保留。");
            previous.put("packageID",id);
        }
        for(JSONObject candidate:captures){
            JSONObject metadata=candidate.optJSONObject("netdisk");if(metadata==null)continue;
            String id=candidate.getString("packageID");if(!id.equals("quark:"+metadata.getString("pwdID")+":root"))continue;
            for(JSONObject course:courses){
                JSONObject previous=course.optJSONObject("webCourse");if(previous==null||!id.equals(previous.optString("packageID")))continue;
                JSONObject source=course.optJSONObject("netdisk");
                if(source!=null&&!CourseSourcePrivacy.netdiskFolder(source.optString("sourceURL")).isEmpty())
                    throw new IllegalArgumentException("已有旧版子目录课程使用根目录编号，请先重新读取该子目录并核对；原课程和学习记录已保留。");
                if(!lessonIDs(candidate).containsAll(lessonIDs(previous)))throw new IllegalArgumentException("已有根目录课程的课节无法完整对应，请核对来源和目录；原课程和学习记录已保留。");
            }
        }
    }
}
