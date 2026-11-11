package local.studyplanner;

import android.app.Dialog;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.time.LocalDate;
import java.util.*;

/** Native, scrollable counterpart of the Mac course/load/recovery inspector. */
final class ScheduleHealthPanel {
    final MainActivity app;
    final JSONObject state;
    final double now;
    final ScheduleHealthPresentation presentation;
    final Dialog dialog;
    final LinearLayout content;
    final ScrollView scroll;
    final Button[] tabs=new Button[3];
    boolean showAllDays;

    ScheduleHealthPanel(MainActivity app)throws Exception{
        this.app=app;state=CourseTools.copy(app.state);now=Planner.now();
        presentation=new ScheduleHealthPresentation(state,ScheduleHealth.assess(state,now,app.consequences.warning()),app.consequences.warning());
        dialog=new Dialog(app);dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout root=app.col();root.setPadding(app.dp(16),app.dp(8),app.dp(16),app.dp(8));root.setBackgroundColor(app.bg);
        PlannerUi.Flow navigation=new PlannerUi.Flow(app);root.addView(navigation);
        String[] labels={"课程安排","每日负担","补学安排"};
        for(int i=0;i<labels.length;i++){final int section=i;tabs[i]=app.pill(labels[i],()->app.run(()->render(section)));navigation.addView(tabs[i]);}
        scroll=new ScrollView(app);scroll.setFillViewport(true);content=app.col();scroll.addView(content);root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        PlannerUi.Flow actions=new PlannerUi.Flow(app);root.addView(actions);
        actions.addView(app.pill("调整可学习时间",()->{dialog.dismiss();app.page=3;app.settingsSection="availability";app.render();}));
        actions.addView(app.pill("知道了",dialog::dismiss));dialog.setContentView(root);render(0);
    }
    void show(){dialog.show();Window window=dialog.getWindow();if(window!=null)window.setLayout(-1,-1);}
    void render(int section)throws Exception{
        content.removeAllViews();for(int i=0;i<tabs.length;i++){
            boolean selected=i==section;tabs[i].setSelected(selected);
            tabs[i].setTextColor(selected?0xff126346:app.ink);
            tabs[i].setTypeface(null,selected?android.graphics.Typeface.BOLD:android.graphics.Typeface.NORMAL);
            tabs[i].setBackground(app.rounded(selected?0xffc5efd7:0xffedf2ef,20));
        }
        content.addView(app.title(section==2?"未完成的内容，接下来怎么学":presentation.health.optLong("remainingMinutes")>0?presentation.title():"学习安排检查"));
        if(section==2)note(content,"这里查看今天确认任务后，仍需补学的内容及其安排。");
        else if(presentation.health.optLong("remainingMinutes")>0)StudyTimeBar.overview(app,content,presentation);
        else note(content,"当前没有待排课程，可在下方检查事项安排。");
        if(section==0)courses();else if(section==1)load();else recovery();scroll.scrollTo(0,0);
    }
    void note(LinearLayout parent,String text){parent.addView(app.text(text,15,app.muted));}
    void courses()throws Exception{
        if(presentation.health.optLong("remainingMinutes")>0)note(content,presentation.guidance());
        List<ScheduleHealthPresentation.CourseAttention> rows=ScheduleHealthPresentation.courses(state,now);
        if(!rows.isEmpty())content.addView(app.title("需要检查的课程"));
        for(ScheduleHealthPresentation.CourseAttention item:rows){
            JSONObject course=item.course;LinearLayout box=app.card(content);app.cardBorder(box,app.color(course.optString("color")));
            box.addView(app.title(course.optString("name")));note(box,"截止日期："+Planner.date(course.optDouble("deadline")));
            StudyTimeBar.add(app,box,"还需学习",ScheduleHealthPresentation.duration(item.remainingMinutes),"已安排",item.plannedMinutes,"未安排",item.unplacedMinutes,0,0);
            note(box,!course.optBoolean("autoScheduleEnabled",true)?"这门课已暂停自动排程。恢复自动排程后再核对课表。":
                "不定时录播课程".equals(course.optString("type"))?"这门课按整节安排。请先检查课节时长和顺序，并为整节课留出连续学习时段。":"请检查课程设置及截止日期前的可学习时段，必要时增加学习时间。");
            box.addView(app.pill("查看课程与课节",()->{
                JSONObject current=Planner.course(app.state,course.optString("id"));
                if(current==null){app.alert("课程已变化","该课程已删除，请重新打开安排检查。");return;}
                dialog.dismiss();app.courseEditor(current);
            }));
        }
        List<JSONObject> conflicts=Planner.list(ScheduleHealth.array(state,"androidConflicts"));
        if(!conflicts.isEmpty())content.addView(app.title("已确认的时间冲突"));
        for(JSONObject proof:conflicts){
            LinearLayout box=app.card(content);app.cardBorder(box,0xffbd3333);
            box.addView(app.text("截至 "+Planner.date(proof.optDouble("deadline")),17,0xffbd3333));
            if(proof.optJSONObject("restConflict")!=null){
                note(box,"核对范围："+Planner.date(proof.optDouble("windowStart"))+"起。"+ScheduleRestConflict.explanation(proof.optJSONObject("restConflict")));
                note(box,ScheduleRestConflict.recovery());
                box.addView(app.pill("查看此日事项与空档",()->openDay(proof.optDouble("windowStart"))));
            }else if(proof.has("minimumContinuousMinutes")){
                long needed=proof.optLong("minimumContinuousMinutes"),available=proof.optLong("availableMinutes");
                StudyTimeBar.add(app,box,"需要连续时间",ScheduleHealthPresentation.duration(needed),"最长连续空档",available,"空档差额",Math.max(0,needed-available),0,0);
            }else{
                note(box,"核对范围："+Planner.date(proof.optDouble("windowStart"))+"起。可用时间暂未扣除浮动事项和课间休息。");
                StudyTimeBar.add(app,box,"需要学习时间",ScheduleHealthPresentation.duration(proof.optLong("requiredMinutes")),
                    "最多可用",proof.optLong("availableMinutes"),"至少缺少",proof.optLong("provenDeficit"),0,0);
            }
            note(box,"涉及课程："+DailyConsequencesView.names(proof.optJSONArray("courseNames")));
        }
        JSONArray warnings=ScheduleHealth.array(state,"androidWarnings");
        if(warnings.length()>0){content.addView(app.title("其他需要检查的情况"));for(int i=0;i<warnings.length();i++)note(content,warnings.optString(i));}
        JSONArray adjustments=ScheduleHealth.array(state,"androidAdjustments");
        if(adjustments.length()>0){
            LinearLayout details=app.col();details.setVisibility(View.GONE);
            content.addView(app.pill("本次排程做了哪些调整",()->details.setVisibility(details.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE)));
            for(int i=0;i<adjustments.length();i++)note(details,adjustments.optString(i));content.addView(details);
        }
        note(content,"截止日期保持不变。每张课程卡片只统计该课程，不重复累计其他课程的时间。");
    }
    void load(){
        content.addView(app.text(presentation.loadSummary(),16,app.ink));
        note(content,"条形图只统计已安排的学习时间，不含课间休息和未排入的内容。青绿色为提醒线内，橙色为超出部分；超出不代表当天排不下。各天使用同一刻度，竖线标出每日提醒线。");
        note(content,"每日提醒线："+ScheduleHealthPresentation.duration(presentation.warningMinutes));
        if(!presentation.heavyDays.isEmpty()){
            CheckBox toggle=new CheckBox(app);toggle.setText("显示全部 "+presentation.days.size()+" 天");toggle.setTextColor(app.ink);toggle.setChecked(showAllDays);
            toggle.setOnCheckedChangeListener((button,checked)->{showAllDays=checked;app.run(()->render(1));});content.addView(toggle);
        }
        List<JSONObject> days=showAllDays||presentation.heavyDays.isEmpty()?presentation.days:presentation.heavyDays;
        LinearLayout rows=app.col();content.addView(rows);
        Button more=app.pill("",()->{});int[] count={0};
        Runnable append=()->{
            int end=Math.min(days.size(),count[0]+30);
            for(;count[0]<end;count[0]++){
                JSONObject day=days.get(count[0]);LinearLayout box=app.card(rows);
                StudyTimeBar.daily(app,box,day,presentation,Planner.date(day.optDouble("date")));
            }
            more.setText("继续显示（还有 "+(days.size()-count[0])+" 天）");more.setVisibility(count[0]<days.size()?View.VISIBLE:View.GONE);
        };
        more.setOnClickListener(v->{if(!app.busy)append.run();});content.addView(more);append.run();
        note(content,"调高提醒线只会减少提醒，不会增加可用时间；课间仍保留 "+Planner.BREAK_MINUTES+" 分钟休息。");
    }
    void recovery(){
        long unplaced=presentation.health.optLong("recoveryUnscheduledMinutes");
        if(presentation.recoveryRemainingMinutes>0)StudyTimeBar.add(app,content,"这批内容仍需补学",ScheduleHealthPresentation.duration(presentation.recoveryRemainingMinutes),
            "已排入课表",presentation.recoveryScheduledMinutes,"还未排入",unplaced,0,0);
        content.addView(app.text(presentation.recoverySummary(),16,app.ink));
        if(unplaced>0)content.addView(app.pill("查看未排入的课程",()->app.run(()->render(0))));
        Map<LocalDate,List<JSONObject>> byDay=new TreeMap<>();
        for(JSONObject item:Planner.list(ScheduleHealth.array(presentation.health,"recoveryItems")))byDay.computeIfAbsent(Planner.day(item.optDouble("start")),k->new ArrayList<>()).add(item);
        if(!byDay.isEmpty())note(content,"按下面日期的课表学习即可，无需额外加时。");
        for(JSONObject day:Planner.list(ScheduleHealth.array(presentation.health,"recovery"))){
            double date=day.optDouble("date");LinearLayout box=app.card(content);
            box.addView(app.text((Planner.day(date).equals(Planner.day(now))?"今天 · ":"")+Planner.date(date)+" · 补学 "+ScheduleHealthPresentation.duration(day.optLong("plannedMinutes")),17,app.ink));
            for(JSONObject item:byDay.getOrDefault(Planner.day(date),Collections.emptyList())){
                JSONObject course=Planner.course(state,item.optString("courseID"));String lesson=item.optString("lessonName","");
                box.addView(app.text(Planner.clock(item.optDouble("start"))+" · "+(course==null?"课程":course.optString("name"))+"\n"+
                    (lesson.isEmpty()?"学习任务":lesson)+" · 补学 "+ScheduleHealthPresentation.duration(item.optLong("minutes")),15,app.ink));
            }
            box.addView(app.pill("查看当天课表",()->openDay(date)));
        }
        LinearLayout explanation=app.col();explanation.setVisibility(View.GONE);
        content.addView(app.pill("这里的补学时间是怎么算的？",()->explanation.setVisibility(explanation.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE)));
        note(explanation,"统计今天确认时未完成或只完成一部分的内容，再扣除后来已经学完的部分。同一课节的重复确认不会重复累计。确认的任务可能原本排在不同日期，所以不把确认记录的原计划时长当作今天的学习目标。");content.addView(explanation);
    }
    void openDay(double date){dialog.dismiss();app.selected=Planner.day(date);app.month=app.selected.withDayOfMonth(1);app.page=0;app.render();}
}
