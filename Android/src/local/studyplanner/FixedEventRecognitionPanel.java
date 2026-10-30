package local.studyplanner;

import android.text.*;
import android.widget.*;
import org.json.*;

/** Recognition remains a draft until the normal event editor successfully saves it. */
final class FixedEventRecognitionPanel {
    static String weekdays(JSONArray days){String[] names={"","周日","周一","周二","周三","周四","周五","周六"};java.util.List<String> values=new java.util.ArrayList<>();for(int i=0;i<days.length();i++){int n=days.optInt(i);if(n>=1&&n<=7)values.add(names[n]);}return String.join("、",values);}
    static void render(MainActivity app,LinearLayout parent){
        LinearLayout box=app.card(parent);box.addView(app.title("粘贴文字，识别日程"));box.addView(app.text("在本机识别，不上传文字；相对日期按今天（"+java.time.LocalDate.now(Planner.ZONE)+"）换算。识别后需核对并添加。",13,app.muted));
        EditText input=app.field(box,"通知或聊天文字","",false);input.setSingleLine(false);input.setMinLines(3);input.setHint("明天下午3点到5点开会");
        LinearLayout results=app.col();TextView status=app.text("支持分行识别多条事项，每次最多30000字、20条候选。",12,app.muted);int[] generation={0};boolean[] running={false};
        Button recognize=app.button("识别日程",()->{
            if(running[0])return;final String raw=input.getText().toString();final int token=++generation[0];running[0]=true;status.setText("正在本机识别…");results.removeAllViews();
            app.worker.execute(()->{FixedEventTextParser.Result value=FixedEventTextParser.parse(raw,Planner.now());app.runOnUiThread(()->{
                if(app.isDestroyed()||!box.isAttachedToWindow()||token!=generation[0])return;running[0]=false;
                status.setText(value.drafts.size()+" 条候选"+(value.messages.isEmpty()?"":"\n"+String.join("\n",value.messages)));
                for(FixedEventTextParser.Draft draft:value.drafts){JSONObject e=draft.event;LinearLayout candidate=app.card(results);
                    candidate.addView(app.text(e.optString("title"),17,app.ink));candidate.addView(app.text(Planner.date(e.optDouble("startDate"))+"  "+Planner.time(e.optInt("startMinute"))+"–"+Planner.time(e.optInt("endMinute"))+(e.optJSONArray("weekdays").length()>0?"\n重复星期："+weekdays(e.optJSONArray("weekdays"))+" · 截至 "+Planner.date(e.optDouble("endDate")):""),13,app.muted));
                    for(String warning:draft.warnings)candidate.addView(app.text(warning,13,0xffa56618));candidate.addView(app.button("核对并添加",()->app.eventEditor(e,true)));
                }
            });});
        });box.addView(recognize);box.addView(status);box.addView(results);
        input.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){generation[0]++;running[0]=false;results.removeAllViews();status.setText("文字已更新，请重新识别。最多30000字。");}public void afterTextChanged(Editable s){}});
    }
}
