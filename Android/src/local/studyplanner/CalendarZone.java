package local.studyplanner;

import android.app.AlertDialog;
import android.content.Context;
import android.widget.LinearLayout;
import java.time.ZoneId;

/** Keep existing installations on Beijing time; following the system is an explicit local choice. */
final class CalendarZone {
    static String option(Context c){return c.getSharedPreferences("calendar-options",Context.MODE_MULTI_PROCESS).getString("zone","beijing");}
    static ZoneId resolve(Context c){return option(c).equals("system")?ZoneId.systemDefault():ZoneId.of("Asia/Shanghai");}
    static void controls(MainActivity app,LinearLayout form){
        form.addView(app.title("日程时区"));form.addView(app.text((option(app).equals("system")?"跟随系统：":"北京时间：")+Planner.ZONE.getId(),14,app.ink));
        form.addView(app.button("选择日程时区",()->new AlertDialog.Builder(app).setTitle("日程时区")
            .setItems(new String[]{"北京时间（保留原有行为）","跟随系统时区"},(d,index)->new AlertDialog.Builder(app).setTitle("切换日程时区并重新排课？")
                .setMessage("将按新时区解释每日时段并重排未确认任务；已有学习记录的时间戳保留，日期显示可能变化。此设置仅保存在手机。")
                .setNegativeButton("取消",null).setPositiveButton("切换",(confirm,which)->change(app,index==0?"beijing":"system")).show()).show()));
    }
    static void refresh(MainActivity app){if(!app.busy&&!resolve(app).equals(Planner.ZONE))change(app,option(app));}
    static void change(MainActivity app,String choice){
        String previous=option(app);ZoneId old=Planner.ZONE;
        app.mutate(state->{
            ZoneId target=choice.equals("system")?ZoneId.systemDefault():ZoneId.of("Asia/Shanghai");
            Planner.ZONE=target;
            try{Planner.replan(state,Planner.now());
                if(!app.getSharedPreferences("calendar-options",0).edit().putString("zone",choice).commit())throw new IllegalStateException("时区设置未保存。");
            }catch(Exception error){Planner.ZONE=old;throw error;}
        },false,()->{app.selected=java.time.LocalDate.now(Planner.ZONE);app.month=app.selected.withDayOfMonth(1);},error->{
            Planner.ZONE=old;app.getSharedPreferences("calendar-options",0).edit().putString("zone",previous).commit();app.alert("时区切换未保存",error.getMessage());
        });
    }
}
