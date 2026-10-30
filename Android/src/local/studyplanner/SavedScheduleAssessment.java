package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Diagnose the persisted timetable, without silently substituting a new draft. */
final class SavedScheduleAssessment {
    static void refresh(JSONObject state,double now)throws Exception {
        JSONObject preview=CourseTools.copy(state);Planner.replan(preview,now);
        List<JSONObject> courses=new ArrayList<>(),tasks=new ArrayList<>();
        Map<String,Integer> booked=new HashMap<>();Map<LocalDate,Integer> daily=new HashMap<>();
        for(JSONObject c:Planner.list(state.getJSONArray("courses")))
            if(!c.optBoolean("isArchived")&&c.optBoolean("autoScheduleEnabled",true)&&Planner.remaining(state,c)>0)courses.add(c);
        Set<String> ids=new HashSet<>();for(JSONObject c:courses)ids.add(c.getString("id"));
        for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(t)&&Planner.planningEnd(t)>now&&ids.contains(t.optString("courseID"))){
            tasks.add(t);booked.merge(t.getString("courseID"),t.getInt("durationMinutes"),Integer::sum);
            daily.merge(Planner.day(t.getDouble("start")),t.getInt("durationMinutes"),Integer::sum);
        }
        JSONObject missing=new JSONObject();Set<String> missingNames=new HashSet<>();JSONArray warnings=new JSONArray();
        for(JSONObject c:courses){int n=Math.max(0,Planner.remaining(state,c)-booked.getOrDefault(c.getString("id"),0));missing.put(c.getString("id"),n);
            if(n>0){missingNames.add(c.getString("name"));warnings.put(c.getString("name")+"：仍有 "+n+" 分钟未排入当前课表，请重新排程或调整可学习时间。");}}
        JSONArray plans=ScheduleHealth.array(preview,"androidDayPlans"),risks=new JSONArray(),conflicts=new JSONArray();
        for(JSONObject d:Planner.list(plans))d.put("plannedMinutes",daily.getOrDefault(Planner.day(d.getDouble("date")),0));
        Set<LocalDate> cutoffs=new TreeSet<>();for(JSONObject c:courses)cutoffs.add(Planner.day(c.getDouble("deadline")));
        for(LocalDate cutoff:cutoffs){int required=0,absent=0,capacity=0;JSONArray names=new JSONArray();List<JSONObject> group=new ArrayList<>();
            for(JSONObject c:courses)if(!Planner.day(c.getDouble("deadline")).isAfter(cutoff)){group.add(c);required+=Planner.remaining(state,c);int n=missing.getInt(c.getString("id"));absent+=n;if(n>0)names.put(c.getString("name"));}
            if(absent==0)continue;
            for(JSONObject d:Planner.list(plans)){LocalDate day=Planner.day(d.getDouble("date"));if(day.isAfter(cutoff))continue;for(JSONObject c:group)if(Planner.eligible(c,day)){capacity+=d.optInt("availableMinutes");break;}}
            risks.put(new JSONObject().put("deadline",Planner.at(cutoff,0)).put("requiredMinutes",required).put("availableMinutes",capacity).put("unscheduledMinutes",absent).put("courseNames",names));
        }
        for(JSONObject conflict:Planner.list(ScheduleHealth.array(preview,"androidConflicts"))){boolean relevant=false;JSONArray names=conflict.optJSONArray("courseNames");if(names!=null)for(int i=0;i<names.length();i++)if(missingNames.contains(names.getString(i)))relevant=true;if(relevant)conflicts.put(conflict);}
        state.put("androidMissing",missing).put("androidWarnings",warnings).put("androidDayPlans",plans).put("androidRisks",risks).put("androidConflicts",conflicts).put("androidAdjustments",new JSONArray());
    }
}
