package local.studyplanner;

import android.app.AlertDialog;
import android.view.View;
import android.widget.*;
import org.json.*;
import java.time.*;
import java.util.*;

final class CompressedPreviewPanel {
    static void render(MainActivity app,LinearLayout parent){
        LinearLayout box=app.card(parent);box.addView(app.title("极限压缩方案"));TextView summary=app.text("正在读取云同步结果…",13,app.muted);box.addView(summary);
        box.addView(app.text("由 Mac 计算，云同步后在此查看。仅作对照，不改变正式课表。",12,app.muted));JSONObject captured=app.state;
        app.worker.execute(()->{try{JSONObject preview=CompressedPreviewStore.read(app);boolean current=preview!=null&&CompressedPreview.current(preview,captured,Planner.now());app.runOnUiThread(()->{
            if(app.isDestroyed()||!box.isAttachedToWindow()||app.state!=captured)return;
            if(preview==null){summary.setText("暂无结果，请先在 Mac 完成计算，再让两端完成云同步。");return;}
            summary.setText((current?"已同步":"待更新 · 课程、进度、时段或日期已变化")+"\n计算于 "+Planner.date(preview.optDouble("capturedAt"))+" "+Planner.clock(preview.optDouble("capturedAt"))+(preview.has("finish")?"\n全部学完："+Planner.date(preview.optDouble("finish"))+" "+Planner.clock(preview.optDouble("finish")):"\n没有剩余学习量"));
            box.addView(app.button(current?"查看方案":"查看旧方案（待更新）",()->app.run(()->show(app,preview))));
        });}catch(Exception e){app.runOnUiThread(()->{if(!app.isDestroyed()&&box.isAttachedToWindow())summary.setText("结果暂不可读，请在 Mac 重新计算并云同步。");});}});
    }
    static void show(MainActivity app,JSONObject p)throws Exception {
        LinearLayout form=app.col();form.setPadding(app.dp(16),app.dp(8),app.dp(16),app.dp(8));
        form.addView(app.text("完整课节与顺序保持不变；此极限方案不额外保留课间休息，不受原课程日期、每日加量或暂停排程限制。",13,app.muted));
        for(JSONObject c:Planner.list(p.getJSONArray("courses")))form.addView(app.text(c.getString("name")+" · "+c.getInt("remainingMinutes")+" 分钟"+(c.has("finish")?"\n最晚完成 "+Planner.date(c.getDouble("finish"))+" "+Planner.clock(c.getDouble("finish")):" · 已完成"),15,app.color(c.optString("color"))));
        List<JSONObject> rows=Planner.list(p.getJSONArray("rows"));Set<LocalDate> days=new TreeSet<>();for(JSONObject r:rows)days.add(Planner.day(r.getDouble("start")));
        if(!days.isEmpty()){
            Spinner date=new Spinner(app);List<LocalDate> list=new ArrayList<>(days);date.setAdapter(new ArrayAdapter<>(app,android.R.layout.simple_spinner_dropdown_item,list));form.addView(date);LinearLayout timeline=app.col();form.addView(timeline);
            date.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener(){public void onNothingSelected(android.widget.AdapterView<?> v){}public void onItemSelected(android.widget.AdapterView<?> v,View view,int position,long id){timeline.removeAllViews();int count=0;for(JSONObject r:rows)if(Planner.day(r.optDouble("start")).equals(list.get(position))){if(count++>=200){timeline.addView(app.text("当天项目较多，完整预览请在 Mac 查看。",13,app.muted));break;}timeline.addView(app.text(Planner.clock(r.optDouble("start"))+"–"+Planner.clock(r.optDouble("end"))+"  "+(r.optBoolean("fixed")?"固定事项 · ":"")+r.optString("title"),14,app.color(r.optString("color"))));}}});
        }
        if(p.getInt("totalRows")>rows.size())form.addView(app.text("手机显示前 "+rows.size()+" 条，共 "+p.getInt("totalRows")+" 条；完整方案请在 Mac 查看。",13,app.muted));
        ScrollView scroll=new ScrollView(app);scroll.addView(form);new AlertDialog.Builder(app).setTitle("极限压缩 · 只读预览").setView(scroll).setPositiveButton("关闭",null).show();
    }
}
