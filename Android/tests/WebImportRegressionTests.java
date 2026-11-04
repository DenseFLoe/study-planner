package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.util.*;

/** Shared Swift/Java fixtures plus real import, sync and capture-merge regressions. */
public final class WebImportRegressionTests {
 static int checks;
 static final double now=ImportParityTests.now, deadline=ImportParityTests.deadline;
 static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
 static JSONObject capture(String host,int duration)throws Exception{
  JSONObject row=new JSONObject().put("id","L1").put("courseId","88").put("name","Course").put("duration",duration).put("percent",0);
  JSONArray responses=new JSONArray().put(new JSONObject().put("url","https://"+host+"/api?access_token=SYNTHETIC_TOKEN").put("body",new JSONObject().put("data",new JSONArray().put(row)).toString()));
  return GenericCourseDigest.snapshots(responses,"https://"+host+"/course?session=SYNTHETIC_SESSION","Synthetic",now).get(0);
 }
 static void fixtures()throws Exception{
  JSONArray fixtures=new JSONArray(Files.readString(Paths.get("Tests/Fixtures/web-import-regressions.json")));
  for(JSONObject fixture:Planner.list(fixtures)){
   String name=fixture.getString("name");JSONArray responses=new JSONArray();
   for(JSONObject body:Planner.list(fixture.getJSONArray("bodies")))responses.put(new JSONObject().put("url","https://a.example/api").put("body",body.toString()));
   JSONObject value=GenericCourseDigest.snapshots(responses,"https://a.example/course","Synthetic",now).get(0);
   JSONArray lessons=value.getJSONArray("lessons"),percent=fixture.getJSONArray("percent"),seconds=fixture.getJSONArray("seconds");
   check(lessons.length()==percent.length(),name+": lesson count");
   for(int i=0;i<lessons.length();i++){check(lessons.getJSONObject(i).getDouble("watchedPercent")==percent.getDouble(i),name+": percent");check(lessons.getJSONObject(i).optDouble("durationSeconds",0)==seconds.getDouble(i),name+": duration");}
   check((WebCourseImport.problem(value)==null)==fixture.getBoolean("valid"),name+": validity");
   JSONObject state=PlannerTests.empty();
   if(!fixture.getBoolean("valid")){try{WebCourseImport.save(state,Collections.singletonList(value),deadline,now);throw new AssertionError(name+": accepted conflicting data");}catch(IllegalArgumentException expected){check(state.getJSONArray("courses").length()==0,name+": partial write");}continue;}
   WebCourseImport.save(state,Collections.singletonList(value),deadline,now);JSONObject course=state.getJSONArray("courses").getJSONObject(0);
   check(course.getInt("totalMinutes")==fixture.getInt("totalMinutes"),name+": final total");
   check(Planner.completed(state,course)==fixture.getInt("completedMinutes"),name+": final completion");
   List<Planner.Work> work=Planner.lessonWorkAll(state,course);
   check(work.size()==fixture.getInt("workItems"),name+": work items");
   check(work.stream().mapToInt(w->w.minutes).sum()==fixture.getInt("totalMinutes")-fixture.getInt("completedMinutes"),name+": remaining");
  }
 }
 static void identity()throws Exception{
  JSONObject a=capture("a.example",3600),b=capture("b.example",7200),state=PlannerTests.empty();
  check(a.getString("packageID").equals(b.getString("packageID")),"Legacy package IDs changed");
  check(!WebCourseImport.identity(a).equals(WebCourseImport.identity(b)),"Cross-site identity collided");
  WebCourseImport.save(state,Arrays.asList(a,b),deadline,now);check(state.getJSONArray("courses").length()==2,"Batch collapsed sites");
  state=PlannerTests.empty();WebCourseImport.save(state,Collections.singletonList(a),deadline,now);
  JSONObject old=state.getJSONArray("courses").getJSONObject(0);String id=old.getString("id"),lessonID=a.getJSONArray("lessons").getJSONObject(0).getString("id");
  JSONObject task=Planner.task(id,now,60).put("lessonID",lessonID);state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),60,now);
  old.put("lessonOrderCustomized",true).put("deletedLessonIDs",new JSONArray().put("generic:88:deleted"));
  WebCourseImport.save(state,Collections.singletonList(b),deadline,now);JSONObject other=state.getJSONArray("courses").getJSONObject(1);
  check(Planner.completed(state,other)==0&&Planner.remaining(state,other)==120,"Cross-site history credited");check(!other.has("deletedLessonIDs"),"Cross-site deletion copied");
  JSONObject fresh=CourseTools.copy(a).put("sourceURL","https://A.EXAMPLE:443/new-page?token=SYNTHETIC_TOKEN");fresh.getJSONArray("lessons").put(ImportParityTests.lesson("generic:88:deleted",3600,0));
  WebCourseImport.save(state,Collections.singletonList(fresh),deadline,now);old=Planner.course(state,id);
  check(state.getJSONArray("courses").length()==2,"Legacy same-site update duplicated");check(old.getJSONObject("webCourse").getJSONArray("lessons").length()==1,"Deleted lesson restored");check(Planner.completed(state,old)==60,"Legacy refresh lost completion");check(old.optBoolean("lessonOrderCustomized"),"Legacy custom order lost");
  SyncLedger ledger=new SyncLedger();ledger.capture(state);SyncLedger peer=new SyncLedger();peer.merge(ledger.changes(0));JSONObject restored=peer.materialize();
  check(restored.getJSONArray("courses").length()==2,"Sync collapsed sites");check(Planner.completed(restored,Planner.course(restored,id))==60,"Sync lost history");
  List<JSONObject> merged=WebsiteCapture.merge(Collections.singletonList(a),Collections.singletonList(b));check(merged.size()==2,"Capture merged unrelated sites");check(WebsiteCapture.merge(merged,Collections.singletonList(a)).size()==2,"Capture repeated site");
  JSONObject fuller=WebsiteCapture.merge(Collections.singletonList(a),Collections.singletonList(capture("a.example",0))).get(0);check(WebCourseImport.total(fuller)==60&&WebCourseImport.problem(fuller)==null,"Thin capture erased timing flags");
  for(boolean ambiguous:new boolean[]{false,true}){
   JSONObject conflict=PlannerTests.empty();WebCourseImport.save(conflict,Collections.singletonList(a),deadline,now);JSONObject first=conflict.getJSONArray("courses").getJSONObject(0);
   if(ambiguous)conflict.getJSONArray("courses").put(CourseTools.copy(first).put("id",Planner.id()));else first.getJSONObject("webCourse").put("sourceURL","");
   String before=conflict.toString();try{WebCourseImport.save(conflict,Arrays.asList(b,a),deadline,now);throw new AssertionError("Ambiguous legacy source accepted");}catch(IllegalArgumentException expected){check(conflict.toString().equals(before),"Ambiguous batch partially saved");}
  }
 }
 static void privacy()throws Exception{
  String source="https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@ixuecheng.cn/detail?id=88&type=1&token=SYNTHETIC_TOKEN&session=SYNTHETIC_SESSION#SYNTHETIC_FRAGMENT";
  check(WebCourseImport.safeURL(source).equals("https://ixuecheng.cn/detail?id=88&type=1"),"Public locator lost or credential persisted");
  JSONObject capture=capture("a.example",3600);check(capture.getString("sourceURL").equals("https://a.example/course"),"API URL used instead of page");
  JSONObject state=PlannerTests.empty();WebCourseImport.save(state,Collections.singletonList(capture.put("sourceURL",source)),deadline,now);
  check(!state.toString().contains("SYNTHETIC_"),"Import persisted URL credentials");SyncLedger ledger=new SyncLedger();ledger.capture(state);check(!ledger.changes(0).toString().contains("SYNTHETIC_"),"Sync persisted URL credentials");
  check(WebCourseImport.origin("https://www.ixuecheng.cn:443/detail?id=88").equals(WebCourseImport.origin(source)),"Known www alias changed identity");
  JSONObject catalog=new JSONObject().put("courseID","88").put("name","Live").put("rows",new JSONArray().put(new JSONObject().put("name","Course").put("key","0").put("replay",true)));
  JSONObject foreign=capture("other.example",3600);foreign.getJSONArray("lessons").getJSONObject(0).put("watchedPercent",100);
  JSONObject live=WebsiteCapture.xuecheng(catalog,Collections.singletonList(foreign),source,now);check(live.getJSONArray("lessons").getJSONObject(0).getDouble("watchedPercent")==0,"Xuecheng reused foreign progress");
 }
 static void customCourseNames()throws Exception{
  JSONObject state=PlannerTests.empty(),snapshot=capture("names.example",3600).put("name","网站原名");
  WebCourseImport.save(state,Collections.singletonList(snapshot),deadline,now);
  JSONObject course=state.getJSONArray("courses").getJSONObject(0);String id=course.getString("id");
  check(course.getString("name").equals("网站原名"),"First import did not use website name");
  course.put("name","我的复习计划").put("notes","保留备注");
  JSONObject fresh=CourseTools.copy(snapshot).put("name","网站新名").put("fetchedAt",now+1);
  fresh.getJSONArray("lessons").getJSONObject(0).put("watchedPercent",50);
  WebCourseImport.save(state,Collections.singletonList(fresh),deadline,now+1);course=Planner.course(state,id);
  check(course.getString("name").equals("我的复习计划"),"Website refresh replaced custom name");
  check(course.getJSONObject("webCourse").getString("name").equals("网站新名")&&Planner.completed(state,course)==30,"Keeping a custom name blocked website progress");
  check(course.getString("notes").equals("保留备注"),"Refresh changed notes");
  course.put("name","网站新名");fresh.put("name","网站再次改名").put("fetchedAt",now+2);
  WebCourseImport.save(state,Collections.singletonList(fresh),deadline,now+2);course=Planner.course(state,id);
  check(course.getString("name").equals("网站再次改名"),"Uncustomized name stopped following website");
  course.put("name","归档前自定义名").put("isArchived",true);
  fresh.put("name","新的来源名").put("fetchedAt",now+3);
  WebCourseImport.save(state,Collections.singletonList(fresh),deadline,now+3);course=Planner.course(state,id);
  check(course.getString("name").equals("归档前自定义名")&&!course.optBoolean("isArchived"),"Reimport lost archived course custom name");
 }
 public static void main(String[] args)throws Exception{fixtures();identity();privacy();customCourseNames();System.out.println("WebImportRegressionTests: "+checks+" checks passed");}
}
