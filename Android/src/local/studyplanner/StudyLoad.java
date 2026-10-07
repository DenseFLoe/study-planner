package local.studyplanner;

import org.json.*;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;

/** Divisible-minute upper bound, including paused courses; only daily fixed rules reduce it. */
public final class StudyLoad {
    public static final class Assessment {
        public int level,required,available,days,warningAfter,criticalAfter;public LocalDate start,deadline;public boolean limited;
        public double dailyRequired(){return required/(60.0*days);}public double dailyCapacity(){return available/(60.0*days);}public double utilization(){return available>0?required/(double)available:Double.POSITIVE_INFINITY;}
    }
    static class Work {int start,end,minutes;Work(int start,int end,int minutes){this.start=start;this.end=end;this.minutes=minutes;}}
    public static Assessment assess(JSONObject state,double now)throws Exception {
        LocalDate today=Planner.day(now);int horizon=(int)ChronoUnit.DAYS.between(today,today.plusYears(10)),last=0;List<Work> work=new ArrayList<>();boolean limited=false;
        for(JSONObject course:Planner.list(state.getJSONArray("courses")))if(!course.optBoolean("isArchived")&&Planner.remaining(state,course)>0){int start=(int)ChronoUnit.DAYS.between(today,Planner.day(course.getDouble("startDate"))),end=(int)ChronoUnit.DAYS.between(today,Planner.day(course.getDouble("deadline")));limited|=end>horizon;end=Math.min(horizon,end);work.add(new Work(Math.max(0,Math.min(horizon+1,start)),end,Planner.remaining(state,course)));last=Math.max(last,end);}
        if(work.isEmpty())return null;List<JSONObject> daily=new ArrayList<>();for(JSONObject event:Planner.list(state.getJSONArray("fixedEvents"))){Set<Integer> weekdays=new HashSet<>();JSONArray days=event.optJSONArray("weekdays");if(days!=null)for(int i=0;i<days.length();i++)weekdays.add(days.optInt(i));if(weekdays.size()==7&&event.optInt("startMinute")>=0&&event.optInt("endMinute")<=1440&&Planner.occupied(event)>0&&Planner.occupied(event)<=event.optInt("endMinute")-event.optInt("startMinute"))daily.add(event);}
        int[] prefix=new int[last+2];Map<String,Integer> cached=new HashMap<>();
        for(int index=0;index<=last;index++){LocalDate day=today.plusDays(index);List<JSONObject> active=new ArrayList<>();String key=""+Planner.weekday(day);for(int i=0;i<daily.size();i++)if(Planner.occurs(daily.get(i),day)){active.add(daily.get(i));key+="|"+i;}Integer capacity=cached.get(key);
            if(capacity==null){boolean[] free=new boolean[1440];for(JSONObject w:Planner.list(state.getJSONObject("settings").getJSONArray("availability")))if(w.optInt("weekday")==Planner.weekday(day)&&w.optInt("startMinute")>=0&&w.optInt("endMinute")<=1440&&w.optInt("startMinute")<w.optInt("endMinute"))for(int m=w.getInt("startMinute");m<w.getInt("endMinute");m++)free[m]=true;
                for(JSONObject event:active)if(!Planner.floating(event))for(int m=event.getInt("startMinute");m<event.getInt("endMinute");m++)free[m]=false;
                int count=0,cost=0;for(boolean value:free)if(value)count++;for(JSONObject event:active)if(Planner.floating(event)){int outside=0;for(int m=event.getInt("startMinute");m<event.getInt("endMinute");m++)if(!free[m])outside++;cost+=Math.max(0,Planner.occupied(event)-outside);}capacity=Math.max(0,count-cost);cached.put(key,capacity);
            }prefix[index+1]=prefix[index]+capacity;
        }
        Assessment result=snapshot(work,prefix,today,0);result.limited=limited;result.warningAfter=first(work,prefix,today,last,result,1);result.criticalAfter=first(work,prefix,today,last,result,2);return result;
    }
    static Assessment snapshot(List<Work> work,int[] prefix,LocalDate today,int skipped){Set<Integer> starts=new TreeSet<>(),ends=new TreeSet<>();starts.add(skipped);for(Work w:work){starts.add(Math.max(skipped,w.start));ends.add(w.end);}Assessment worst=null;
        for(int start:starts)for(int end:ends){int required=0;for(Work w:work)if(Math.max(skipped,w.start)>=start&&w.end<=end)required+=w.minutes;if(required==0)continue;int available=end>=start&&start<prefix.length-1?prefix[end+1]-prefix[start]:0;Assessment candidate=new Assessment();candidate.level=required>available?2:required>=available*.8?1:0;candidate.start=today.plusDays(start);candidate.deadline=today.plusDays(end);candidate.required=required;candidate.available=available;candidate.days=Math.max(1,end-start+1);if(worst==null||candidate.utilization()>worst.utilization())worst=candidate;}
        return worst;
    }
    static int first(List<Work> work,int[] prefix,LocalDate today,int last,Assessment initial,int threshold){if(initial.level>=threshold)return 0;int low=1,high=last+1;while(low<high){int middle=low+(high-low)/2;if(snapshot(work,prefix,today,middle).level>=threshold)high=middle;else low=middle+1;}return low;}
}
