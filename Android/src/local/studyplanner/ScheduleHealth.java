package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Distinguishes a complete plan, heavy days, unknown placement and proven hard conflicts. */
final class ScheduleHealth {
    static JSONArray array(JSONObject state,String key){JSONArray a=state.optJSONArray(key);return a==null?new JSONArray():a;}
    static void record(JSONObject state,List<JSONObject> courses,Map<String,Integer> required,Map<String,Integer> missing,
                       Map<String,List<Planner.Work>> work,List<Planner.Day> hard,List<Planner.Day> original,
                       List<JSONObject> tasks,LocalDate today,LocalDate horizon,JSONArray adjustments) throws Exception {
        JSONArray plans=new JSONArray(),conflicts=new JSONArray();
        for(Planner.Day day:original){int capacity=0,planned=0;for(Planner.Span span:day.free)capacity+=span.minutes();
            for(JSONObject t:tasks)if(Planner.day(t.optDouble("start")).equals(day.d))planned+=t.optInt("durationMinutes");
            plans.put(new JSONObject().put("date",Planner.at(day.d,0)).put("availableMinutes",capacity).put("plannedMinutes",planned));}
        boolean bounded=false;Set<LocalDate> starts=new TreeSet<>(),ends=new TreeSet<>();starts.add(today);
        for(JSONObject c:courses){LocalDate start=Planner.day(c.optDouble("startDate")),end=Planner.day(c.optDouble("deadline"));starts.add(start.isAfter(today)?start:today);ends.add(end);if(end.isAfter(horizon))bounded=true;}
        if(!bounded){
            // Ignoring breaks and floating occupancy is an optimistic capacity upper bound.
            for(LocalDate start:starts)for(LocalDate end:ends){int needed=0,upper=0;JSONArray names=new JSONArray();
                for(JSONObject c:courses){LocalDate from=Planner.day(c.optDouble("startDate"));if(from.isBefore(today))from=today;
                    if(!from.isBefore(start)&&!Planner.day(c.optDouble("deadline")).isAfter(end)){needed+=required.get(c.optString("id"));names.put(c.optString("name"));}}
                for(Planner.Day day:hard)if(!day.d.isBefore(start)&&!day.d.isAfter(end))for(Planner.Span span:day.free)upper+=span.minutes();
                if(needed>upper)conflicts.put(new JSONObject().put("windowStart",Planner.at(start,0)).put("deadline",Planner.at(end,0)).put("requiredMinutes",needed).put("availableMinutes",upper).put("provenDeficit",needed-upper).put("courseNames",names));
            }
            for(JSONObject c:courses){int longest=0;for(Planner.Day day:hard)if(Planner.eligible(c,day.d))for(Planner.Span span:day.free)longest=Math.max(longest,span.minutes());
                for(Planner.Work item:work.get(c.optString("id")))if(item.minutes>longest){conflicts.put(new JSONObject().put("windowStart",Math.max(Planner.at(today,0),c.optDouble("startDate"))).put("deadline",c.optDouble("deadline")).put("requiredMinutes",item.minutes).put("availableMinutes",longest).put("minimumContinuousMinutes",item.minutes).put("courseNames",new JSONArray().put(c.optString("name"))));break;}
            }
        }
        state.put("androidMissing",new JSONObject(missing)).put("androidDayPlans",plans).put("androidConflicts",conflicts).put("androidAdjustments",adjustments);
    }
    static String key(JSONObject task){return task.optString("courseID")+"|"+task.optString("lessonID");}
    static JSONObject assess(JSONObject state,double now,int warning) throws Exception {
        int remaining=0,missing=0,paused=0,peak=0,heavy=0,total=0,count=0,reviewed=0,credited=0;
        Map<String,Integer> debts=new HashMap<>();JSONObject absent=state.optJSONObject("androidMissing");
        for(JSONObject c:Planner.list(state.getJSONArray("courses")))if(!c.optBoolean("isArchived")&&Planner.remaining(state,c)>0){
            int n=Planner.remaining(state,c);remaining+=n;if(!c.optBoolean("autoScheduleEnabled",true))paused+=n;else missing+=absent==null?0:absent.optInt(c.optString("id"));
        }
        for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(t.has("confirmedAt")&&Planner.day(t.optDouble("confirmedAt")).equals(Planner.day(now))){
            reviewed+=t.optInt("durationMinutes");credited+=t.optInt("completedMinutes");JSONObject c=Planner.course(state,t.optString("courseID"));
            if(c==null||c.optBoolean("isArchived"))continue;int cap=Planner.remaining(state,c);
            if(t.has("lessonID"))for(Planner.Work w:Planner.lessonWorkAll(state,c))if(w.lessonID.equals(t.optString("lessonID"))){cap=w.minutes;break;}
            int debt=Math.max(0,Math.min(cap,t.optInt("durationMinutes")-t.optInt("completedMinutes"))),old=debts.getOrDefault(key(t),0);
            debts.put(key(t),t.has("lessonID")?Math.max(old,debt):Math.min(cap,old+debt));
        }
        for(JSONObject day:Planner.list(array(state,"androidDayPlans"))){int n=day.optInt("plannedMinutes");if(n>0){count++;total+=n;peak=Math.max(peak,n);if(n>Math.max(30,warning))heavy++;}}
        Map<LocalDate,Integer> recovery=new TreeMap<>();List<JSONObject> tasks=Planner.list(state.getJSONArray("tasks"));tasks.sort(Comparator.comparingDouble(t->t.optDouble("start")));
        for(JSONObject t:tasks)if(Planner.pending(t)&&Planner.planningEnd(t)>now){String key=key(t);int n=Math.min(t.optInt("durationMinutes"),debts.getOrDefault(key,0));if(n>0){recovery.merge(Planner.day(t.optDouble("start")),n,Integer::sum);debts.put(key,debts.get(key)-n);}}
        JSONArray recoveries=new JSONArray();for(Map.Entry<LocalDate,Integer> e:recovery.entrySet())recoveries.put(new JSONObject().put("date",Planner.at(e.getKey(),0)).put("plannedMinutes",e.getValue()));
        String kind=array(state,"androidConflicts").length()>0?"shortage":missing>0||paused>0||array(state,"androidWarnings").length()>0?"pending":heavy>0?"heavy":"scheduled";
        return new JSONObject().put("kind",kind).put("remainingMinutes",remaining).put("unplacedMinutes",missing).put("pausedMinutes",paused)
            .put("peakMinutes",peak).put("heavyDays",heavy).put("averageMinutes",count==0?0:Math.round((double)total/count))
            .put("reviewedMinutes",reviewed).put("creditedMinutes",credited).put("recovery",recoveries);
    }
    static JSONObject outcome(JSONObject state,double now,int warning) throws Exception {
        JSONObject result=assess(state,now,warning),proof=null;
        for(JSONObject conflict:Planner.list(array(state,"androidConflicts")))if(proof==null||conflict.optInt("provenDeficit")>proof.optInt("provenDeficit"))proof=conflict;
        if(proof!=null){for(String key:new String[]{"provenDeficit","minimumContinuousMinutes","courseNames"})if(proof.has(key))result.put(key,proof.get(key));}
        return result;
    }
    static String title(String kind){switch(kind){case "heavy":return "能按期排完 · 学习负担偏重";case "pending":return "当前方案还没排好";case "shortage":return "已确认存在时间约束冲突";default:return "已安排 · 仍可按期完成";}}
}
