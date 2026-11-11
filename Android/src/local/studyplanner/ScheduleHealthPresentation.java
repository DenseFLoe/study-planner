package local.studyplanner;

import org.json.*;
import java.util.*;

/** Read-only display model. Course totals never sum overlapping deadline risk groups. */
final class ScheduleHealthPresentation {
    final JSONObject health;
    final int warningMinutes;
    final List<JSONObject> days=new ArrayList<>(),heavyDays=new ArrayList<>();
    JSONObject peak;
    final long recoveryScheduledMinutes,recoveryRemainingMinutes;

    ScheduleHealthPresentation(JSONObject state,JSONObject health,int warning){
        this.health=health;warningMinutes=Math.max(30,warning);
        for(JSONObject day:Planner.list(ScheduleHealth.array(state,"androidDayPlans")))if(day.optInt("plannedMinutes")>0){
            days.add(day);if(day.optInt("plannedMinutes")>warningMinutes)heavyDays.add(day);
            if(peak==null||day.optInt("plannedMinutes")>peak.optInt("plannedMinutes"))peak=day;
        }
        days.sort(Comparator.comparingDouble(d->d.optDouble("date")));
        heavyDays.sort(Comparator.comparingDouble(d->d.optDouble("date")));
        long scheduled=0;for(JSONObject day:Planner.list(ScheduleHealth.array(health,"recovery")))scheduled+=day.optLong("plannedMinutes");
        recoveryScheduledMinutes=scheduled;recoveryRemainingMinutes=scheduled+health.optLong("recoveryUnscheduledMinutes");
    }

    static final class CourseAttention {
        final JSONObject course;
        final long remainingMinutes,plannedMinutes,unplacedMinutes;
        CourseAttention(JSONObject course,long remaining,long planned){
            this.course=course;remainingMinutes=remaining;plannedMinutes=planned;unplacedMinutes=remaining-planned;
        }
    }
    static List<CourseAttention> courses(JSONObject state,double now)throws Exception{
        Map<String,Long> planned=new HashMap<>();
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(task)&&Planner.planningEnd(task)>now)
            planned.merge(task.optString("courseID"),task.optLong("durationMinutes"),Long::sum);
        List<CourseAttention> rows=new ArrayList<>();
        for(JSONObject course:Planner.list(state.getJSONArray("courses"))){
            if(course.optBoolean("isArchived"))continue;
            long remaining=Planner.remaining(state,course);if(remaining<=0)continue;
            long placed=course.optBoolean("autoScheduleEnabled",true)?Math.min(remaining,planned.getOrDefault(course.optString("id"),0L)):0;
            if(placed<remaining)rows.add(new CourseAttention(course,remaining,placed));
        }
        rows.sort(Comparator.comparingDouble(row->row.course.optDouble("deadline")));return rows;
    }
    long plannedMinutes(){return Math.max(0,health.optLong("remainingMinutes")-health.optLong("unplacedMinutes")-health.optLong("pausedMinutes"));}
    int dailyScale(){return Math.max(warningMinutes,peak==null?0:peak.optInt("plannedMinutes"));}
    String title(){switch(health.optString("kind")){
        case "heavy":return "课程已排完，部分日期负担偏重";
        case "pending":return "课程安排还需要检查";
        case "shortage":return "现有学习时间无法满足安排要求";
        default:return "剩余课程已全部安排";
    }}
    String guidance(){switch(health.optString("kind")){
        case "heavy":return "截止日期保持不变。建议先检查负担较重的日期，再调整可学习时段。";
        case "pending":return health.optLong("unplacedMinutes")>0?"这表示课表还不完整，并不代表一定来不及学完。先检查下方课程，再调整可学习时段。":"请检查暂停排程的课程或下方提示，再重新核对安排。";
        case "shortage":return "已有明确的时间冲突，请按下方原因调整可学习时段、事项或课节安排。";
        default:return "当前课表已覆盖剩余内容，截止日期保持不变。";
    }}
    String loadSummary(){
        if(peak==null)return "目前没有已排入的学习任务，暂时无法评估每日负担。";
        String prefix=heavyDays.isEmpty()?"已安排的 "+days.size()+" 天均未超过每天 ":"已安排的日程中，有 "+heavyDays.size()+" 天超过每天 ";
        return prefix+duration(warningMinutes)+"的提醒线。最重的是 "+Planner.date(peak.optDouble("date"))+"，安排了 "+duration(peak.optLong("plannedMinutes"))+"。";
    }
    String recoverySummary(){
        if(recoveryRemainingMinutes==0)return "今天确认过的内容中，目前没有仍需补学的部分。";
        if(recoveryScheduledMinutes==0)return "这批内容还有 "+duration(recoveryRemainingMinutes)+"需要补学，目前尚未排入课表。请到“课程安排”检查原因。";
        String text=duration(recoveryScheduledMinutes)+"已排到下面 "+ScheduleHealth.array(health,"recovery").length()+" 个日期，已包含在每日学习量中，按当天课表学习即可。";
        return health.optLong("recoveryUnscheduledMinutes")==0?text:text+"另外 "+duration(health.optLong("recoveryUnscheduledMinutes"))+"还未排入，可到“课程安排”检查原因。";
    }
    static String duration(long minutes){
        long n=Math.max(0,minutes);if(n<60)return n+" 分钟";
        return n/60+" 小时"+(n%60==0?"":" "+n%60+" 分");
    }
}
