package local.studyplanner;
import org.json.*;
import java.time.*;
import java.util.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
/** Deterministic synthetic plans: replay a failing case with fixture(index). */
public final class SyncScheduleStressTests {
 static final long SEED=0x202611031607L;
 static volatile String phase="initialization";
 static String id(Random r){return new UUID(r.nextLong(),r.nextLong()).toString().toUpperCase(Locale.ROOT);}
 static JSONObject window(Random r,LocalDate day,int a,int b)throws Exception{return PlannerTests.window(Planner.weekday(day),a,b).put("id",id(r));}
 static JSONObject event(Random r,LocalDate day,int a,int b,Integer duration)throws Exception {
  JSONObject e=new JSONObject().put("id",id(r)).put("title","Synthetic commitment").put("startDate",Planner.at(day,0)).put("endDate",Planner.at(day,0)).put("weekdays",new JSONArray()).put("excludedDates",new JSONArray()).put("startMinute",a).put("endMinute",b).put("color","orange").put("notes","");
  if(duration!=null)e.put("floatingDurationMinutes",duration);return e;
 }
 static JSONObject fixture(int index)throws Exception{
  Random r=new Random(SEED+index*104729L);
  LocalDate[] dates={LocalDate.of(2026,11,3),LocalDate.of(2028,2,28),LocalDate.of(2026,12,31),LocalDate.of(2026,3,8)};
  LocalDate day=dates[index%dates.length];int days=1+r.nextInt(4);
  int minute=new int[]{0,420,480,539,720,1380}[index%6];double now=Planner.at(day,minute)+(index%3==0?17:0);
  JSONObject state=PlannerTests.empty();state.put("stressNow",now).put("stressIndex",index);
  if(index%11==0)state.getJSONObject("settings").put("actualStudyStart",now);
  JSONArray windows=state.getJSONObject("settings").getJSONArray("availability");
  for(int offset=0;offset<days;offset++){
   LocalDate date=day.plusDays(offset);int kind=index%8;
   if(kind==1)windows.put(window(r,date,0,1440));
   else if(kind==2)windows.put(window(r,date,480,720)).put(window(r,date,780,1080));
   else if(kind==3)windows.put(window(r,date,480,600)).put(window(r,date,600,720));
   else if(kind==4)windows.put(window(r,date,480,600)).put(window(r,date,601,840));
   else if(kind!=0)for(int w=0;w<1+r.nextInt(3);w++){int a=r.nextInt(80)*15,b=Math.min(1440,a+(2+r.nextInt(15))*15);windows.put(window(r,date,a,b));}
   int events=r.nextInt(5);for(int e=0;e<events;e++){int a=r.nextInt(84)*15,b=Math.min(1440,a+(1+r.nextInt(12))*15);Integer duration=r.nextBoolean()?(1+r.nextInt((b-a)/15))*15:null;JSONObject value=event(r,date,a,b,duration);if(r.nextInt(8)==0)value.getJSONArray("excludedDates").put(Planner.at(date,0));state.getJSONArray("fixedEvents").put(value);}
  }
  if(index%10==0){state.getJSONArray("fixedEvents").put(event(r,day,480,540,null)).put(event(r,day,480,540,60));if(index%8==0)windows.put(window(r,day,600,720));}
  for(int c=0;c<1+r.nextInt(4);c++){
   int startOffset=r.nextInt(days),endOffset=startOffset+r.nextInt(days-startOffset),total=15*(1+r.nextInt(index%13==0?100:20));
   JSONObject course=PlannerTests.course("Synthetic course "+c,total,day.plusDays(startOffset),day.plusDays(endOffset),new int[]{15,30,60,90,180}[r.nextInt(5)]).put("id",id(r)).put("type","录播课程").put("color","blue").put("notes","").put("priority",1+r.nextInt(3));
   if(r.nextInt(7)==0)course.put("autoScheduleEnabled",false);
   if(r.nextBoolean())course.put("dailyStudyWeight",new double[]{1,1.5,2}[r.nextInt(3)]);
   if(r.nextInt(4)==0){JSONArray lessons=new JSONArray();int n=2+r.nextInt(5),sum=0;for(int l=0;l<n;l++){int duration=15*(1+r.nextInt(8));sum+=duration;lessons.put(new JSONObject().put("id","lesson-"+l).put("name","Lesson "+l).put("durationMinutes",duration));}course.put("type","不定时录播课程").put("manualLessons",lessons).put("totalMinutes",sum);total=sum;}
   if(r.nextInt(4)==0)course.put("initialCompletedMinutes",r.nextInt(total+1));
   state.getJSONArray("courses").put(course);
  }
  if(index%3==0){JSONObject course=state.getJSONArray("courses").getJSONObject(0);int duration=15*(1+r.nextInt(4));JSONObject task=Planner.task(course.getString("id"),now-7200,duration).put("id",id(r));if(course.has("manualLessons"))task.put("lessonID","lesson-0");
   if(index%5==0)task.put("floatingWindowStart",now-7500).put("floatingWindowEnd",now-1200);
   state.getJSONArray("tasks").put(task);if(index%2==0)Planner.confirm(state,task.getString("id"),r.nextInt(duration+1),now-1800);
  }
  return state;
 }
 static Path failures;
 static void save(String name,JSONObject value)throws Exception{
  if(failures==null)failures=Files.createTempDirectory("planner-schedule-stress-");
  Path file=failures.resolve(name+".json");Files.write(file,value.toString(2).getBytes(StandardCharsets.UTF_8));System.out.println("Fixture: "+file);
 }
 static void largePlans()throws Exception{
  LocalDate day=LocalDate.of(2026,11,3);double now=Planner.at(day,420);
  for(int count:new int[]{32,128}){
   phase="large plan with "+count+" courses";
   JSONObject state=PlannerTests.empty();
   for(int weekday=1;weekday<=7;weekday++)state.getJSONObject("settings").getJSONArray("availability")
    .put(PlannerTests.window(weekday,480,1200).put("id",Planner.stableID("stress-window-"+weekday)));
   for(int course=0;course<count;course++)state.getJSONArray("courses").put(PlannerTests.course("Load "+course,900,day,day.plusDays(239),30)
    .put("id",Planner.stableID("stress-course-"+course)).put("priority",1+course%3));
   long started=System.nanoTime();Planner.replan(state,now);Planner.validate(state);
   if(SyncExchange.invalidPending(state,now))throw new AssertionError("Large engine plan rejected: "+count);
   Map<String,Integer> booked=new HashMap<>();for(JSONObject task:Planner.list(state.getJSONArray("tasks")))
    if(Planner.pending(task))booked.merge(task.getString("courseID"),task.getInt("durationMinutes"),Integer::sum);
   for(JSONObject course:Planner.list(state.getJSONArray("courses")))if(booked.getOrDefault(course.getString("id"),0)!=900)
    throw new AssertionError("Large feasible plan omitted or duplicated course work: "+course.getString("id"));
   SyncLedger ledger=new SyncLedger();ledger.capture(state,1000);JSONObject restored=ledger.materialize();
   if(restored.getJSONArray("tasks").length()!=state.getJSONArray("tasks").length())throw new AssertionError("Large plan lost tasks in ledger round trip");
   long sequence=ledger.sequence();ledger.capture(restored,2000);
   if(ledger.sequence()!=sequence)throw new AssertionError("Large no-op capture changed revisions");
   for(JSONObject course:Planner.list(restored.getJSONArray("courses")))if(Planner.remaining(restored,course)!=900)throw new AssertionError("Scheduling changed unfinished work");
   System.out.println("LARGE courses="+count+" horizonDays=240 tasks="+state.getJSONArray("tasks").length()+" records="+ledger.records().length()
    +" seconds="+((System.nanoTime()-started)/1e9)+" maxHeap="+Runtime.getRuntime().maxMemory());
  }
 }
 public static void main(String[] args)throws Exception{
  Thread watchdog=new Thread(()->{
   try{Thread.sleep(110_000);}catch(InterruptedException ignored){return;}
   System.err.println("Schedule stress exceeded 110 seconds: seed="+SEED+" phase="+phase);System.exit(1);
  },"schedule-stress-timeout");watchdog.setDaemon(true);watchdog.start();
  long started=System.nanoTime(),limit=started+110_000_000_000L;int completed=0,failed=0,tasks=0,maxTasks=0,warnings=0,history=0,withFloating=0,withExact=0,empty=0;
  for(int index=0;index<300&&System.nanoTime()<limit;index++){
   phase="case "+index;
   JSONObject state=fixture(index),before=CourseTools.copy(state);double now=state.getDouble("stressNow");
   try{
    List<String> problems=Planner.replan(state,now);warnings+=problems.isEmpty()?0:1;Planner.validate(state);int n=0;
    for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(task)&&Planner.end(task)>now)n++;
    tasks+=n;maxTasks=Math.max(maxTasks,n);if(n==0)empty++;if(before.getJSONArray("tasks").length()>0)history++;
    boolean f=false,e=false;for(JSONObject event:Planner.list(state.getJSONArray("fixedEvents"))){if(Planner.floating(event))f=true;else e=true;}if(f)withFloating++;if(e)withExact++;
    if(SyncExchange.invalidPending(state,now)){failed++;save("failure-"+index+"-before",before);save("failure-"+index+"-after",state);System.out.println("FAIL index="+index+" caseSeed="+(SEED+index*104729L)+" tasks="+n+" warnings="+problems);}
   }catch(Exception error){failed++;save("exception-"+index+"-before",before);System.out.println("EXCEPTION index="+index+" "+error);}
   completed++;if(completed%25==0)System.out.println("progress="+completed+" failures="+failed+" seconds="+((System.nanoTime()-started)/1e9));if(failed>=5)break;
  }
  System.out.println("RESULT seed="+SEED+" cases="+completed+" failures="+failed+" pendingTasks="+tasks+" maxPending="+maxTasks+" warningCases="+warnings+" historyCases="+history+" floatingCases="+withFloating+" exactCases="+withExact+" emptyPlans="+empty+" seconds="+((System.nanoTime()-started)/1e9));
  if(failed>0||completed!=300||tasks==0)throw new AssertionError("Stress checks failed, generated no work, or exceeded the 110-second budget");
  if(Arrays.asList(args).contains("--large"))largePlans();
 }
}
