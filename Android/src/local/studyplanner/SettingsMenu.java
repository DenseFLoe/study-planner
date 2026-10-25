package local.studyplanner;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.RippleDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import java.util.*;

/** Square category entrances. Changing categories only changes visibility, retaining edits. */
final class SettingsMenu {
    private final MainActivity app;
    private final LinearLayout parent,overview,header,saveBar;
    final SettingsTileGrid grid;
    private final TextView heading;
    private final Map<String,LinearLayout> pages=new LinkedHashMap<>();
    private final Map<String,String> titles=new LinkedHashMap<>();
    private final Set<String> schedulePages=new HashSet<>();

    SettingsMenu(MainActivity app,LinearLayout parent){
        this.app=app;this.parent=parent;
        overview=app.col();parent.addView(overview);
        overview.addView(app.title("学习设置"));
        overview.addView(app.text("点击卡片进入设置",13,app.muted));
        grid=new SettingsTileGrid(app);grid.setPadding(0,app.dp(12),0,app.dp(12));
        overview.addView(grid,new LinearLayout.LayoutParams(-1,-2));
        header=app.row();parent.addView(header);
        header.addView(app.button("‹ 全部设置",()->show("")));
        heading=app.title("");app.weighted(header,heading);
        saveBar=app.col();
    }
    LinearLayout page(String key,String title,int icon,boolean editsSchedule){
        LinearLayout content=app.col();content.setVisibility(View.GONE);
        parent.addView(content,new LinearLayout.LayoutParams(-1,-2));
        pages.put(key,content);titles.put(key,title);if(editsSchedule)schedulePages.add(key);
        LinearLayout tile=app.col();tile.setGravity(Gravity.CENTER);tile.setPadding(app.dp(10),app.dp(12),app.dp(10),app.dp(12));
        tile.setBackground(new RippleDrawable(ColorStateList.valueOf(0xffd9eee1),app.rounded(0xffffffff,16),null));
        tile.addView(new PlannerUi.Icon(app,icon,app.blue),new LinearLayout.LayoutParams(app.dp(30),app.dp(30)));
        TextView label=app.text(title,16,app.ink);label.setGravity(Gravity.CENTER);label.setTypeface(null,Typeface.BOLD);
        LinearLayout.LayoutParams labelParams=new LinearLayout.LayoutParams(-1,-2);labelParams.topMargin=app.dp(10);tile.addView(label,labelParams);
        tile.setFocusable(true);tile.setContentDescription(title+"，点击进入");tile.setOnClickListener(v->{if(!app.busy)show(key);});
        grid.addView(tile);return content;
    }
    void setSaveButton(Button button){
        saveBar.addView(app.text("可先调整多个设置，再一起保存并重排。",13,app.muted));
        saveBar.addView(button);parent.addView(saveBar);
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
