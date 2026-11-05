package local.studyplanner;

import org.json.*;
import java.time.*;
import java.util.*;

/** Same request format as Swift; an explicit start reserves time, never credits progress. */
final class ImmediateStudy {
    static final String NO_SPACE="当前空档不足，请检查可学习时段、固定事项和已确认学习后的15分钟休息；原课表已保留。";
    static JSONObject request(JSONObject state){return state.optJSONObject("settings").optJSONObject("immediateStudy");}
    static JSONObject first(JSONObject state,LocalDate day){
        JSONObject first=null;
        for(JSONObject task:Planner.list(state.optJSONArray("tasks")))if(Planner.pending(task)&&Planner.day(task.optDouble("start")).equals(day)){
            JSONObject course=Planner.course(state,task.optString("courseID"));
            if(course!=null&&!course.optBoolean("isArchived")&&(first==null||task.optDouble("start")<first.optDouble("start")))first=task;
        }
        return first;
    }
    static int remaining(JSONObject state,JSONObject task){
        JSONObject course=Planner.course(state,task.optString("courseID"));
        if(course==null||course.optBoolean("isArchived")||!course.optBoolean("autoScheduleEnabled",true))return 0;
        List<Planner.Work> lessons=Planner.lessonWorkAll(state,course);int sum=0;for(Planner.Work work:lessons)sum+=work.minutes;
        boolean consistent=!lessons.isEmpty()&&sum==Planner.remaining(state,course);
        if(Planner.hasLessonID(task)){if(consistent)for(Planner.Work work:lessons)if(work.lessonID.equals(task.optString("lessonID")))return work.minutes;return 0;}
        return consistent?0:Planner.remaining(state,course);
    }
    static JSONObject continuation(JSONObject state,double now){
        JSONObject request=request(state);if(request==null||!request.optBoolean("continuesLesson"))return null;
        JSONObject task=request.optJSONObject("task");if(task==null||remaining(state,task)<=0)return null;
        JSONObject course=Planner.course(state,task.optString("courseID"));
        return Planner.eligible(course,Planner.day(now))?task:null;
    }
    static JSONObject reservation(JSONObject task)throws Exception{
        LocalDate day=Planner.day(task.getDouble("start"));
        int start=(int)((task.getDouble("start")-Planner.at(day,0))/60);
        int end=start+task.getInt("durationMinutes");
        if(start<0||end>1440||start>=end||Planner.at(day,start)!=task.getDouble("start")||Planner.at(day,end)!=Planner.end(task))return null;
        return new JSONObject().put("id",Planner.stableID("immediate-reservation|"+task.getString("id")))
            .put("title","立即学习").put("startMinute",start).put("endMinute",end)
            .put("startDate",Planner.at(day,0)).put("endDate",Planner.at(day,0)).put("weekdays",new JSONArray()).put("excludedDates",new JSONArray());
    }
    static List<Planner.Span> free(JSONObject state,LocalDate day)throws Exception{
        List<Planner.Span> windows=new ArrayList<>(),blocks=new ArrayList<>();
        for(JSONObject w:Planner.list(state.getJSONObject("settings").getJSONArray("availability")))if(w.getInt("weekday")==Planner.weekday(day))
            windows.add(new Planner.Span(Planner.at(day,w.getInt("startMinute")),Planner.at(day,w.getInt("endMinute"))));
        for(JSONObject e:Planner.list(state.getJSONArray("fixedEvents")))if(!Planner.floating(e)&&Planner.occurs(e,day))
            blocks.add(new Planner.Span(Planner.at(day,e.getInt("startMinute")),Planner.at(day,e.getInt("endMinute"))));
        return Planner.subtract(windows,blocks);
    }
    static JSONObject valid(JSONObject state,double now)throws Exception{
        JSONObject request=request(state),task=request==null?null:request.optJSONObject("task");if(task==null)return null;
        Planner.validateTaskData(task);
        int minutes=task.getInt("durationMinutes");double start=task.getDouble("start"),end=Planner.end(task);LocalDate day=Planner.day(start);
        if(!Planner.pending(task)||minutes<1||minutes>1440||end<=now||start-now>=60||!day.equals(Planner.day(now))||end>Planner.at(day.plusDays(1),0)||remaining(state,task)<minutes)return null;
        JSONObject course=Planner.course(state,task.getString("courseID"));if(!Planner.eligible(course,day))return null;
        Double anchor=Planner.actualStudyStart(state,now);if(anchor!=null&&start<anchor)return null;
        for(JSONObject old:Planner.list(state.getJSONArray("tasks"))){
            if(old.optString("id").equals(task.getString("id"))){if(!Planner.pending(old))return null;continue;}
            if(Planner.planningStart(old)<now&&((Planner.pending(old)&&Planner.planningEnd(old)<=now&&!(anchor!=null&&Planner.day(old.optDouble("start")).equals(day)))||old.optInt("completedMinutes")>0))
                if(start<Planner.retainedHistoryEnd(old)+Planner.BREAK_SECONDS&&end>Planner.retainedHistoryStart(old)-Planner.BREAK_SECONDS)return null;
        }
        boolean fits=false;for(Planner.Span span:free(state,day))if(start>=span.a&&end<=span.b)fits=true;if(!fits)return null;
        List<JSONObject> events=new ArrayList<>();boolean floating=false;
        for(JSONObject event:Planner.list(state.getJSONArray("fixedEvents")))if(Planner.occurs(event,day)){events.add(event);floating|=Planner.floating(event);}
        if(floating){
            JSONObject pin=reservation(task);List<JSONObject> withPin=new ArrayList<>(events);if(pin!=null)withPin.add(pin);
            if(pin==null||Planner.reserveResult(withPin,new boolean[1440],Planner.RESERVATION_ATTEMPT_LIMIT).placements==null){
                List<Planner.Span> exact=new ArrayList<>();exact.add(new Planner.Span(start,end));
                List<ScheduleFeasibilitySearch.Floating> floats=new ArrayList<>();
                for(JSONObject event:events)if(Planner.floating(event))floats.add(new ScheduleFeasibilitySearch.Floating(day,event));
                else exact.add(new Planner.Span(Planner.at(day,event.getInt("startMinute")),Planner.at(day,event.getInt("endMinute"))));
                List<Planner.Day> available=Collections.singletonList(new Planner.Day(day,Planner.subtract(Collections.singletonList(new Planner.Span(Planner.at(day,0),Planner.at(day.plusDays(1),0))),exact)));
                int beginning=ScheduleFeasibilitySearch.minute(Planner.at(day,0));
                ScheduleFeasibilitySearch.Solution solution=ScheduleFeasibilitySearch.find(Collections.singletonList(new ScheduleFeasibilitySearch.Queue(course,Collections.emptyList())),ScheduleFeasibilitySearch.windows(available),ScheduleFeasibilitySearch.windows(available),floats,beginning,beginning);
                if(solution==null||solution.floatingStarts.size()!=floats.size())return null;
            }
        }
        return task;
    }
    static void startLesson(JSONObject state,String courseID,String lessonID,double now)throws Exception{
        JSONObject course=Planner.course(state,courseID);if(course==null||course.optBoolean("isArchived")||!course.optBoolean("autoScheduleEnabled",true))throw new IllegalArgumentException("请选择已启用自动排课的分节课程。");
        for(Planner.Work work:Planner.lessonWork(state,course))if(work.lessonID.equals(lessonID)){start(state,course,work,work.minutes,true,now);return;}
        throw new IllegalArgumentException("课节已完成或已有变化，请重新选择。");
    }
    static void resume(JSONObject state,LocalDate selected,String reviewedID,double now)throws Exception{
        JSONObject task=first(state,selected);
        if(selected.isBefore(Planner.day(now))||task==null||!task.optString("id").equals(reviewedID)||remaining(state,task)<task.optInt("durationMinutes"))throw new IllegalArgumentException("最上方未确认课程已变化，请刷新后重新核对。");
        start(state,Planner.course(state,task.getString("courseID")),new Planner.Work(remaining(state,task),task.optString("lessonID",null),task.optString("lessonName",null)),task.getInt("durationMinutes"),false,now);
    }
    private static void start(JSONObject state,JSONObject course,Planner.Work work,int requested,boolean shorten,double now)throws Exception{
        double start=Math.ceil(now/60)*60;LocalDate day=Planner.day(start);
        if(!Planner.eligible(course,day))throw new IllegalArgumentException("现在不在课程的开始与截止日期内。");
        JSONObject next=CourseTools.copy(state);Planner.recordActualStudyStart(next,Math.min(1439,(int)((start-Planner.at(day,0))/60)),start);
        next.getJSONObject("settings").put("actualStudyStart",start);
        int maximum=0;for(Planner.Span span:free(next,day))if(span.a<=start&&start<span.b)maximum=Math.min(1440,Math.min(requested,(int)((span.b-start)/60)));
        if(maximum<=0||!shorten&&maximum!=requested)throw new IllegalArgumentException(NO_SPACE);
        JSONObject task=Planner.task(course.getString("id"),start,new Planner.Work(maximum,work.lessonID,work.lessonName));task.put("status","planned");
        JSONObject request=new JSONObject().put("task",task);next.getJSONObject("settings").put("immediateStudy",request);
        if(valid(next,now)==null){
            if(!shorten)throw new IllegalArgumentException(NO_SPACE);
            int low=1,high=maximum-1,best=0;
            while(low<=high){int middle=(low+high)/2;task.put("durationMinutes",middle);if(valid(next,now)!=null){best=middle;low=middle+1;}else high=middle-1;}
            if(best==0)throw new IllegalArgumentException(NO_SPACE);task.put("durationMinutes",best);
        }
        if(work.lessonID!=null&&task.getInt("durationMinutes")<work.minutes)request.put("continuesLesson",true);
        Planner.replan(next,now);
        boolean found=false;for(JSONObject planned:Planner.list(next.getJSONArray("tasks")))if(planned.optString("id").equals(task.getString("id")))found=true;
        if(!found)throw new IllegalArgumentException(NO_SPACE);
        Iterator<String> keys=next.keys();while(keys.hasNext()){String key=keys.next();state.put(key,next.get(key));}
    }
    static void prioritize(JSONObject state,JSONObject continuation)throws Exception{
        if(continuation==null)return;JSONObject course=Planner.course(state,continuation.getString("courseID"));
        List<String> order=new ArrayList<>();order.add(continuation.getString("lessonID"));
        for(String id:CourseTools.order(course))if(!order.contains(id))order.add(id);course.put("lessonOrder",new JSONArray(order));
    }
    static void removeOrders(JSONObject state,List<JSONObject> tasks,JSONObject pin,JSONObject continuation)throws Exception{
        JSONArray old=state.getJSONObject("settings").optJSONArray("dailyTaskOrders");if(old==null)return;
        Set<LocalDate> days=new HashSet<>();if(pin!=null)days.add(Planner.day(pin.getDouble("start")));
        if(continuation!=null)for(JSONObject task:tasks)if(task.optString("courseID").equals(continuation.optString("courseID"))&&task.optString("lessonID").equals(continuation.optString("lessonID")))days.add(Planner.day(task.optDouble("start")));
        JSONArray orders=new JSONArray();for(JSONObject row:Planner.list(old))if(!days.contains(Planner.day(row.getDouble("day"))))orders.put(row);
        state.getJSONObject("settings").put("dailyTaskOrders",orders);
    }
}
