package local.studyplanner;

import android.app.AlertDialog;
import android.animation.ValueAnimator;
import android.widget.*;
import org.json.*;
import java.util.*;

/** Native cards for the dedicated learning tab. */
final class DailyConsequencesView {
    final MainActivity app;final DailyConsequenceController controller;
    DailyConsequencesView(MainActivity app){this.app=app;controller=app.consequences;}
    void render(LinearLayout panel){
        if(panel==null)return;panel.removeAllViews();
        try{content(panel);}catch(Exception e){panel.addView(app.text("预报暂时无法显示，请稍后重试。",15,app.muted));}
    }
    void content(LinearLayout panel)throws Exception{
        LinearLayout box=app.card(panel);box.addView(app.title("昨日结果 · 今日后果预报"));
        JSONObject past=controller.yesterday;
        if(past==null)box.addView(app.text("尚无昨日预报记录，从今天开始保留每日对照。",15,app.muted));
        else{
            box.addView(app.text("昨日 "+Planner.date(past.optDouble("date"))+" · 已确认 "+duration(past.optInt("confirmedMinutes"))+" / 目标 "+duration(past.optInt("goalMinutes")),15,app.ink));
            box.addView(app.text(past.optBoolean("isReviewed")?"✓ 昨日已核对":"昨日尚未全部核对；未确认记录不会直接算作没学。",15,past.optBoolean("isReviewed")?0xff126346:0xff874b00));
            if(past.has("outcome"))box.addView(app.text("按昨日已确认学习量推算："+outcome(past.getJSONObject("outcome")),15,app.ink));
            else box.addView(app.text("课程或原有进度已变化，昨日预报需重新核对。",15,app.muted));
            if(past.optBoolean("usesLegacyDates"))box.addView(app.text("部分旧记录按确认日期汇总，补录请核对实际日期。",15,app.muted));
            if(past.optInt("ambiguousRecords")>0)box.addView(app.text("有 "+past.optInt("ambiguousRecords")+" 条记录缺少明确的学习日期，暂不作最终结论。",15,app.muted));
            if(!past.optBoolean("isReviewed")){box.addView(app.pill("核对待确认任务",app::review));
                if(!past.optBoolean("pending")&&past.optInt("ambiguousRecords")==0)box.addView(app.pill("昨日已核对，没有其他学习",controller::markYesterdayReviewed));}
        }
        JSONObject day=controller.today;
        if(day==null)box.addView(app.text(controller.calculating?"正在准备今日预报…":"今日预报尚未就绪。",15,app.muted));
        else{
            box.addView(app.title("今天 "+Planner.date(day.optDouble("date"))));
            box.addView(app.text("已确认有效学习 "+duration(controller.confirmed)+" / 今日目标 "+duration(day.optInt("goalMinutes")),16,app.ink));
            box.addView(app.text("确认学习不会降低今日目标；课程或可学时段变更时更新预报。各档同时展示，无需选择。",15,app.muted));
            boolean legacy=false;for(JSONObject r:Planner.list(app.state.getJSONArray("completions")))if(!r.has("studyDate")&&Planner.day(day.optDouble("date")).equals(DailyConsequences.effectiveDay(r,app.state)))legacy=true;
            if(legacy)box.addView(app.text("部分旧记录按确认日期汇总，补录请核对实际日期。",15,app.muted));
            if(day.optInt("goalMinutes")==0)box.addView(app.text("今天没有待执行的学习目标，请同时留意实时排程预警。",15,app.muted));
            else{
                for(int fraction:DailyConsequences.fractions(day))scenario(box,day,fraction);
                if(controller.calculating)box.addView(app.text("正在核算各档后果…",15,app.muted));
                box.addView(app.text("推演假设之后每天也只完成当天预排量的同一比例，最多查看未来90天；未找到排法不当作无解。达标表示今天已超过这一档少学量，整体压力仍以实时预警为准。",15,app.muted));
            }
        }
        if(controller.message!=null){box.addView(app.text(controller.message,15,0xff874b00));box.addView(app.pill("重新核算",()->{controller.lastState=null;app.render();}));}
    }
    void scenario(LinearLayout parent,JSONObject day,int fraction)throws Exception{
        boolean passed=DailyConsequences.achieved(day,fraction,controller.confirmed);LinearLayout row=app.card(parent);
        row.setBackground(app.rounded(passed?0xffe8f5ed:0xfff7f7f7,12));
        String title=fraction==0?"今天完全不学":fraction==1000?"今天完成全部计划":"今天只完成 "+fraction/10+"% · "+duration(DailyConsequences.target(day,fraction));
        row.addView(app.text((passed?"✓ ":"↳ ")+title,16,app.ink));
        row.addView(app.text(passed?(fraction==1000?"今日目标已完成":"已超过这一档少学量 · 已避开"):"再确认 "+duration(Math.max(0,DailyConsequences.threshold(day,fraction)-controller.confirmed))+(fraction==1000?"，达到今日目标":"，超过这一档"),15,passed?0xff126346:app.muted));
        JSONObject forecast=null;for(JSONObject f:Planner.list(day.getJSONArray("forecasts")))if(f.optInt("fraction")==fraction)forecast=f;
        if(forecast!=null&&forecast.has("firstDay")){
            String details=outcome(forecast.getJSONObject("firstDay"))+"\n"+pressure(forecast)+"\n"+limit(forecast);
            if(passed)row.addView(app.pill(fraction==1000?"查看达标后的预排":"查看这一档原先的后果",()->new AlertDialog.Builder(app).setTitle(title).setMessage(details).setPositiveButton("关闭",null).show()));
            else row.addView(app.text("若今天停在这一档，明日起：\n"+details,15,app.muted));
        }else if(forecast!=null&&forecast.has("unavailableTodayMinutes")&&!passed)row.addView(app.text("按当前今日课表，这档还差 "+duration(forecast.optInt("unavailableTodayMinutes"))+" 没有可执行安排，暂不把它当成能达成的假设。",15,0xff874b00));
        else if(!passed)row.addView(app.text("正在推算，不先给出未经核算的天数。",15,app.muted));
        else if(forecast!=null&&forecast.optInt("evaluatedDays")==0)row.addView(app.text("已用实际确认进度超过这一档，不撤回已确认学习量反算后果。",15,app.muted));
        if(passed&&controller.celebrations.remove(fraction)&&ValueAnimator.areAnimatorsEnabled()){
            row.setAlpha(.4f);row.animate().alpha(1).setDuration(800).start();
        }
    }
    String duration(int minutes){return minutes<60?minutes+" 分钟":app.hours(minutes);}
    String outcome(JSONObject value){switch(value.optString("kind")){
        case "heavy":return "能排入，但有 "+value.optInt("heavyDays")+" 天超出负担提醒线；最重一天 "+duration(value.optInt("peakMinutes"))+"。";
        case "pending":return "暂未排入 "+duration(value.optInt("unplacedMinutes"))+"，完整排法仍待确认。";
        case "shortage":return value.has("provenDeficit")?"已证实至少缺少 "+duration(value.optInt("provenDeficit"))+"；涉及 "+names(value.optJSONArray("courseNames"))+"。":"已证实缺少能放下 "+value.optInt("minimumContinuousMinutes")+" 分钟内容的连续空档。";
        default:return "仍可按期排入；后续最重一天 "+duration(value.optInt("peakMinutes"))+"。";
    }}
    static String names(JSONArray a){StringJoiner out=new StringJoiner("、");if(a!=null)for(int i=0;i<a.length();i++)out.add(a.optString(i));return out.toString();}
    String pressure(JSONObject f){if(f.has("pressureAfterDays")){int n=f.optInt("pressureAfterDays");return n==0?"压力线：当前预排已超过提醒线。":"若每天都按此比例完成，预排约第 "+n+" 天触及压力线。";}
        return f.has("uncertainFromDay")||f.has("provenLimitAfterDays")?"课表存在未确定或已冲突内容，暂不给出安全的压力缓冲天数。":"本次推演的 "+f.optInt("evaluatedDays")+" 天内，未发现新增超负担日期。";}
    String limit(JSONObject f){if(f.has("provenLimitAfterDays")){int n=f.optInt("provenLimitAfterDays");if(f.has("uncertainFromDay")&&f.optInt("uncertainFromDay")<n)return "极限：第 "+f.optInt("uncertainFromDay")+" 天起排法待复核，最迟第 "+n+" 天已证实存在约束冲突。";
        return n==0?"极限：当前已确认存在约束冲突。":"若每天都按此比例完成，第 "+n+" 天已能证实存在约束冲突。";}
        return f.has("uncertainFromDay")?"极限：第 "+f.optInt("uncertainFromDay")+" 天起排法尚未确定，不能断言已超限。":"在本次 "+f.optInt("evaluatedDays")+" 天推演内，未证实硬上限不足。";}
}
