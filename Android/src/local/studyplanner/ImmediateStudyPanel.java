package local.studyplanner;

import android.app.AlertDialog;
import android.widget.*;
import org.json.*;
import java.time.*;
import java.util.*;

final class ImmediateStudyPanel {
    static void controls(MainActivity app,PlannerUi.Flow actions){
        actions.addView(app.primaryButton("立即学习",()->chooseCourse(app)));
        LocalDate day=app.selected;JSONObject first=ImmediateStudy.first(app.state,day);
        Button resume=app.button("继续上课",()->{if(first!=null)app.mutate(s->ImmediateStudy.resume(s,day,first.optString("id"),Planner.now()),false,()->today(app));});
        resume.setEnabled(first!=null&&!day.isBefore(LocalDate.now(Planner.ZONE)));actions.addView(resume);
    }
    static void today(MainActivity app){app.selected=LocalDate.now(Planner.ZONE);app.month=app.selected.withDayOfMonth(1);}
    static void chooseCourse(MainActivity app){
        BackupPanel.load(app,()->{
            JSONObject state=app.database.load();List<JSONObject> courses=new ArrayList<>();
            for(JSONObject course:Planner.list(state.getJSONArray("courses")))if(!course.optBoolean("isArchived")&&course.optBoolean("autoScheduleEnabled",true)&&!Planner.lessonWork(state,course).isEmpty())courses.add(course);
            return courses;
        },courses->{
            if(courses.isEmpty()){app.alert("立即学习","暂无可立即学习的未完成分节课程。");return;}
            String[] names=new String[courses.size()];for(int i=0;i<names.length;i++)names[i]=courses.get(i).optString("name");
            new AlertDialog.Builder(app).setTitle("选择课程").setItems(names,(d,index)->chooseLesson(app,courses.get(index))).setNegativeButton("取消",null).show();
        });
    }
    static void chooseLesson(MainActivity app,JSONObject course){
        BackupPanel.load(app,()->{JSONObject state=app.database.load(),current=Planner.course(state,course.optString("id"));if(current==null)throw new IllegalArgumentException("课程已删除，请重新选择。");return Planner.lessonWork(state,current);},work->{
            String[] names=new String[work.size()];for(int i=0;i<names.length;i++)names[i]=work.get(i).lessonName+" · 剩余 "+work.get(i).minutes+" 分钟";
            new AlertDialog.Builder(app).setTitle("选择立即学习的课节").setItems(names,(d,index)->app.mutate(s->ImmediateStudy.startLesson(s,course.optString("id"),work.get(index).lessonID,Planner.now()),false,()->today(app))).setNegativeButton("取消",null).show();
        });
    }
}
