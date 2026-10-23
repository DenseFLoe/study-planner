package local.studyplanner;

import org.json.*;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;

/** Pure local projections. They never change the shared planner state or real progress. */
final class DailyConsequences {
    static final int[] FRACTIONS={0,250,500,750,1000};
    static JSONObject fields(JSONObject source,String... names) throws Exception {
        JSONObject value=new JSONObject();for(String name:names)if(source.has(name))value.put(name,CourseTools.copyValue(source.get(name)));return value;
    }
    static String canonical(Object value) throws Exception {return SyncLedger.canonical(value);}
    static String revision(JSONObject state,int warning) throws Exception {
        List<JSONObject> courses=Planner.list(state.getJSONArray("courses"));courses.sort(Comparator.comparing(c->c.optString("id")));
        JSONArray configs=new JSONArray();for(JSONObject c:courses){JSONObject config=fields(c,"id","type","totalMinutes","startDate","deadline","minimumBlockMinutes","priority","dailyStudyWeight","autoScheduleEnabled","isArchived","lessonOrder");
            JSONArray lessons=new JSONArray();for(JSONObject l:CourseTools.lessons(c))lessons.put(fields(l,"id","durationMinutes","durationSeconds"));config.put("lessons",lessons);configs.put(config);}
        List<JSONObject> events=Planner.list(state.getJSONArray("fixedEvents"));events.sort(Comparator.comparing(e->e.optString("id")));JSONArray fixed=new JSONArray();
        for(JSONObject e:events){JSONObject config=fields(e,"id","startMinute","endMinute","startDate","endDate","floatingDurationMinutes");
            for(String key:new String[]{"weekdays","excludedDates"}){JSONArray raw=e.optJSONArray(key);List<Double> numbers=new ArrayList<>();if(raw!=null)for(int i=0;i<raw.length();i++)numbers.add(raw.getDouble(i));Collections.sort(numbers);config.put(key,new JSONArray(numbers));}fixed.put(config);}
        List<JSONObject> windows=Planner.list(state.getJSONObject("settings").getJSONArray("availability"));windows.sort(Comparator.comparingInt((JSONObject w)->w.optInt("weekday")).thenComparingInt(w->w.optInt("startMinute")).thenComparingInt(w->w.optInt("endMinute")));
        JSONArray availability=new JSONArray();for(JSONObject w:windows)availability.put(fields(w,"weekday","startMinute","endMinute"));
        return Planner.stableID(canonical(new JSONObject().put("courses",configs).put("events",fixed).put("availability",availability).put("unit",state.getJSONObject("settings").getInt("minimumScheduleUnit")).put("warning",warning).put("schedulingRuleLevels",new SchedulePriorities(state.getJSONObject("settings")).json())));
    }
    static JSONObject task(JSONObject state,String id){for(JSONObject task:Planner.list(state.optJSONArray("tasks")))if(task.optString("id").equals(id))return task;return null;}
    static LocalDate effectiveDay(JSONObject record,JSONObject state) {
        if(record.has("studyDate")&&!record.isNull("studyDate"))return Planner.day(record.optDouble("studyDate"));
        JSONObject task=task(state,record.optString("taskID"));LocalDate recorded=Planner.day(record.optDouble("recordedAt"));
        return task!=null&&Planner.day(task.optDouble("start")).equals(recorded)?recorded:null;
    }
    static int confirmed(LocalDate day,JSONObject state){int total=0;for(JSONObject r:Planner.list(state.optJSONArray("completions")))if(day.equals(effectiveDay(r,state)))total+=r.optInt("minutes");return total;}
    static int target(JSONObject entry,int fraction){return (int)((long)entry.optInt("goalMinutes")*fraction/1000);}
    static int threshold(JSONObject entry,int fraction){return target(entry,fraction)+(fraction==1000?0:1);}
    static boolean achieved(JSONObject entry,int fraction,int confirmed){return entry.optInt("goalMinutes")>0&&confirmed>=threshold(entry,fraction);}
    static List<Integer> fractions(JSONObject entry){List<Integer> values=new ArrayList<>();Set<Integer> seen=new HashSet<>();for(int f:FRACTIONS)if(f==1000||seen.add(target(entry,f)))values.add(f);return values;}
    static List<JSONObject> planned(JSONObject plan,LocalDate date,double now){List<JSONObject> tasks=new ArrayList<>();for(JSONObject t:Planner.list(plan.optJSONArray("tasks")))if(Planner.pending(t)&&Planner.end(t)>now&&Planner.day(t.optDouble("start")).equals(date))tasks.add(t);tasks.sort(Comparator.comparingDouble(t->t.optDouble("start")));return tasks;}
    static JSONObject capture(JSONObject state,JSONObject plan,double now,int warning) throws Exception {
        LocalDate today=Planner.day(now);int credited=confirmed(today,state),goal=credited;List<JSONObject> planned=planned(plan,today,now);for(JSONObject t:planned)goal+=t.optInt("durationMinutes");
        JSONObject baseline=baseline(state,now);
        JSONObject entry=new JSONObject().put("id",Planner.id()).put("date",Planner.at(today,0)).put("capturedAt",now).put("revision",revision(state,warning))
            .put("warningMinutes",warning).put("goalMinutes",goal).put("confirmedAtCapture",credited).put("capturedRecords",CourseTools.copyValue(state.getJSONArray("completions")))
            .put("plannedToday",CourseTools.copyValue(new JSONArray(planned))).put("baseline",baseline).put("forecasts",new JSONArray()).put("celebrated",new JSONArray());
        for(int f:fractions(entry))if(achieved(entry,f,credited))entry.getJSONArray("celebrated").put(f);return entry;
    }
    static JSONObject baseline(JSONObject state,double now) throws Exception {
        LocalDate today=Planner.day(now);
        JSONObject baseline=new JSONObject().put("schemaVersion",1).put("settings",CourseTools.copy(state.getJSONObject("settings"))).put("completions",new JSONArray());
        JSONArray courses=new JSONArray();for(JSONObject c:Planner.list(state.getJSONArray("courses"))){
            JSONObject copy=fields(c,"id","name","type","startDate","deadline","minimumBlockMinutes","priority","dailyStudyWeight","autoScheduleEnabled","isArchived");
            copy.put("totalMinutes",Planner.remaining(state,c)).put("initialCompletedMinutes",0);JSONArray lessons=new JSONArray();
            for(Planner.Work w:Planner.lessonWork(state,c))lessons.put(new JSONObject().put("id",w.lessonID).put("name",w.lessonName).put("durationMinutes",w.minutes));
            if(lessons.length()>0)copy.put("manualLessons",lessons);else copy.put("type","录播课程");courses.put(copy);
        }
        JSONArray events=new JSONArray();for(JSONObject e:Planner.list(state.getJSONArray("fixedEvents")))events.put(fields(e,"id","title","startMinute","endMinute","startDate","endDate","weekdays","excludedDates","floatingDurationMinutes"));
        JSONArray history=new JSONArray();for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(Planner.retainedHistoryEnd(t)>=Planner.at(today,0)-Planner.BREAK_SECONDS)history.put(CourseTools.copy(t));
        baseline.put("courses",courses).put("fixedEvents",events).put("tasks",history);
        return baseline;
    }
    static JSONObject find(JSONObject journal,LocalDate day){for(JSONObject entry:Planner.list(journal.optJSONArray("days")))if(Planner.day(entry.optDouble("date")).equals(day))return entry;return null;}
    static Set<Integer> integers(JSONArray values){Set<Integer> out=new HashSet<>();for(int i=0;i<values.length();i++)out.add(values.optInt(i));return out;}
    static final class Update {
        final JSONObject entry;final int confirmed;final Set<Integer> celebrations;
        Update(JSONObject entry,int confirmed,Set<Integer> celebrations){this.entry=entry;this.confirmed=confirmed;this.celebrations=celebrations;}
    }
    static Update refresh(JSONObject journal,JSONObject state,double now,int warning,String displayedEntryID)throws Exception{
        LocalDate date=Planner.day(now);JSONObject entry=find(journal,date);String revision=revision(state,warning);
        boolean animate=entry!=null&&entry.optString("id").equals(displayedEntryID);
        if(entry==null||!revision.equals(entry.optString("revision"))||!valid(entry,state)){
            JSONObject plan=baseline(state,now);Planner.replan(plan,now);JSONObject next=capture(state,plan,now,warning);
            if(entry!=null){if(entry.optString("revision").equals(revision(state,entry.optInt("warningMinutes"))))next.put("goalMinutes",entry.optInt("goalMinutes"));
                Set<Integer> celebrated=integers(entry.getJSONArray("celebrated"));for(int f:fractions(next))if(achieved(next,f,next.optInt("confirmedAtCapture")))celebrated.add(f);next.put("celebrated",new JSONArray(celebrated));}
            List<JSONObject> days=Planner.list(journal.getJSONArray("days"));days.removeIf(d->Planner.day(d.optDouble("date")).equals(date)||Planner.day(d.optDouble("date")).isBefore(date.minusDays(13)));days.add(next);journal.put("days",new JSONArray(days));entry=next;animate=false;
        }
        int actual=confirmed(date,state);Set<Integer> celebrated=integers(entry.getJSONArray("celebrated")),newly=new HashSet<>();
        for(int f:fractions(entry))if(achieved(entry,f,actual)&&celebrated.add(f)&&animate)newly.add(f);
        entry.put("celebrated",new JSONArray(celebrated));return new Update(entry,actual,newly);
    }
    static Set<String> capturedIDs(JSONObject entry){Set<String> ids=new HashSet<>();for(JSONObject r:Planner.list(entry.optJSONArray("capturedRecords")))ids.add(r.optString("id"));return ids;}
    static boolean valid(JSONObject entry,JSONObject state) throws Exception {
        Map<String,JSONObject> records=new HashMap<>();for(JSONObject r:Planner.list(state.getJSONArray("completions")))records.put(r.optString("id"),r);
        for(JSONObject r:Planner.list(entry.getJSONArray("capturedRecords")))if(!canonical(r).equals(canonical(records.get(r.optString("id")))))return false;
        Set<String> captured=capturedIDs(entry);LocalDate date=Planner.day(entry.optDouble("date"));
        for(JSONObject r:records.values())if(!captured.contains(r.optString("id"))){LocalDate day=effectiveDay(r,state);if(day!=null&&day.isBefore(date))return false;}
        JSONObject baseline=entry.getJSONObject("baseline");for(JSONObject c:Planner.list(baseline.getJSONArray("courses"))){JSONObject current=Planner.course(state,c.optString("id"));if(current==null)return false;int extra=0;
            for(JSONObject r:records.values())if(r.optString("courseID").equals(c.optString("id"))&&!captured.contains(r.optString("id")))extra+=r.optInt("minutes");
            if(Planner.remaining(state,current)!=Math.max(0,Planner.remaining(baseline,c)-extra))return false;
        }return true;
    }
    static void credit(JSONObject state,String courseID,String lessonID,int minutes) throws Exception {
        JSONObject c=Planner.course(state,courseID);if(c==null||minutes<=0)return;JSONArray raw=c.optJSONArray("manualLessons");
        if(raw==null){c.put("totalMinutes",Math.max(0,c.optInt("totalMinutes")-minutes));return;}
        List<JSONObject> lessons=Planner.list(raw);JSONObject chosen=null;for(JSONObject l:lessons)if(l.optString("id").equals(lessonID))chosen=l;
        if(chosen!=null)chosen.put("durationMinutes",Math.max(0,chosen.optInt("durationMinutes")-minutes));
        else for(JSONObject l:lessons){int used=Math.min(minutes,l.optInt("durationMinutes"));l.put("durationMinutes",l.optInt("durationMinutes")-used);minutes-=used;if(minutes<=0)break;}
        JSONArray left=new JSONArray();int total=0;for(JSONObject l:lessons)if(l.optInt("durationMinutes")>0){left.put(l);total+=l.optInt("durationMinutes");}c.put("manualLessons",left).put("totalMinutes",total);
    }
    static JSONObject forecast(JSONObject entry,int fraction,int horizon) throws Exception {
        int target=target(entry,fraction),captured=entry.optInt("confirmedAtCapture");JSONObject forecast=new JSONObject().put("fraction",fraction).put("todayMinutes",target).put("evaluatedDays",0);
        if(target<captured)return forecast;JSONObject state=CourseTools.copy(entry.getJSONObject("baseline"));double now=entry.optDouble("capturedAt");LocalDate date=Planner.day(now);
        Planner.replan(state,now);List<JSONObject> today=planned(state,date,now);int available=0;for(JSONObject t:today)available+=t.optInt("durationMinutes");
        if(target-captured>available)return forecast.put("unavailableTodayMinutes",target-captured-available);
        int warning=entry.optInt("warningMinutes");updateLimits(forecast,ScheduleHealth.outcome(state,now,warning),0);
        LocalDate last=date;for(JSONObject c:Planner.list(state.getJSONArray("courses")))if(!c.optBoolean("isArchived")&&c.optBoolean("autoScheduleEnabled",true)&&Planner.day(c.optDouble("deadline")).isAfter(last))last=Planner.day(c.optDouble("deadline"));
        int count=(int)Math.min(Math.max(1,horizon),Math.max(1,ChronoUnit.DAYS.between(date,last)+1));
        for(int i=0;i<count;i++){
            if(Thread.currentThread().isInterrupted())throw new InterruptedException();LocalDate day=Planner.day(now);List<JSONObject> tasks=planned(state,day,now);int total=0;for(JSONObject t:tasks)total+=t.optInt("durationMinutes");
            int budget=i==0?Math.max(0,target-captured):(int)((long)total*fraction/1000);JSONArray history=new JSONArray();
            for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(!Planner.pending(t)&&Planner.planningEnd(t)>=Planner.at(day,0))history.put(t);
            for(JSONObject t:tasks){int actual=Math.min(t.optInt("durationMinutes"),budget);budget-=actual;credit(state,t.optString("courseID"),t.optString("lessonID"),actual);
                if(actual>0)history.put(CourseTools.copy(t).put("completedMinutes",actual).put("status","completed").put("confirmedAt",t.optDouble("start")+actual*60.0));}
            state.put("tasks",history);state.getJSONObject("settings").remove("actualStudyStart");now=Planner.at(day.plusDays(1),0);Planner.replan(state,now);
            JSONObject outcome=ScheduleHealth.outcome(state,now,warning);forecast.put("evaluatedDays",i+1);if(i==0)forecast.put("firstDay",outcome);updateLimits(forecast,outcome,i+1);
            if(forecast.has("provenLimitAfterDays"))break;boolean complete=true;for(JSONObject c:Planner.list(state.getJSONArray("courses")))if(!c.optBoolean("isArchived")&&c.optBoolean("autoScheduleEnabled",true)&&Planner.remaining(state,c)>0)complete=false;if(complete)break;
        }return forecast;
    }
    static void updateLimits(JSONObject forecast,JSONObject outcome,int day) throws Exception {
        if(outcome.optInt("heavyDays")>0&&!forecast.has("pressureAfterDays"))forecast.put("pressureAfterDays",day);
        if(outcome.optString("kind").equals("pending")&&!forecast.has("uncertainFromDay"))forecast.put("uncertainFromDay",day);
        if(outcome.optString("kind").equals("shortage")&&!forecast.has("provenLimitAfterDays"))forecast.put("provenLimitAfterDays",day);
    }
    static JSONObject reality(JSONObject entry,JSONObject state) throws Exception {
        LocalDate date=Planner.day(entry.optDouble("date"));int actual=confirmed(date,state),ambiguous=0;boolean legacy=false,pending=false;
        Set<String> captured=capturedIDs(entry);Map<String,Integer> targets=new HashMap<>(),reviewed=new HashMap<>();
        for(JSONObject t:Planner.list(entry.getJSONArray("plannedToday")))targets.merge(ScheduleHealth.key(t),t.optInt("durationMinutes"),Integer::sum);
        JSONObject projection=CourseTools.copy(entry.getJSONObject("baseline"));
        for(JSONObject r:Planner.list(state.getJSONArray("completions"))){JSONObject t=task(state,r.optString("taskID"));LocalDate effective=effectiveDay(r,state);
            if(effective==null&&(date.equals(Planner.day(r.optDouble("recordedAt")))||(t!=null&&date.equals(Planner.day(t.optDouble("start"))))))ambiguous++;
            if(date.equals(effective)&&!r.has("studyDate"))legacy=true;if(captured.contains(r.optString("id")))continue;
            if(t!=null&&date.equals(Planner.day(t.optDouble("start")))){String key=ScheduleHealth.key(t);int n=t.optInt("durationMinutes");reviewed.put(key,t.has("lessonID")?Math.max(reviewed.getOrDefault(key,0),n):reviewed.getOrDefault(key,0)+n);}
            if(date.equals(effective))credit(projection,r.optString("courseID"),t==null?"":t.optString("lessonID"),r.optInt("minutes"));
        }
        JSONArray history=new JSONArray();for(JSONObject t:Planner.list(state.getJSONArray("tasks"))){if(Planner.pending(t)&&date.equals(Planner.day(t.optDouble("start"))))pending=true;
            if(t.has("confirmedAt")&&t.optInt("completedMinutes")>0&&date.equals(Planner.day(t.optDouble("confirmedAt"))))history.put(CourseTools.copy(t));}
        boolean covered=true;for(String key:targets.keySet())if(reviewed.getOrDefault(key,0)<targets.get(key))covered=false;
        JSONObject value=new JSONObject().put("date",entry.getDouble("date")).put("confirmedMinutes",actual).put("goalMinutes",entry.optInt("goalMinutes")).put("ambiguousRecords",ambiguous).put("usesLegacyDates",legacy)
            .put("pending",pending).put("isReviewed",ambiguous==0&&!pending&&(entry.has("reviewedAt")||covered||actual>=entry.optInt("goalMinutes")));
        if(valid(entry,state)&&revision(state,entry.optInt("warningMinutes")).equals(entry.optString("revision"))){projection.put("tasks",history);double now=Planner.at(date.plusDays(1),0);Planner.replan(projection,now);value.put("outcome",ScheduleHealth.outcome(projection,now,entry.optInt("warningMinutes")));}
        return value;
    }
}
