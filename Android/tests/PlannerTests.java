package local.studyplanner;
import org.json.*;import java.nio.file.*;import java.time.*;import java.util.*;
public class PlannerTests {
 static int checks=0; static void check(boolean b,String message){checks++;if(!b)throw new AssertionError(message);}
 static JSONObject clone(JSONObject s)throws Exception{return new JSONObject(s.toString());}
 static JSONObject empty()throws Exception{return new JSONObject("{\"schemaVersion\":1,\"courses\":[],\"fixedEvents\":[],\"tasks\":[],\"completions\":[],\"settings\":{\"minimumScheduleUnit\":60,\"notificationMinute\":1260,\"availability\":[]}}");}
 static JSONObject course(String name,int total,LocalDate start,LocalDate deadline,int unit)throws Exception{return new JSONObject().put("id",Planner.id()).put("name",name).put("totalMinutes",total).put("initialCompletedMinutes",0).put("startDate",Planner.at(start,0)).put("deadline",Planner.at(deadline,0)).put("minimumBlockMinutes",unit).put("priority",2).put("autoScheduleEnabled",true).put("isArchived",false);}
 static void invariant(JSONObject s,double now)throws Exception{
  List<JSONObject> tasks=new ArrayList<>();for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(t)&&t.getDouble("start")>=now)tasks.add(t);tasks.sort(Comparator.comparingDouble(t->t.optDouble("start")));
  for(int i=0;i<tasks.size();i++){JSONObject t=tasks.get(i),c=Planner.course(s,t.getString("courseID"));LocalDate day=Planner.day(t.getDouble("start"));check(Planner.eligible(c,day),"Outside course dates");if(i>0)check(Planner.end(tasks.get(i-1))+15*60<=t.getDouble("start"),"Tasks need a 15-minute break");for(JSONObject e:Planner.list(s.getJSONArray("fixedEvents")))if(Planner.occurs(e,day))check(t.getDouble("start")>=Planner.at(day,e.getInt("endMinute"))||Planner.end(t)<=Planner.at(day,e.getInt("startMinute")),"Fixed overlap");boolean fits=false;List<Planner.Span> windows=new ArrayList<>();for(JSONObject a:Planner.list(s.getJSONObject("settings").getJSONArray("availability")))if(a.getInt("weekday")==Planner.weekday(day))windows.add(new Planner.Span(Planner.at(day,a.getInt("startMinute")),Planner.at(day,a.getInt("endMinute"))));for(Planner.Span w:Planner.merge(windows))if(t.getDouble("start")>=w.a&&Planner.end(t)<=w.b)fits=true;check(fits,"Outside available windows");}
  for(JSONObject c:Planner.list(s.getJSONArray("courses"))){int planned=0;for(JSONObject t:tasks)if(t.getString("courseID").equals(c.getString("id")))planned+=t.getInt("durationMinutes");for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(t)&&t.getDouble("start")<now&&Planner.end(t)>now&&t.getString("courseID").equals(c.getString("id")))planned+=t.getInt("durationMinutes");check(planned<=Planner.remaining(s,c),"Overallocated learning amount");}
 }
 static void dailyCourseRotationRegression()throws Exception{
  LocalDate day=LocalDate.of(2026,9,14);double now=Planner.at(day,480);
  for(boolean whole:new boolean[]{false,true}){
   JSONObject s=empty(),a=course("数学",240,day,day.plusDays(1),60),b=course("英语",240,day,day.plusDays(1),60);
   for(JSONObject c:new JSONObject[]{a,b}){
    if(whole){JSONArray lessons=new JSONArray();for(int i=0;i<4;i++)lessons.put(new JSONObject().put("id","lesson"+i).put("name","第"+i+"讲").put("durationMinutes",60));c.put("type","不定时录播课程").put("manualLessons",lessons).put("lessonOrder",new JSONArray().put("lesson3").put("lesson1").put("lesson2").put("lesson0"));}
    s.getJSONArray("courses").put(c);
   }
   for(int w=1;w<=7;w++)s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",w).put("startMinute",480).put("endMinute",765));
   check(Planner.replan(s,now).isEmpty(),"Rotation lost feasible capacity");
   for(int offset=0;offset<2;offset++){Set<String> owners=new HashSet<>();String previous="";int total=0;for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.day(t.getDouble("start")).equals(day.plusDays(offset))){String owner=t.getString("courseID");check(!owner.equals(previous),"Same-priority courses should rotate within full days");previous=owner;owners.add(owner);total+=t.getInt("durationMinutes");}check(owners.size()==2&&total==240,"A full day was monopolized by one course");}
   if(whole)for(JSONObject c:new JSONObject[]{a,b}){List<String> ids=new ArrayList<>();for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(t.getString("courseID").equals(c.getString("id")))ids.add(t.getString("lessonID"));check(ids.equals(Arrays.asList("lesson3","lesson1","lesson2","lesson0")),"Rotation reordered lessons");}
   invariant(s,now);
  }
 }
 static void mergedCourseRegression()throws Exception{
  LocalDate day=LocalDate.of(2026,9,28);JSONObject s=empty();
  JSONObject a=course("A",60,day,day.plusDays(2),60).put("type","不定时录播课程").put("initialCompletedMinutes",10);
  a.put("manualLessons",new JSONArray().put(new JSONObject().put("id","same").put("name","第10节").put("durationMinutes",60)));
  JSONObject b=course("B",60,day,day.plusDays(2),60);
  JSONObject merged=course("合并",120,day,day.plusDays(2),60).put("type","不定时录播课程").put("initialCompletedMinutes",10);
  String aid=a.getString("id")+"/same",bid=b.getString("id")+"/whole";
  merged.put("mergedSources",new JSONArray().put(a).put(b)).put("lessonOrder",new JSONArray().put(bid).put(aid));
  s.getJSONArray("courses").put(merged);
  JSONObject t=Planner.task(merged.getString("id"),Planner.at(day,480),30).put("lessonID",aid);s.getJSONArray("tasks").put(t);
  Planner.confirm(s,t.getString("id"),20,Planner.at(day,600));
  List<Planner.Work> work=Planner.lessonWork(s,merged);
  check(work.size()==2&&work.get(0).lessonID.equals(bid),"Merged custom order lost");
  check(work.get(0).minutes==60&&work.get(1).minutes==30,"Merged source progress lost");
  Planner.undoConfirmation(s,t.getString("id"),Planner.at(day,600));
  check(Planner.lessonWork(s,merged).get(1).minutes==50,"Merged undo lost source baseline");
 }
 static void historicalConfirmationRegression()throws Exception{
  LocalDate day=LocalDate.of(2026,9,14);
  for(double now:new double[]{Planner.at(day,720),Planner.at(day.plusDays(1),420)})for(int count:new int[]{1,2}){
   JSONObject s=empty(),c=course("补确认",240,day,day.plusDays(4),60);s.getJSONArray("courses").put(c);
   for(int w=1;w<=7;w++)s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",w).put("startMinute",480).put("endMinute",1080));
   List<JSONObject> old=new ArrayList<>();
   for(int i=0;i<count;i++){JSONObject t=new JSONObject().put("id",Planner.id()).put("courseID",c.getString("id")).put("start",Planner.at(day,480+i*60)).put("durationMinutes",60).put("status","planned");old.add(t);s.getJSONArray("tasks").put(t);}
   Planner.replan(s,now);
   int before=0;for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(t)&&Planner.planningStart(t)>=now)before+=t.getInt("durationMinutes");check(before==240,"Historical work was not redistributed before confirmation");
   boolean needsReplan=false;for(JSONObject t:old)needsReplan|=Planner.confirmationRequiresReplan(t,60,now);
   for(JSONObject t:old)Planner.confirm(s,t.getString("id"),60,now);
   if(needsReplan)Planner.replan(s,now);
   int planned=0,confirmed=0;for(JSONObject t:Planner.list(s.getJSONArray("tasks"))){if(Planner.pending(t)&&Planner.planningStart(t)>=now)planned+=t.getInt("durationMinutes");if(t.optString("status").equals("completed"))confirmed++;}
   check(Planner.remaining(s,c)==240-count*60,"Historical progress incorrect");check(planned==240-count*60,"Historical full confirmation left excess future work");check(confirmed==count,"Confirmed history lost");check(s.getJSONArray("completions").length()==count,"Completion count incorrect");invariant(s,now);
   for(JSONObject t:old)Planner.undoConfirmation(s,t.getString("id"),now);
   Planner.replan(s,now);
   int restored=0;for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(t)&&Planner.planningStart(t)>=now)restored+=t.getInt("durationMinutes");
   check(Planner.remaining(s,c)==240,"Undo did not restore remaining amount");check(restored==240,"Undo historical completion did not restore future work");check(s.getJSONArray("completions").length()==0,"Undo left completion records");invariant(s,now);

  }
  JSONObject task=new JSONObject().put("start",Planner.at(day,480)).put("durationMinutes",60);
  check(!Planner.confirmationRequiresReplan(task,60,Planner.at(day,420)),"Early full completion must preserve plan");
  check(!Planner.confirmationRequiresReplan(task,60,Planner.at(day,510)),"Active full completion must preserve plan");
  check(Planner.confirmationRequiresReplan(task,60,Planner.at(day,540)),"Ended full completion must replan");
  task.put("floatingWindowStart",Planner.at(day,480)).put("floatingWindowEnd",Planner.at(day,720));
  check(!Planner.confirmationRequiresReplan(task,60,Planner.at(day,600)),"Floating completion must use window end");
  check(Planner.confirmationRequiresReplan(task,60,Planner.at(day,720)),"Ended floating completion must replan");
  check(Planner.confirmationRequiresReplan(task,30,Planner.at(day,600)),"Partial completion must replan");
 }
 static void refreshedWebsiteProgressRegression()throws Exception{
  LocalDate day=LocalDate.of(2026,9,28);
  for(int percent:new int[]{0,50,100}){
   JSONObject s=empty(),c=course("刷新后同步",120,day,day,60).put("type","不定时录播课程");
   JSONArray lessons=new JSONArray();
   for(String id:new String[]{"first","second"})lessons.put(new JSONObject().put("id",id).put("name",id).put("published",true).put("requiresDuration",true).put("durationSeconds",3600).put("watchedPercent",id.equals("second")?percent:0));
   c.put("webCourse",new JSONObject().put("fetchedAt",Planner.at(day,480)).put("lessons",lessons));s.getJSONArray("courses").put(c);
   JSONObject task=Planner.task(c.getString("id"),Planner.at(day,360),60).put("lessonID","second");s.getJSONArray("tasks").put(task);
   Planner.confirm(s,task.getString("id"),60,Planner.at(day,420));
   List<Planner.Work> work=Planner.lessonWork(s,c);
   check(work.size()==1&&work.get(0).lessonID.equals("first")&&work.get(0).minutes==60,"Refreshed website progress moved local completion to wrong lesson at "+percent+"%");
   s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("weekday",Planner.weekday(day)).put("startMinute",540).put("endMinute",720));
   Planner.replan(s,Planner.at(day,480));
   for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(t))check(t.optString("lessonID").equals("first"),"Replan repeated a locally completed lesson");
  }
  JSONObject s=empty(),c=course("部分重叠进度",180,day,day,60).put("type","不定时录播课程");
  JSONArray lessons=new JSONArray();
  for(String id:new String[]{"first","second","third"})lessons.put(new JSONObject().put("id",id).put("name",id).put("published",true).put("requiresDuration",true).put("durationSeconds",3600).put("watchedPercent",id.equals("second")?50:0));
  c.put("webCourse",new JSONObject().put("fetchedAt",Planner.at(day,480)).put("lessons",lessons));s.getJSONArray("courses").put(c);
  String lastTask="";
  for(String id:new String[]{"second","third"}){JSONObject task=Planner.task(c.getString("id"),Planner.at(day,360),60).put("lessonID",id);s.getJSONArray("tasks").put(task);lastTask=task.getString("id");Planner.confirm(s,lastTask,30,Planner.at(day,420));}
  List<Planner.Work> work=Planner.lessonWork(s,c);
  check(work.size()==3&&work.get(0).minutes==60&&work.get(1).minutes==30&&work.get(2).minutes==30,"Website and local progress were counted twice for one lesson");
  Planner.undoConfirmation(s,lastTask,Planner.at(day,480));work=Planner.lessonWork(s,c);
  check(work.get(0).minutes==60&&work.get(1).minutes==30&&work.get(2).minutes==60,"Undo after refresh changed the wrong lesson");
 }
 static void lessonScheduling()throws Exception{
  LocalDate date=LocalDate.of(2026,9,14);JSONObject s=empty(),c=course("录播",120,date,date,60).put("type","不定时录播课程");
  c.put("manualLessons",new JSONArray().put(new JSONObject().put("id","one").put("name","第一节").put("durationMinutes",35)).put(new JSONObject().put("id","two").put("name","第二节").put("durationMinutes",85)));
  s.getJSONArray("courses").put(c);s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",2).put("startMinute",480).put("endMinute",780));
  Planner.replan(s,Planner.at(date,480));JSONArray tasks=s.getJSONArray("tasks");check(tasks.length()==2,"Manual lessons were not scheduled separately");
  check(tasks.getJSONObject(0).getInt("durationMinutes")==35&&tasks.getJSONObject(0).getString("lessonID").equals("one"),"First lesson was split");
  check(tasks.getJSONObject(1).getInt("durationMinutes")==85&&tasks.getJSONObject(1).getString("lessonName").equals("第二节"),"Second lesson was split");
  c.put("lessonOrder",new JSONArray().put("two").put("one"));Planner.replan(s,Planner.at(date,480));JSONArray reordered=s.getJSONArray("tasks");
  check(reordered.getJSONObject(0).getString("lessonID").equals("two")&&reordered.getJSONObject(1).getString("lessonID").equals("one"),"Saved lesson order was ignored");
  JSONObject web=empty(),webCourse=course("网页录播",120,date,date,60).put("type","不定时录播课程");
  JSONArray lessons=new JSONArray().put(new JSONObject().put("id","web1").put("name","回放一").put("published",true).put("requiresDuration",true).put("durationSeconds",5400).put("watchedPercent",0)).put(new JSONObject().put("id","web2").put("name","回放二").put("published",true).put("requiresDuration",true).put("durationSeconds",1800).put("watchedPercent",50));
  webCourse.put("initialCompletedMinutes",15).put("webCourse",new JSONObject().put("fetchedAt",Planner.at(date,420)).put("lessons",lessons));web.getJSONArray("courses").put(webCourse);
  web.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",2).put("startMinute",480).put("endMinute",780));
  Planner.replan(web,Planner.at(date,480));JSONArray webTasks=web.getJSONArray("tasks");check(webTasks.length()==2,"Website lessons were not scheduled separately");
  check(webTasks.getJSONObject(0).getInt("durationMinutes")==90&&webTasks.getJSONObject(1).getInt("durationMinutes")==15,"Website remaining time was not respected");
 }
 static void liveOrderRegression()throws Exception{
  LocalDate day=LocalDate.of(2026,9,14);double now=Planner.at(day,510);
  for(boolean floating:new boolean[]{false,true}){
   JSONObject s=empty(),c=course("实时调整",180,day,day,60).put("type","不定时录播课程");
   JSONArray lessons=new JSONArray();for(String id:new String[]{"a","b","c"})lessons.put(new JSONObject().put("id",id).put("name",id).put("durationMinutes",60));c.put("manualLessons",lessons);s.getJSONArray("courses").put(c);
   s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("weekday",2).put("startMinute",480).put("endMinute",1080));
   JSONObject history=Planner.task(c.getString("id"),Planner.at(day,360),60).put("lessonID","c").put("status","planned");s.getJSONArray("tasks").put(history);Planner.confirm(s,history.getString("id"),60,Planner.at(day,420));String confirmed=history.toString();
   Planner.replan(s,Planner.at(day,480));if(floating)for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(t))t.put("floatingWindowStart",Planner.at(day,480)).put("floatingWindowEnd",Planner.at(day,1080));
   c.put("lessonOrder",new JSONArray().put("b").put("a").put("c"));Planner.replan(s,now);
   List<JSONObject> future=new ArrayList<>();for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(t))future.add(t);
   check(future.size()==2&&future.get(0).getString("lessonID").equals("b")&&future.get(1).getString("lessonID").equals("a"),"Today lesson order remained locked");check(future.get(0).getDouble("start")==now,"Active plan not moved to now");check(history.toString().equals(confirmed),"Confirmed history changed");invariant(s,now);
   String first=s.getJSONArray("tasks").toString();Planner.replan(s,now);check(first.equals(s.getJSONArray("tasks").toString()),"Repeated replans duplicate tasks");
   c.put("autoScheduleEnabled",false);Planner.replan(s,now+60);check(s.getJSONArray("tasks").length()==1&&s.getJSONArray("tasks").getJSONObject(0).toString().equals(confirmed),"Disabling course left today's active task");
  }
 }
 static void confirmedWindowRegression()throws Exception{
  LocalDate day=LocalDate.of(2026,9,14);JSONObject s=empty(),c=course("释放浮动窗口",120,day,day,60);s.getJSONArray("courses").put(c);
  s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("weekday",2).put("startMinute",480).put("endMinute",1080));
  JSONObject t=Planner.task(c.getString("id"),Planner.at(day,480),60).put("floatingWindowStart",Planner.at(day,480)).put("floatingWindowEnd",Planner.at(day,1080));s.getJSONArray("tasks").put(t);
  Planner.confirm(s,t.getString("id"),30,Planner.at(day,510));Planner.replan(s,Planner.at(day,510));
  List<JSONObject> pending=new ArrayList<>();for(JSONObject task:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(task))pending.add(task);
  check(pending.size()==2&&pending.get(0).getDouble("start")==Planner.at(day,525),"Confirmed floating task kept unused window locked");invariant(s,Planner.at(day,510));
 }
 static void breakRegression()throws Exception{
  LocalDate day=LocalDate.of(2026,9,14);double now=Planner.at(day,480);
  for(int available:new int[]{120,134,135}){
   JSONObject s=empty();s.getJSONArray("courses").put(course("休息",120,day,day,60));
   s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("weekday",2).put("startMinute",480).put("endMinute",480+available));
   List<String> warnings=Planner.replan(s,now);check(s.getJSONArray("tasks").length()==(available<135?1:2),"Break capacity boundary");check(warnings.isEmpty()==(available==135),"Missing break capacity warning");invariant(s,now);
  }
  for(int minute:new int[]{510,540,545}){
   JSONObject s=empty(),c=course("进行中",120,day,day,60);s.getJSONArray("courses").put(c);
   s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("weekday",2).put("startMinute",480).put("endMinute",780));
   s.getJSONArray("tasks").put(Planner.task(c.getString("id"),now,60).put("status","planned"));
   Planner.replan(s,Planner.at(day,minute));List<JSONObject> future=new ArrayList<>();for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(t.getDouble("start")>=Planner.at(day,minute))future.add(t);
   check(future.get(0).getDouble("start")==Planner.at(day,minute<540?minute:555),"Replan should move active tasks and retain ended lesson breaks");invariant(s,Planner.at(day,minute));
  }
  JSONObject s=empty();s.getJSONArray("courses").put(course("跨日",120,day,day.plusDays(1),60));
  s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("weekday",2).put("startMinute",1380).put("endMinute",1440)).put(new JSONObject().put("weekday",3).put("startMinute",0).put("endMinute",75));
  Planner.replan(s,now);check(s.getJSONArray("tasks").length()==2,"Midnight capacity lost");check(s.getJSONArray("tasks").getJSONObject(1).getDouble("start")==Planner.at(day.plusDays(1),15),"Midnight break lost");invariant(s,now);
 }
 static void actualStudyStartRegression()throws Exception{
  LocalDate today=LocalDate.of(2026,10,3);JSONObject s=empty();
  s.getJSONArray("courses").put(course("开课时间",240,today,today.plusDays(1),60));
  for(int weekday=1;weekday<=7;weekday++)s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",weekday).put("startMinute",480).put("endMinute",720));
  Planner.replan(s,Planner.at(today,480));
  Planner.recordActualStudyStart(s,660,Planner.at(today,840));
  check(Planner.replan(s,Planner.at(today,840)).isEmpty(),"Actual start should spill into tomorrow");
  List<JSONObject> tasks=Planner.list(s.getJSONArray("tasks"));
  check(tasks.size()==4&&tasks.get(0).getDouble("start")==Planner.at(today,660),"Past input should replace today's ended draft");
  check(tasks.get(1).getDouble("start")==Planner.at(today.plusDays(1),480),"Tomorrow should keep normal availability");
  String snapshot=s.getJSONArray("tasks").toString();
  Planner.replan(s,Planner.at(today,960));check(snapshot.equals(s.getJSONArray("tasks").toString()),"Reopening must preserve anchored timetable");
  JSONObject first=s.getJSONArray("tasks").getJSONObject(0);Planner.confirm(s,first.getString("id"),60,Planner.at(today,720));
  Planner.replan(s,Planner.at(today,840));check(Planner.remaining(s,s.getJSONArray("courses").getJSONObject(0))==180,"Anchor lost confirmed progress");
  check(Planner.list(s.getJSONArray("tasks")).stream().anyMatch(t->t.optString("id").equals(first.optString("id"))&&!Planner.pending(t)),"Confirmed task disappeared");
  check(Planner.actualStudyStart(s,Planner.at(today.plusDays(1),420))==null,"Override must expire tomorrow");
  Planner.replan(s,Planner.at(today.plusDays(1),420));
  check(s.getJSONArray("tasks").getJSONObject(0).getString("id").equals(first.getString("id")),"Yesterday's confirmed history disappeared");
  boolean rejected=false;try{Planner.recordActualStudyStart(s,1440,Planner.at(today,840));}catch(IllegalArgumentException e){rejected=true;}check(rejected,"24:00 must not be accepted as today's start");
 }
 public static void main(String[] args)throws Exception{
  actualStudyStartRegression();
  breakRegression();liveOrderRegression();confirmedWindowRegression();
  refreshedWebsiteProgressRegression();
  lessonScheduling();
  dailyCourseRotationRegression();mergedCourseRegression();historicalConfirmationRegression();
  JSONObject initial=new JSONObject(new String(Files.readAllBytes(Paths.get("Android/assets/initial-state.json")),"UTF-8"));Planner.validate(initial);check(initial.getJSONArray("courses").length()==0,"Initial package includes courses");check(initial.getJSONArray("fixedEvents").length()==0,"Initial package includes fixed events");check(initial.getJSONArray("tasks").length()==0,"Initial package includes tasks");check(initial.getJSONArray("completions").length()==0,"Initial package includes completion records");for(JSONObject a:Planner.list(initial.getJSONObject("settings").getJSONArray("availability")))check(Planner.canonicalID(a.getString("id")),"Initial availability ID is not cross-platform");JSONObject legacy=clone(initial);legacy.getJSONObject("settings").getJSONArray("availability").getJSONObject(0).put("id","default-availability-1");Planner.validate(legacy);check(legacy.getJSONObject("settings").getJSONArray("availability").getJSONObject(0).getString("id").equals(Planner.stableID("availability|legacy|default-availability-1")),"Legacy availability ID was not migrated");
  LocalDate today=LocalDate.of(2026,9,18);double now=Planner.at(today,18*60+10);JSONObject s=empty();for(int w=1;w<=7;w++)s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",w).put("startMinute",480).put("endMinute",1320));for(int c=0;c<4;c++)s.getJSONArray("courses").put(course("测试课程"+c,600,today.minusDays(1),today.plusDays(7+c),60));Planner.replan(s,now);Map<String,String> historical=new HashMap<>();for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(t.getDouble("start")<now||!Planner.pending(t))historical.put(t.getString("id"),t.toString());long start=System.nanoTime();Planner.replan(s,now);System.out.println("Scenario replan ms: "+(System.nanoTime()-start)/1e6);invariant(s,now);for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(historical.containsKey(t.getString("id")))check(t.toString().equals(historical.get(t.getString("id"))),"History modified");
  Files.write(Paths.get("Android/build/java-replanned.json"),s.toString().getBytes("UTF-8"));
  JSONObject chosen=null;for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(t)&&t.getDouble("start")>now){chosen=t;break;}String tid=chosen.getString("id"),cid=chosen.getString("courseID");int before=Planner.completed(s,Planner.course(s,cid)),amount=chosen.getInt("durationMinutes")/2;Planner.confirm(s,tid,amount,now);check(Planner.completed(s,Planner.course(s,cid))==before+amount,"Partial credit");boolean refused=false;try{Planner.confirm(s,tid,amount,now);}catch(Exception ex){refused=true;}check(refused,"Duplicate confirmation allowed");Planner.undoConfirmation(s,tid,now);check(Planner.completed(s,Planner.course(s,cid))==before,"Undo did not restore progress");check(Planner.pending(chosen),"Undo did not restore task");boolean recordLeft=false;for(JSONObject record:Planner.list(s.getJSONArray("completions")))if(record.optString("taskID").equals(tid))recordLeft=true;check(!recordLeft,"Undo left completion record");refused=false;try{Planner.undoConfirmation(s,tid,now);}catch(Exception ex){refused=true;}check(refused,"Duplicate undo allowed");Planner.replan(s,now);invariant(s,now);
  Random random=new Random(431);for(int run=0;run<50;run++){JSONObject f=empty();for(int w=1;w<=7;w++)f.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",w).put("startMinute",480).put("endMinute",720)).put(new JSONObject().put("id",Planner.id()).put("weekday",w).put("startMinute",780).put("endMinute",1080));for(int c=0;c<4;c++)f.getJSONArray("courses").put(course("C"+c,random.nextInt(4000)+1,today.plusDays(random.nextInt(3)),today.plusDays(5+random.nextInt(10)),new int[]{30,60,90}[random.nextInt(3)]));f.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.id()).put("title","固定").put("startMinute",600).put("endMinute",660).put("startDate",Planner.at(today,0)).put("endDate",Planner.at(today.plusDays(20),0)).put("weekdays",new JSONArray("[2,4,6]")));Planner.replan(f,Planner.at(today,480));invariant(f,Planner.at(today,480));}
  JSONObject noTime=empty();noTime.getJSONArray("courses").put(course("无可用日",100,today,today.plusDays(2),60));check(!Planner.replan(noTime,now).isEmpty(),"No capacity warning");check(noTime.getJSONArray("tasks").length()==0,"Tasks without capacity");
  JSONObject one=empty();one.getJSONArray("courses").put(course("最后余量",61,today,today,60));one.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",Planner.weekday(today)).put("startMinute",480).put("endMinute",720));Planner.replan(one,Planner.at(today,480));check(one.getJSONArray("tasks").length()==2,"Tail block missing");JSONObject first=one.getJSONArray("tasks").getJSONObject(0);Planner.confirm(one,first.getString("id"),0,Planner.at(today,480));check(Planner.remaining(one,one.getJSONArray("courses").getJSONObject(0))==61,"Missed added debt");
  JSONObject events=empty();JSONObject e=new JSONObject().put("id",Planner.id()).put("title","午休").put("startMinute",720).put("endMinute",780).put("startDate",Planner.at(today.minusDays(10),0)).put("endDate",Planner.at(today.plusDays(10),0)).put("weekdays",new JSONArray("[1,2,3,4,5,6,7]"));events.getJSONArray("fixedEvents").put(e);JSONObject edit=clone(e).put("endMinute",800);Planner.saveEvent(events,edit,now);check(events.getJSONArray("fixedEvents").length()==2,"Recurring history not split");check(Planner.occurs(e,today),"Today's started rule lost");check(!Planner.occurs(edit,today),"Edited started rule");check(Planner.occurs(edit,today.plusDays(1)),"Future rule absent");boolean conflict=false;try{Planner.saveEvent(events,clone(edit).put("id",Planner.id()),now);}catch(Exception ex){conflict=true;}check(conflict,"Fixed conflict accepted");Planner.removeEvent(events,edit.getString("id"),now);check(events.getJSONArray("fixedEvents").length()==1,"Remove future");
  JSONObject archived=clone(s);for(JSONObject c:Planner.list(archived.getJSONArray("courses")))c.put("isArchived",true);Planner.replan(archived,now);for(JSONObject t:Planner.list(archived.getJSONArray("tasks")))check(t.getDouble("start")<now||!Planner.pending(t),"Archived future task");
  System.out.println("PASS "+checks+" checks: snapshot, invariants in 50 scenarios, partial/missed/duplicate confirmations, history, recurrence conflicts, tail blocks, archive, no capacity.");
 }
}
