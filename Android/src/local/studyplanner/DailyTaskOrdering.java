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
        LocalDate day=Planner.day(earliest);boolean[] study=new boolean[1440],available=new boolean[1440];
        for(JSONObject w:Planner.list(state.getJSONObject("settings").getJSONArray("availability")))if(w.optInt("weekday")==Planner.weekday(day)&&w.optInt("startMinute")>=0&&w.optInt("endMinute")<=1440&&w.optInt("startMinute")<w.optInt("endMinute"))for(int m=w.getInt("startMinute");m<w.getInt("endMinute");m++)study[m]=available[m]=true;
        List<JSONObject> events=new ArrayList<>();for(JSONObject e:Planner.list(state.getJSONArray("fixedEvents")))if(Planner.occurs(e,day))events.add(e);
        Map<String,Integer> reserved=Planner.reserve(events,study);if(reserved==null)return null;
        for(JSONObject e:events){int start=reserved.getOrDefault(e.getString("id"),e.getInt("startMinute"));for(int m=start;m<start+Planner.occupied(e);m++)available[m]=false;}
        Set<String> moving=new HashSet<>();for(JSONObject t:ordered)moving.add(t.getString("id"));
        List<JSONObject> obstacles=new ArrayList<>();for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(!moving.contains(t.getString("id"))&&Planner.day(t.getDouble("start")).equals(day)&&(Planner.pending(t)||t.optInt("completedMinutes")>0))obstacles.add(t);
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
            if(!found)return null;
        }
        return placed;
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
            List<JSONObject> placed=place(context,sorted,original.get(0).getDouble("start"));if(placed!=null)for(int i=0;i<indices.size();i++)result.set(indices.get(i),placed.get(i));
        }
        result.sort(Comparator.comparingDouble(t->t.optDouble("start")));return result;
    }
}
