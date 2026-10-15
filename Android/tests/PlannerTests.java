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
 static JSONObject window(int weekday,int start,int end)throws Exception{return new JSONObject().put("id",Planner.id()).put("weekday",weekday).put("startMinute",start).put("endMinute",end);}
 static JSONObject diversityState(int days,int[] minutes,double weight)throws Exception{
  JSONObject s=empty();for(int w=1;w<=7;w++)s.getJSONObject("settings").getJSONArray("availability").put(window(w,480,1080));
  LocalDate start=LocalDate.of(2026,9,14);
  for(int i=0;i<minutes.length;i++)s.getJSONArray("courses").put(course("课程"+i,minutes[i],start,start.plusDays(days-1),60).put("priority",3-i));
  if(minutes.length>0)s.getJSONArray("courses").getJSONObject(0).put("dailyStudyWeight",weight);
  return s;
 }
 static int totalMinutes(JSONObject s)throws Exception{int total=0;for(JSONObject t:Planner.list(s.getJSONArray("tasks")))total+=t.getInt("durationMinutes");return total;}
 static Set<String> owners(JSONObject s,LocalDate date)throws Exception{Set<String> owners=new HashSet<>();for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.day(t.getDouble("start")).equals(date))owners.add(t.getString("courseID"));return owners;}
 static List<JSONObject> dayTasks(JSONObject s,LocalDate date)throws Exception{List<JSONObject> rows=new ArrayList<>();for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.day(t.getDouble("start")).equals(date))rows.add(t);return rows;}
 static int courseMinutes(JSONObject s,String courseID)throws Exception{int total=0;for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(t.getString("courseID").equals(courseID))total+=t.getInt("durationMinutes");return total;}
 static int unscheduledMinutes(JSONObject s)throws Exception{JSONArray risks=s.getJSONArray("androidRisks");return risks.length()==0?0:risks.getJSONObject(0).getInt("unscheduledMinutes");}
 static List<JSONObject> sortedTasks(JSONObject s)throws Exception{List<JSONObject> tasks=Planner.list(s.getJSONArray("tasks"));tasks.sort(Comparator.comparingDouble(t->t.optDouble("start")));return tasks;}
 static boolean warned(JSONObject s,String text)throws Exception{JSONArray warnings=s.getJSONArray("androidWarnings");for(int i=0;i<warnings.length();i++)if(warnings.getString(i).contains(text))return true;return false;}
 static void diversityEveryDayRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14);double now=Planner.at(start,480);
  for(double weight:new double[]{1,1.5,2,2.99})for(boolean whole:new boolean[]{false,true}){
   JSONObject s=diversityState(3,new int[]{600,180,180},weight);
   if(whole)for(JSONObject c:Planner.list(s.getJSONArray("courses"))){
    int count=c.getInt("totalMinutes")/60;JSONArray lessons=new JSONArray(),order=new JSONArray();
    for(int i=0;i<count;i++)lessons.put(new JSONObject().put("id","lesson"+i).put("name","第"+i+"节").put("durationMinutes",60));
    for(int i=count-1;i>=0;i--)order.put("lesson"+i);
    c.put("type","不定时录播课程").put("manualLessons",lessons).put("lessonOrder",order);
   }
   List<String> warnings=Planner.replan(s,now);
   check(s.getJSONArray("androidRisks").length()==0,"Diversity lost feasible capacity at "+weight);
   check(warnings.isEmpty(),"Diversity reported a problem at "+weight);
   check(totalMinutes(s)==960,"Diversity changed the booked amount at "+weight);
   for(int offset=0;offset<3;offset++)check(owners(s,start.plusDays(offset)).size()==3,"Daily diversity lost a course at "+weight);
   if(whole)for(JSONObject c:Planner.list(s.getJSONArray("courses"))){
    List<String> ids=new ArrayList<>();for(JSONObject t:sortedTasks(s))if(t.getString("courseID").equals(c.getString("id")))ids.add(t.optString("lessonID"));
    List<String> expected=new ArrayList<>();JSONArray order=c.getJSONArray("lessonOrder");for(int i=0;i<order.length();i++)expected.add(order.getString(i));
    check(ids.equals(expected),"Diversity reordered lessons at "+weight);
   }
   String snapshot=s.getJSONArray("tasks").toString();Planner.replan(s,now);check(snapshot.equals(s.getJSONArray("tasks").toString()),"Diversity is not deterministic at "+weight);
   invariant(s,now);
  }
 }
 static void fourthSubjectReservedRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14);double now=Planner.at(start,480);
  JSONObject s=diversityState(4,new int[]{240,240,120,120},1);
  s.getJSONArray("courses").getJSONObject(3).put("priority",0);
  List<String> warnings=Planner.replan(s,now);
  check(s.getJSONArray("androidRisks").length()==0,"Fourth subject lost feasible capacity");
  check(warnings.isEmpty(),"Fourth subject reported a problem");
  for(int offset=0;offset<4;offset++)check(owners(s,start.plusDays(offset)).size()==3,"A later day lost its third subject");
  check(totalMinutes(s)==720,"Reserving the fourth subject changed the booked amount");
  invariant(s,now);
 }
 static void diversityLongBlockRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14),next=LocalDate.of(2026,9,15);double now=Planner.at(start,480);
  JSONObject s=diversityState(1,new int[]{30,120,30},1);JSONArray courses=s.getJSONArray("courses");
  courses.getJSONObject(0).put("minimumBlockMinutes",30).put("deadline",Planner.at(start,0));
  courses.getJSONObject(1).put("minimumBlockMinutes",120).put("deadline",Planner.at(next,0));
  courses.getJSONObject(2).put("minimumBlockMinutes",30).put("deadline",Planner.at(next,0));
  s.getJSONObject("settings").put("availability",new JSONArray().put(window(2,480,600)).put(window(2,660,690)).put(window(2,750,780)));
  List<String> warnings=Planner.replan(s,now);
  check(owners(s,start).size()==3,"Short lessons consumed the long window");
  check(sortedTasks(s).get(0).getString("courseID").equals(courses.getJSONObject(1).getString("id")),"The long lesson lost its own window");
  check(s.getJSONArray("androidRisks").length()==0,"Long block search lost feasible capacity");
  check(warnings.isEmpty(),"Long block search reported a problem");
  invariant(s,now);
 }
 static void diversityPrecedenceRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14),next=LocalDate.of(2026,9,15);double now=Planner.at(start,480);
  JSONObject s=diversityState(1,new int[]{600,60,60},1);JSONArray courses=s.getJSONArray("courses");
  courses.getJSONObject(1).put("deadline",Planner.at(next,0));courses.getJSONObject(2).put("deadline",Planner.at(next,0));
  Planner.replan(s,now);
  check(owners(s,start).size()==3,"Urgency displaced the daily diversity");
  check(s.getJSONArray("androidRisks").length()>0&&s.getJSONArray("androidRisks").getJSONObject(0).getInt("unscheduledMinutes")>0,"Diversity must not invent capacity");
  invariant(s,now);
 }
 static void tripleDiversityExceptionRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14);double now=Planner.at(start,480);
  for(double weight:new double[]{2.99,3}){
   JSONObject s=diversityState(2,new int[]{480,60,60},weight);s.getJSONArray("courses").getJSONObject(0).put("minimumBlockMinutes",480);
   JSONArray availability=new JSONArray();for(int w=1;w<=7;w++)availability.put(window(w,480,960));
   s.getJSONObject("settings").put("availability",availability);
   List<String> warnings=Planner.replan(s,now);
   if(weight==3){
    List<JSONObject> firstDay=new ArrayList<>();for(JSONObject t:sortedTasks(s))if(Planner.day(t.getDouble("start")).equals(start))firstDay.add(t);
    check(firstDay.size()==1&&firstDay.get(0).getString("courseID").equals(s.getJSONArray("courses").getJSONObject(0).getString("id")),"A triple boost must take its own day");
    check(owners(s,start.plusDays(1)).size()==2,"Finished triple work must not exempt tomorrow's ordinary courses");
   }else{
    check(owners(s,start).size()==2,"Sub-triple boosts must still share the day");
    check(warnings.isEmpty(),"Sub-triple boosts must not report a missing third course");
   }
   invariant(s,now);
  }
  JSONObject s=diversityState(3,new int[]{600,180,180},1);
  s.getJSONArray("courses").put(course("未来三倍",60,LocalDate.of(2026,9,17),LocalDate.of(2026,9,17),60).put("dailyStudyWeight",3));
  Planner.replan(s,now);
  for(int offset=0;offset<3;offset++)check(owners(s,start.plusDays(offset)).size()==3,"A future triple course must not exempt the current days");
  invariant(s,now);
 }
 static void limitedDiversityIsNormalRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14);double now=Planner.at(start,480);
  for(int count:new int[]{1,2,3}){
   int[] minutes=new int[count];Arrays.fill(minutes,60);
   JSONObject s=diversityState(1,minutes,1);
   s.getJSONObject("settings").put("availability",new JSONArray().put(window(2,480,615)));
   Planner.replan(s,now);
   check(s.getJSONArray("tasks").length()==Math.min(2,count),"Impossible diversity invented work");
   check(!warned(s,"未满足"),"Limited diversity must not report missing daily diversity");
   check(unscheduledMinutes(s)==(count==3?60:0),"Limited diversity changed unscheduled minutes");
   invariant(s,now);
  }
 }
 static void fixedEventsCanLeaveOnlyOneCourseRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14);double now=Planner.at(start,480);
  JSONObject s=diversityState(3,new int[]{180,180,180},1);
  JSONArray availability=new JSONArray();for(int w=1;w<=7;w++)availability.put(window(w,480,960));
  s.getJSONObject("settings").put("availability",availability);
  s.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.id()).put("title","上午固定课").put("startMinute",480).put("endMinute",600).put("startDate",Planner.at(start,0)).put("endDate",Planner.at(start,0)).put("weekdays",new JSONArray()));
  s.getJSONArray("fixedEvents").put(new JSONObject().put("id",Planner.id()).put("title","下午固定课").put("startMinute",660).put("endMinute",960).put("startDate",Planner.at(start,0)).put("endDate",Planner.at(start,0)).put("weekdays",new JSONArray()));
  List<String> warnings=Planner.replan(s,now);
  check(dayTasks(s,start).size()==1,"Fixed events must leave exactly one course on the first day");
  check(warnings.isEmpty(),"One-course days from fixed events must not warn");
  check(s.getJSONArray("androidRisks").length()==0,"Fixed events lost feasible capacity");
  check(totalMinutes(s)==540,"Fixed events changed the booked amount");
  for(int offset=1;offset<=2;offset++)check(owners(s,start.plusDays(offset)).size()==3,"A later day lost its third course");
  invariant(s,now);
 }
 static void doNotReserveThreeSubjectsForDaysThatOnlyFitOneRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14);double now=Planner.at(start,480);
  JSONObject s=diversityState(3,new int[]{120,120,120},1);
  s.getJSONObject("settings").put("availability",new JSONArray().put(window(2,480,1080)).put(window(3,480,540)).put(window(4,480,540)));
  List<String> warnings=Planner.replan(s,now);
  check(s.getJSONArray("androidRisks").length()==0,"Narrow future windows lost feasible capacity");
  check(warnings.isEmpty(),"Narrow future windows must not warn");
  check(totalMinutes(s)==360,"Narrow future windows changed the booked amount");
  invariant(s,now);
 }
 static void futureDiversityDoesNotStrandTodaysDeadlineRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14);double now=Planner.at(start,480);
  JSONObject s=diversityState(4,new int[]{120,120,120,120},1);
  String first=s.getJSONArray("courses").getJSONObject(0).getString("id");
  s.getJSONArray("courses").getJSONObject(0).put("deadline",Planner.at(start,0));
  List<String> warnings=Planner.replan(s,now);
  check(courseMinutes(s,first)==120,"Todays deadline work was left unscheduled for future diversity");
  check(s.getJSONArray("androidRisks").length()==0,"Todays deadline work lost feasible capacity");
  check(warnings.isEmpty(),"Todays deadline work must not warn");
  invariant(s,now);
 }
 static void twoWholeLessonCoursesMixDespiteDifferentPrioritiesRegression()throws Exception{
  LocalDate start=LocalDate.of(2026,9,14);double now=Planner.at(start,480);
  JSONObject s=diversityState(2,new int[]{240,240},1);
  JSONArray availability=new JSONArray();for(int w=1;w<=7;w++)availability.put(window(w,480,765));
  s.getJSONObject("settings").put("availability",availability);
  for(JSONObject c:Planner.list(s.getJSONArray("courses"))){
   JSONArray lessons=new JSONArray();for(int i=0;i<4;i++)lessons.put(new JSONObject().put("id",""+i).put("name","课"+i).put("durationMinutes",60));
   c.put("type","不定时录播课程").put("manualLessons",lessons);
  }
  List<String> warnings=Planner.replan(s,now);
  for(int offset=0;offset<2;offset++)check(owners(s,start.plusDays(offset)).size()==2,"Two whole-lesson courses must mix despite different priorities");
  check(warnings.isEmpty(),"Two whole-lesson courses must not warn");
  check(s.getJSONArray("androidRisks").length()==0,"Two whole-lesson courses lost feasible capacity");
  check(totalMinutes(s)==480,"Two whole-lesson courses changed the booked amount");
  invariant(s,now);
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
   Planner.replan(s,now);check(s.getJSONArray("androidRisks").length()==0,"Rotation lost feasible capacity");
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
 // Seed records from before the supplied snapshot directly. Calling confirm on an
 // already-refreshed course correctly caps NEW credit at its current remaining work.
 static void historicalCompletion(JSONObject state,JSONObject task,int minutes,double recordedAt)throws Exception{
  task.put("completedMinutes",minutes).put("confirmedAt",recordedAt).put("status",minutes==task.getInt("durationMinutes")?"completed":"partial");
  state.getJSONArray("completions").put(new JSONObject().put("id",Planner.stableID("completion|"+task.getString("id"))).put("courseID",task.getString("courseID")).put("taskID",task.getString("id")).put("minutes",minutes).put("recordedAt",recordedAt));
 }
 static void refreshedWebsiteProgressRegression()throws Exception{
  LocalDate day=LocalDate.of(2026,9,28);
  for(int percent:new int[]{0,50,100}){
   JSONObject s=empty(),c=course("刷新后同步",120,day,day,60).put("type","不定时录播课程");
   JSONArray lessons=new JSONArray();
   for(String id:new String[]{"first","second"})lessons.put(new JSONObject().put("id",id).put("name",id).put("published",true).put("requiresDuration",true).put("durationSeconds",3600).put("watchedPercent",id.equals("second")?percent:0));
   c.put("webCourse",new JSONObject().put("fetchedAt",Planner.at(day,480)).put("lessons",lessons));s.getJSONArray("courses").put(c);
   JSONObject task=Planner.task(c.getString("id"),Planner.at(day,360),60).put("lessonID","second");s.getJSONArray("tasks").put(task);
   historicalCompletion(s,task,60,Planner.at(day,420));
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
  for(String id:new String[]{"second","third"}){JSONObject task=Planner.task(c.getString("id"),Planner.at(day,360),60).put("lessonID",id);s.getJSONArray("tasks").put(task);lastTask=task.getString("id");historicalCompletion(s,task,30,Planner.at(day,420));}
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
   Planner.replan(s,now);check(s.getJSONArray("tasks").length()==(available<135?1:2),"Break capacity boundary");check((s.getJSONArray("androidRisks").length()==0)==(available==135),"Missing break capacity warning");invariant(s,now);
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
  Planner.replan(s,Planner.at(today,840));check(s.getJSONArray("androidRisks").length()==0,"Actual start should spill into tomorrow");
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
  diversityEveryDayRegression();fourthSubjectReservedRegression();diversityLongBlockRegression();diversityPrecedenceRegression();tripleDiversityExceptionRegression();limitedDiversityIsNormalRegression();
  fixedEventsCanLeaveOnlyOneCourseRegression();doNotReserveThreeSubjectsForDaysThatOnlyFitOneRegression();futureDiversityDoesNotStrandTodaysDeadlineRegression();twoWholeLessonCoursesMixDespiteDifferentPrioritiesRegression();
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
