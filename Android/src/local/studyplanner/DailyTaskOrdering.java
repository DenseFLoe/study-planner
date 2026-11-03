package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Same persisted keys, whole-task placement and retained-history boundaries as StudyCore. */
public final class DailyTaskOrdering {
    public static final String NO_SPACE="交换后无法在当天可学习时段内保留课程时长和课间休息，请调整可学习时间或选择其他板块。";
    static List<String> keys(List<JSONObject> tasks){
        Map<String,Integer> counts=new HashMap<>();List<String> keys=new ArrayList<>();
        for(JSONObject task:tasks){String base=task.optString("courseID")+"|"+task.optString("lessonID")+"|"+task.optInt("durationMinutes");int n=counts.getOrDefault(base,0);counts.put(base,n+1);keys.add(base+"|"+n);}
        return keys;
    }
    static List<JSONObject> place(JSONObject state,List<JSONObject> ordered,double earliest)throws Exception {
        return place(state,ordered,earliest,null);
    }
    private static List<JSONObject> place(JSONObject state,List<JSONObject> ordered,double earliest,Map<String,Integer> floatingPlacements)throws Exception {
        LocalDate day=Planner.day(earliest);boolean[] study=new boolean[1440],available=new boolean[1440];
        for(JSONObject w:Planner.list(state.getJSONObject("settings").getJSONArray("availability")))if(w.optInt("weekday")==Planner.weekday(day)&&w.optInt("startMinute")>=0&&w.optInt("endMinute")<=1440&&w.optInt("startMinute")<w.optInt("endMinute"))for(int m=w.getInt("startMinute");m<w.getInt("endMinute");m++)study[m]=available[m]=true;
        List<JSONObject> events=new ArrayList<>();for(JSONObject e:Planner.list(state.getJSONArray("fixedEvents")))if(Planner.occurs(e,day))events.add(e);
        Map<String,Integer> reserved=floatingPlacements==null?Planner.reserve(events,study):floatingPlacements;if(reserved==null)return null;
        for(JSONObject e:events){int start=reserved.getOrDefault(e.getString("id"),e.getInt("startMinute"));for(int m=start;m<start+Planner.occupied(e);m++)available[m]=false;}
        Set<String> moving=new HashSet<>();for(JSONObject t:ordered)moving.add(t.getString("id"));
        // Include neighboring days when their buffered interval reaches this day.
        double dayStart=Planner.at(day,0),dayEnd=Planner.at(day.plusDays(1),0);
        List<JSONObject> obstacles=new ArrayList<>();for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(!moving.contains(t.getString("id"))&&(Planner.pending(t)||t.optInt("completedMinutes")>0)
            &&Planner.retainedHistoryEnd(t)+Planner.BREAK_SECONDS>dayStart&&Planner.retainedHistoryStart(t)-Planner.BREAK_SECONDS<dayEnd)obstacles.add(t);
        List<JSONObject> placed=new ArrayList<>();double cursor=earliest;
        for(JSONObject source:ordered){boolean found=false;int first=Planner.day(cursor).equals(day)?(int)((cursor-Planner.at(day,0))/60):1440;
            for(int minute=first;minute<1440;minute++){
                int endMinute=minute+source.getInt("durationMinutes");double start=Planner.at(day,minute),end=Planner.at(day,endMinute);
                if(start<cursor||endMinute>1440||!available[minute])continue;
                boolean blocked=false;for(int m=minute;m<endMinute;m++)if(!available[m]){blocked=true;break;}
                if(blocked)continue;
                for(JSONObject obstacle:obstacles)if(start<Planner.retainedHistoryEnd(obstacle)+Planner.BREAK_SECONDS&&end>Planner.retainedHistoryStart(obstacle)-Planner.BREAK_SECONDS){blocked=true;break;}
                if(blocked)continue;
                JSONObject task=new JSONObject(source.toString());task.put("start",start);task.remove("floatingWindowStart");task.remove("floatingWindowEnd");
                int regionStart=1440,regionEnd=0;for(JSONObject e:events)if(Planner.floating(e)&&e.getInt("startMinute")<endMinute&&e.getInt("endMinute")>minute){regionStart=Math.min(regionStart,e.getInt("startMinute"));regionEnd=Math.max(regionEnd,e.getInt("endMinute"));}
                if(regionEnd>0){int lower=minute,upper=endMinute;while(lower>regionStart&&inWindow(lower-1,study,events))lower--;while(upper<regionEnd&&inWindow(upper,study,events))upper++;task.put("floatingWindowStart",Planner.at(day,lower)).put("floatingWindowEnd",Planner.at(day,upper));}
                placed.add(task);cursor=end+Planner.BREAK_SECONDS;found=true;break;
            }
            if(!found){
                if(floatingPlacements!=null)return null;
                Map<String,Integer> alternate=jointFloatingPlacements(ordered,earliest,day,study,events,obstacles);
                return alternate==null?null:place(state,ordered,earliest,alternate);
            }
        }
        return placed;
    }
    /** One queue preserves the user's order; only the event witness is reused. */
    private static Map<String,Integer> jointFloatingPlacements(List<JSONObject> ordered,double earliest,LocalDate day,
            boolean[] study,List<JSONObject> events,List<JSONObject> obstacles)throws Exception {
        List<JSONObject> floating=new ArrayList<>(),exact=new ArrayList<>();
        for(JSONObject event:events)(Planner.floating(event)?floating:exact).add(event);
        if(floating.isEmpty()||floating.size()>8||ordered.size()>600)return null;
        boolean[] eventFree=new boolean[1440],studyFree=new boolean[1440];
        for(int minute=0;minute<1440;minute++){
            boolean free=true;double start=Planner.at(day,minute),end=Planner.at(day,minute+1);
            for(JSONObject event:exact)if(minute>=event.getInt("startMinute")&&minute<event.getInt("endMinute")){free=false;break;}
            if(free)for(JSONObject obstacle:obstacles)if(start<Planner.retainedHistoryEnd(obstacle)+Planner.BREAK_SECONDS
                &&end>Planner.retainedHistoryStart(obstacle)-Planner.BREAK_SECONDS){free=false;break;}
            eventFree[minute]=free;studyFree[minute]=free&&study[minute];
        }
        JSONObject queueCourse=new JSONObject().put("id",ordered.get(0).getString("courseID"))
            .put("startDate",Planner.at(day,0)).put("deadline",Planner.at(day,0));
        List<Planner.Work> work=new ArrayList<>();for(JSONObject task:ordered)work.add(new Planner.Work(task.getInt("durationMinutes"),null,null));
        List<ScheduleFeasibilitySearch.Floating> jobs=new ArrayList<>();for(JSONObject event:floating)jobs.add(new ScheduleFeasibilitySearch.Floating(day,event));
        ScheduleFeasibilitySearch.Solution solution=ScheduleFeasibilitySearch.find(
            Collections.singletonList(new ScheduleFeasibilitySearch.Queue(queueCourse,work)),searchWindows(studyFree,day),searchWindows(eventFree,day),jobs,
            ScheduleFeasibilitySearch.minute(earliest),ScheduleFeasibilitySearch.minute(Planner.at(day,0)));
        if(solution==null||solution.tasks.size()!=ordered.size()||solution.floatingStarts.size()!=floating.size())return null;
        Map<String,Integer> placements=new HashMap<>();
        for(int i=0;i<floating.size();i++){
            Integer start=solution.floatingStarts.get(i);if(start==null)return null;
            // Invert Planner.at's elapsed minutes, including dates with an offset transition.
            placements.put(floating.get(i).getString("id"),(int)((start*60.0-Planner.at(day,0))/60));
        }
        return placements;
    }
    private static List<ScheduleFeasibilitySearch.Window> searchWindows(boolean[] free,LocalDate day){
        List<ScheduleFeasibilitySearch.Window> result=new ArrayList<>();int start=-1;
        for(int minute=0;minute<=1440;minute++){
            boolean available=minute<1440&&free[minute];if(available&&start<0)start=minute;
            if(!available&&start>=0){result.add(new ScheduleFeasibilitySearch.Window(ScheduleFeasibilitySearch.minute(Planner.at(day,start)),ScheduleFeasibilitySearch.minute(Planner.at(day,minute))));start=-1;}
        }
        return result;
    }
    static boolean inWindow(int minute,boolean[] study,List<JSONObject> events){if(minute<0||minute>=1440||!study[minute])return false;for(JSONObject e:events)if(!Planner.floating(e)&&minute>=e.optInt("startMinute")&&minute<e.optInt("endMinute"))return false;return true;}
    public static void swap(JSONObject state,String sourceID,String targetID,double now)throws Exception {
        JSONObject source=null,target=null;for(JSONObject t:Planner.list(state.getJSONArray("tasks"))){if(t.getString("id").equals(sourceID))source=t;if(t.getString("id").equals(targetID))target=t;}
        if(source==null||target==null||sourceID.equals(targetID)||!Planner.pending(source)||!Planner.pending(target)||!Planner.day(source.getDouble("start")).equals(Planner.day(target.getDouble("start")))||Planner.day(source.getDouble("start")).isBefore(Planner.day(now)))throw new IllegalArgumentException("只能交换同一天的两个不同未确认学习板块，请刷新后重试。");
        LocalDate day=Planner.day(source.getDouble("start"));List<JSONObject> original=new ArrayList<>();for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(t)&&Planner.day(t.getDouble("start")).equals(day))original.add(t);
        original.sort(Comparator.comparingDouble(t->t.optDouble("start")));List<String> keys=keys(original);List<JSONObject> ordered=new ArrayList<>(original);int a=original.indexOf(source),b=original.indexOf(target);Collections.swap(keys,a,b);Collections.swap(ordered,a,b);
        List<JSONObject> placed=place(state,ordered,original.get(0).getDouble("start"));if(placed==null)throw new IllegalArgumentException(NO_SPACE);
        Map<String,JSONObject> updated=new HashMap<>();for(JSONObject t:placed)updated.put(t.getString("id"),t);List<JSONObject> tasks=new ArrayList<>();for(JSONObject t:Planner.list(state.getJSONArray("tasks")))tasks.add(updated.getOrDefault(t.getString("id"),t));tasks.sort(Comparator.comparingDouble(t->t.optDouble("start")));
        JSONArray orders=new JSONArray();JSONArray old=state.getJSONObject("settings").optJSONArray("dailyTaskOrders");if(old!=null)for(JSONObject order:Planner.list(old))if(!Planner.day(order.getDouble("day")).equals(day))orders.put(order);
        orders.put(new JSONObject().put("day",Planner.at(day,0)).put("keys",new JSONArray(keys)));
        state.put("tasks",new JSONArray(tasks));state.getJSONObject("settings").put("dailyTaskOrders",orders);
    }
    static List<JSONObject> apply(JSONObject state,List<JSONObject> generated,List<JSONObject> history)throws Exception {
        JSONArray orders=state.getJSONObject("settings").optJSONArray("dailyTaskOrders");if(orders==null)return generated;
        List<JSONObject> result=new ArrayList<>(generated);JSONObject context=new JSONObject(state.toString());context.put("tasks",new JSONArray(history));
        for(JSONObject order:Planner.list(orders)){
            LocalDate day=Planner.day(order.getDouble("day"));List<Integer> indices=new ArrayList<>();for(int i=0;i<result.size();i++)if(Planner.day(result.get(i).getDouble("start")).equals(day))indices.add(i);
            List<JSONObject> original=new ArrayList<>();for(int index:indices)original.add(result.get(index));original.sort(Comparator.comparingDouble(t->t.optDouble("start")));if(original.isEmpty())continue;
            List<String> keys=keys(original);Map<String,Integer> ranks=new HashMap<>();JSONArray preferred=order.getJSONArray("keys");for(int i=0;i<preferred.length();i++)ranks.putIfAbsent(preferred.getString(i),i);
            Map<String,Integer> taskRanks=new HashMap<>();for(int i=0;i<original.size();i++)taskRanks.put(original.get(i).getString("id"),ranks.getOrDefault(keys.get(i),preferred.length()+i));List<JSONObject> sorted=new ArrayList<>(original);sorted.sort(Comparator.comparingInt(t->taskRanks.get(t.optString("id"))));
            // Generated neighboring days are not in persisted history yet.
            List<JSONObject> obstacles=new ArrayList<>(history);Set<String> retainedIDs=new HashSet<>();for(JSONObject t:history)retainedIDs.add(t.getString("id"));
            for(JSONObject t:result)if(!Planner.day(t.getDouble("start")).equals(day)&&!retainedIDs.contains(t.getString("id")))obstacles.add(t);
            context.put("tasks",new JSONArray(obstacles));
            List<JSONObject> placed=place(context,sorted,original.get(0).getDouble("start"));if(placed!=null)for(int i=0;i<indices.size();i++)result.set(indices.get(i),placed.get(i));
        }
        result.sort(Comparator.comparingDouble(t->t.optDouble("start")));return result;
    }
}
