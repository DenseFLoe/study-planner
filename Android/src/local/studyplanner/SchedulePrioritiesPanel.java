package local.studyplanner;

import android.graphics.Typeface;
import android.widget.*;
import org.json.*;

/**
 * Settings panel for the four existing soft scheduling preferences.
 *
 * <p>Only the Spinner selections live in this panel. The constructor never writes to the
 * supplied settings object and never touches the database; the main settings save button
 * reads {@link #levels()} when the user chooses to save and replan.
 */
final class SchedulePrioritiesPanel {
    private final Spinner[] spinners=new Spinner[SchedulePriorities.RULES.length];

    SchedulePrioritiesPanel(MainActivity app,LinearLayout parent,JSONObject settings){
        LinearLayout box=app.card(parent);
        box.addView(app.title("排课逻辑权重"));
        box.addView(app.text("数字越小越优先。先满足 0 级时间约束，再按等级考虑已有偏好；同级按默认顺序处理。",13,app.muted));

        LinearLayout fixed=app.col();
        fixed.setPadding(app.dp(12),app.dp(8),app.dp(12),app.dp(8));
        fixed.setBackground(app.rounded(0xfff2f2f2,12));
        LinearLayout.LayoutParams fixedParams=new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,LinearLayout.LayoutParams.WRAP_CONTENT);
        fixedParams.setMargins(0,app.dp(6),0,app.dp(6));
        box.addView(fixed,fixedParams);
        TextView fixedTitle=app.text("0 级 · 必须遵守",16,app.ink);
        fixedTitle.setTypeface(null,Typeface.BOLD);
        fixed.addView(fixedTitle);
        fixed.addView(app.text("遵守课程开始日、截止日、可学习时段和实际开课时间；保留固定课表，浮动事项在规定窗口内完成。空间不足时提示，不能靠调整等级突破时间限制。",13,app.muted));
        fixed.addView(app.text("保留往日和已确认记录；保持整节课与课节顺序，以及 15 分钟课间休息。普通课程遵守最小时间块，最后余量可更短。",13,app.muted));

        SchedulePriorities priorities=new SchedulePriorities(settings);
        for(int i=0;i<spinners.length;i++){
            TextView name=app.text(SchedulePriorities.TITLES[i],16,app.ink);
            name.setTypeface(null,Typeface.BOLD);
            box.addView(name);
            Spinner spinner=new Spinner(app);
            spinner.setContentDescription(SchedulePriorities.TITLES[i]+"优先等级");
            spinner.setAdapter(new ArrayAdapter<>(app,android.R.layout.simple_spinner_dropdown_item,SchedulePriorities.LEVEL_NAMES));
            spinner.setSelection(priorities.levels[i]-1);
            box.addView(spinner);
            box.addView(app.text(SchedulePriorities.DETAILS[i],13,app.muted));
            spinners[i]=spinner;
        }

        box.addView(app.button("恢复默认权重",()->{
            for(int i=0;i<spinners.length;i++)spinners[i].setSelection(i);
        }));
        box.addView(app.text("点击保存设置并重排生效；时间紧张时偏好会让步。默认规则下，能排入的 3 倍课程可优先集中学习。手动调整的当天顺序在仍可排入时保留。",13,app.muted));
    }

    /** The four selected levels (1..4), keyed exactly like the planner's stored settings. */
    JSONObject levels()throws JSONException{
        JSONObject out=new JSONObject();
        for(int i=0;i<spinners.length;i++){
            int selected=spinners[i]==null?-1:spinners[i].getSelectedItemPosition();
            out.put(SchedulePriorities.RULES[i],Math.max(1,Math.min(4,(selected<0?i:selected)+1)));
        }
        return out;
    }
}
