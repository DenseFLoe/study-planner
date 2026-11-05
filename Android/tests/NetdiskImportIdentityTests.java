package local.studyplanner;

import org.json.*;
import java.util.*;

/** Directory links, legacy bindings and failed batches must preserve the original study history. */
public final class NetdiskImportIdentityTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static String url(String folder){return "https://pan.quark.cn/s/abc123"+(folder.isEmpty()?"":"#/list/share/"+folder);}
    static JSONObject scan(String folder,JSONArray entries)throws Exception {
        return new JSONObject().put("pwdID","abc123").put("rootFID",folder).put("shareTitle","课程")
            .put("sourceURL",url(folder)).put("fetchedAt",ImportParityTests.now).put("entries",entries);
    }
    static JSONArray videos(String folder)throws Exception {
        JSONArray entries=new JSONArray();
        for(int i=1;i<=3;i++)entries.put(ImportParityTests.video("",(folder.isEmpty()?"root":folder)+"v"+i,"第"+i+"讲",600.0));
        return entries;
    }
    static JSONObject fixture(String folder)throws Exception {
        List<JSONObject> values=NetdiskImport.build(scan(folder,videos(folder)));
        check(values.size()==1,"Direct directory recognition changed");return values.get(0);
    }
    static JSONObject legacy(JSONObject fresh,String folder)throws Exception {
        JSONObject old=CourseTools.copy(fresh);String prefix="quark:abc123:";
        old.put("packageID",old.getString("packageID").replace(prefix+folder+":series:",prefix+":series:")
            .replace(prefix+folder,prefix+"root"));
        return old;
    }
    static void save(JSONObject state,JSONObject... captures)throws Exception {
        WebCourseImport.save(state,Arrays.asList(captures),ImportParityTests.deadline,ImportParityTests.now);
    }
    static void reject(JSONObject state,JSONObject... captures)throws Exception {
        String before=state.toString();
        try{save(state,captures);throw new AssertionError("Ambiguous or incomplete binding accepted");}
        catch(IllegalArgumentException expected){check(before.equals(state.toString()),"Rejected import changed live data");}
    }
    static void separateDirectories()throws Exception {
        JSONObject state=PlannerTests.empty(),a=fixture("aaaa0001"),b=fixture("bbbb0002"),root=fixture("");
        save(state,a,b,root);check(state.getJSONArray("courses").length()==3,"Distinct subdirectories collided");
        String id=state.getJSONArray("courses").getJSONObject(0).getString("id");save(state,a);
        check(state.getJSONArray("courses").length()==3&&Planner.course(state,id)!=null,"Repeated import duplicated course");
        JSONArray nested=new JSONArray().put(ImportParityTests.folder("高数").put("fid","aaaa0001"));
        for(JSONObject video:Planner.list(videos("aaaa0001")))nested.put(video.put("parentPath","高数").put("relativePath","高数/"+video.getString("name")));
        check(NetdiskImport.build(scan("",nested)).get(0).getString("packageID").equals(a.getString("packageID")),"Full share and direct directory identities differ");
        for(JSONObject invalid:new JSONObject[]{scan("aaaa0001",videos("aaaa0001")).put("rootFID","bbbb0002"),scan("aaaa0001",videos("aaaa0001")).put("pwdID","other"),scan("aaaa0001",videos("aaaa0001")).put("rootFID",7)}){
            try{NetdiskImport.build(invalid);throw new AssertionError("Mismatched source locator accepted");}
            catch(IllegalArgumentException expected){checks++;}
        }
    }
    static void migrationRetainsHistory()throws Exception {
        JSONObject fresh=fixture("aaaa0001"),state=PlannerTests.empty();save(state,legacy(fresh,"aaaa0001"));
        JSONObject course=state.getJSONArray("courses").getJSONObject(0);String id=course.getString("id");
        JSONArray lessons=course.getJSONObject("webCourse").getJSONArray("lessons"),order=new JSONArray();
        for(int i=lessons.length()-1;i>=0;i--)order.put(lessons.getJSONObject(i).getString("id"));
        course.put("name","我的复习计划").put("lessonOrder",order).put("lessonOrderCustomized",true).put("deletedLessonIDs",new JSONArray().put("removed"));
        JSONObject task=Planner.task(id,ImportParityTests.now,10).put("lessonID",lessons.getJSONObject(0).getString("id"));
        state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),5,ImportParityTests.now);
        String tasks=state.getJSONArray("tasks").toString(),records=state.getJSONArray("completions").toString();save(state,fresh);course=Planner.course(state,id);
        check(state.getJSONArray("courses").length()==1,"Legacy directory duplicated");
        check(course.getJSONObject("webCourse").getString("packageID").equals(fresh.getString("packageID")),"Legacy identity not repaired");
        check(course.getString("name").equals("我的复习计划"),"Custom course title lost");
        check(course.getJSONArray("lessonOrder").toString().equals(order.toString()),"Manual order lost");
        check(course.getJSONArray("deletedLessonIDs").getString(0).equals("removed"),"Deletion marker lost");
        check(tasks.equals(state.getJSONArray("tasks").toString())&&records.equals(state.getJSONArray("completions").toString()),"History rewritten");
        check(Planner.completed(state,course)==5,"Progress changed during migration");
    }
    static void conflictsAreAtomic()throws Exception {
        JSONObject fresh=fixture("aaaa0001"),state=PlannerTests.empty();save(state,legacy(fresh,"aaaa0001"));
        JSONObject incomplete=CourseTools.copy(fresh);incomplete.getJSONArray("lessons").remove(0);reject(state,incomplete);
        JSONObject invalid=ImportParityTests.snapshot(0,0,ImportParityTests.now);invalid.getJSONArray("lessons").getJSONObject(0).remove("durationSeconds");reject(state,fresh,invalid);
        JSONObject canonical=PlannerTests.empty();save(canonical,fresh);state.getJSONArray("courses").put(canonical.getJSONArray("courses").getJSONObject(0));reject(state,fresh);
        state=PlannerTests.empty();save(state,legacy(fresh,"aaaa0001"));reject(state,fixture(""));
        JSONObject unknown=CourseTools.copy(state);unknown.getJSONArray("courses").getJSONObject(0).getJSONObject("netdisk").put("sourceURL",url(""));reject(unknown,fixture(""));
        save(state,fresh,fixture(""));check(state.getJSONArray("courses").length()==2,"Migrated subdirectory prevented separate root import");
        state=PlannerTests.empty();JSONObject root=fixture("");save(state,root);String id=state.getJSONArray("courses").getJSONObject(0).getString("id");
        JSONArray expanded=videos("").put(ImportParityTests.video("","rootv4","第4讲",600.0));save(state,NetdiskImport.build(scan("",expanded)).get(0));
        check(state.getJSONArray("courses").length()==1&&Planner.course(state,id).getJSONObject("webCourse").getJSONArray("lessons").length()==4,"Root refresh with all old lessons failed");
    }
    static void seriesAndMerges()throws Exception {
        JSONArray entries=new JSONArray();
        for(String stem:new String[]{"高数课节","线代课节"})for(int i=1;i<=3;i++){
            String name=stem+String.format(Locale.ROOT,"%02d",i);
            entries.put(ImportParityTests.folder(name)).put(ImportParityTests.video(name,stem+i,"第"+i+"讲",600.0));
        }
        List<JSONObject> fresh=NetdiskImport.build(scan("aaaa0001",entries)),old=new ArrayList<>();
        check(fresh.size()==2,"Lecture series recognition changed");for(JSONObject value:fresh)old.add(legacy(value,"aaaa0001"));
        for(boolean merged:new boolean[]{false,true}){
            JSONObject state=PlannerTests.empty();List<JSONObject> previous=merged?Collections.singletonList(NetdiskImport.merge(old,"数学合集")):old;
            List<JSONObject> current=merged?Collections.singletonList(NetdiskImport.merge(fresh,"数学合集")):fresh;
            save(state,previous.toArray(new JSONObject[0]));List<String> ids=new ArrayList<>();for(JSONObject course:Planner.list(state.getJSONArray("courses")))ids.add(course.getString("id"));
            save(state,current.toArray(new JSONObject[0]));check(state.getJSONArray("courses").length()==ids.size(),"Series migration duplicated courses");
            for(int i=0;i<ids.size();i++)check(Planner.course(state,ids.get(i)).getJSONObject("webCourse").getString("packageID").equals(current.get(i).getString("packageID")),"Series migration lost identity");
        }
    }
    public static void main(String[] args)throws Exception {separateDirectories();migrationRetainsHistory();conflictsAreAtomic();seriesAndMerges();System.out.println("NetdiskImportIdentityTests: "+checks+" checks passed");}
}
