package local.studyplanner;

import android.content.Context;
import android.graphics.Typeface;
import android.view.Gravity;
import android.view.View;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import java.util.*;

/** Settings rows retain their editors and drafts while navigating categories. */
final class SettingsMenu {
    private final MainActivity app;
    private final LinearLayout parent,overview,header,saveBar;
    final LinearLayout grid;
    private final TextView heading;
    private final Map<String,LinearLayout> pages=new LinkedHashMap<>();
    private final Map<String,String> titles=new LinkedHashMap<>();
    private final Set<String> schedulePages=new HashSet<>();

    SettingsMenu(MainActivity app,LinearLayout parent){
        this.app=app;this.parent=parent;
        overview=app.col();parent.addView(overview);
        overview.addView(app.text("按你的节奏安排学习",14,app.muted));
        grid=app.col();grid.setPadding(0,app.dp(12),0,app.dp(12));
        overview.addView(grid,new LinearLayout.LayoutParams(-1,-2));
        header=app.row();parent.addView(header);
        header.addView(PlannerUi.iconButton(app,6,"返回全部设置",()->show("")),new LinearLayout.LayoutParams(app.dp(48),app.dp(48)));
        heading=app.title("");app.weighted(header,heading);
        saveBar=app.col();
    }
    LinearLayout page(String key,String title,int icon,boolean editsSchedule){
        LinearLayout content=app.col();content.setVisibility(View.GONE);
        parent.addView(content,new LinearLayout.LayoutParams(-1,-2));
        pages.put(key,content);titles.put(key,title);if(editsSchedule)schedulePages.add(key);
        LinearLayout tile=app.row();tile.setMinimumHeight(app.dp(80));tile.setPadding(app.dp(16),app.dp(12),app.dp(12),app.dp(12));
        tile.setBackground(PlannerUi.ripple(app,PlannerUi.SURFACE,18));
        android.widget.FrameLayout iconBox=new android.widget.FrameLayout(app);iconBox.setBackground(app.rounded(PlannerUi.TONAL,12));
        iconBox.addView(new PlannerUi.Icon(app,icon,app.blue),new android.widget.FrameLayout.LayoutParams(app.dp(22),app.dp(22),Gravity.CENTER));
        tile.addView(iconBox,new LinearLayout.LayoutParams(app.dp(40),app.dp(40)));
        LinearLayout copy=app.col();copy.setPadding(app.dp(14),0,app.dp(8),0);
        TextView label=app.text(title,16,app.ink);label.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));copy.addView(label);
        copy.addView(app.text(description(key),12,app.muted));app.weighted(tile,copy);
        tile.addView(new PlannerUi.Icon(app,7,app.muted),new LinearLayout.LayoutParams(app.dp(18),app.dp(18)));
        tile.setFocusable(true);tile.setContentDescription(title+"，"+description(key));tile.setOnClickListener(v->{if(!app.busy)show(key);});
        LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,-2);params.bottomMargin=app.dp(8);grid.addView(tile,params);return content;
    }
    private String description(String key){
        switch(key){
            case "assistant":return "对话查询 · 日程修改";
            case "display":return "时间字号 · 日程时区";
            case "priorities":return "优先级与排课偏好";
            case "explanation":return "了解课程为什么这样安排";
            case "defaults":return "最小学习时间块 · 确认时间";
            case "availability":return "每天可用时段与休息日";
            case "localSync":return "通过热点连接电脑";
            case "cloudSync":return "多设备同步与连接状态";
            case "data":return "导出 · 恢复 · 版本信息";
            default:return "查看与调整";
        }
    }
    void setSaveButton(Button button){
        saveBar.addView(app.text("可先调整多个设置，再一起保存并重排。",13,app.muted));
        PlannerUi.buttonTone(button,true);saveBar.addView(button);parent.addView(saveBar);
    }
    void setRestoreButton(Button button){
        saveBar.addView(button);
        saveBar.addView(app.text("切换页面或同步后，未保存输入仍会保留。",13,app.muted));
    }
    void show(String key){
        if(!pages.containsKey(key))key="";
        app.settingsSection=key;boolean home=key.isEmpty();
        overview.setVisibility(home?View.VISIBLE:View.GONE);header.setVisibility(home?View.GONE:View.VISIBLE);
        heading.setText(home?"":titles.get(key));
        for(Map.Entry<String,LinearLayout> entry:pages.entrySet())entry.getValue().setVisibility(entry.getKey().equals(key)?View.VISIBLE:View.GONE);
        saveBar.setVisibility(schedulePages.contains(key)?View.VISIBLE:View.GONE);
        InputMethodManager keyboard=(InputMethodManager)app.getSystemService(Context.INPUT_METHOD_SERVICE);
        if(keyboard!=null)keyboard.hideSoftInputFromWindow(parent.getWindowToken(),0);
        parent.post(()->{if(parent.getParent() instanceof ScrollView)((ScrollView)parent.getParent()).scrollTo(0,0);});
    }
}
