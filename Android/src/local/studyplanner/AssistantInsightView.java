package local.studyplanner;

import android.content.*;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;
import org.json.*;

/** Phone cards use wrapping labels and actions; charts have an accessible numeric alternative. */
final class AssistantInsightView {
    static int dp(Context c,int n){return PlannerUi.dp(c,n);}
    static LinearLayout column(Context c){LinearLayout v=new LinearLayout(c);v.setOrientation(LinearLayout.VERTICAL);return v;}
    static TextView label(Context c,String text,int size,int color){TextView v=AssistantMarkdown.text(c,"",size);v.setText(text);v.setTextColor(color);v.setPadding(0,dp(c,4),0,dp(c,6));return v;}
    static Button action(Context c,String text,Runnable run){Button b=new Button(c);PlannerUi.styleButton(b);b.setText(text);b.setTextSize(14);AssistantUi.quiet(b);b.setOnClickListener(v->run.run());return b;}
    static void copy(Context c,String text){((ClipboardManager)c.getSystemService(Context.CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("学习助手",text));Toast.makeText(c,"已复制",Toast.LENGTH_SHORT).show();}
    static LinearLayout render(Context c,LinearLayout parent,JSONObject data){
        LinearLayout box=column(c);try{
            AssistantInsights.validate(data);box.setPadding(dp(c,14),dp(c,12),dp(c,14),dp(c,12));box.setBackground(AssistantUi.shape(c,AssistantUi.SURFACE,18));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.setMargins(0,dp(c,10),0,dp(c,6));parent.addView(box,p);
            TextView title=label(c,data.getString("title"),18,AssistantUi.INK);title.setTypeface(null,Typeface.BOLD);box.addView(title);box.addView(label(c,data.getString("subtitle"),13,AssistantUi.MUTED));
            MetricGrid grid=new MetricGrid(c);for(JSONObject metric:Planner.list(data.getJSONArray("metrics"))){LinearLayout cell=column(c);cell.setPadding(dp(c,10),dp(c,8),dp(c,10),dp(c,8));cell.setBackground(AssistantUi.shape(c,AssistantUi.WHITE,12));cell.addView(label(c,metric.getString("title"),12,AssistantUi.MUTED));TextView value=label(c,AssistantChart.format(metric.getDouble("value"))+" "+metric.getString("unit"),19,AssistantUi.INK);value.setTypeface(null,Typeface.BOLD);cell.addView(value);grid.addView(cell);}box.addView(grid,new LinearLayout.LayoutParams(-1,-2));
            if(data.has("progress")){double progress=data.getDouble("progress");box.addView(label(c,"有效课程进度 · "+AssistantChart.format(progress*100)+"%",14,AssistantUi.INK));ProgressBar bar=new ProgressBar(c,null,android.R.attr.progressBarStyleHorizontal);bar.setMax(10000);bar.setProgress((int)Math.round(progress*10000));bar.setProgressTintList(ColorStateList.valueOf(0xff157e79));bar.setContentDescription("有效课程进度 "+AssistantChart.format(progress*100)+"%");box.addView(bar,new LinearLayout.LayoutParams(-1,dp(c,8)));}
            if(data.has("chart"))AssistantChartView.render(c,box,new AssistantChart(data.getJSONObject("chart")),false);
            JSONArray notes=data.getJSONArray("notes");for(int i=0;i<notes.length();i++)box.addView(label(c,notes.getString(i),12,AssistantUi.MUTED));
            box.addView(label(c,"生成时的数据快照 · "+data.getString("capturedAt"),11,AssistantUi.MUTED));
        }catch(Exception e){box.addView(label(c,"此卡片暂时无法显示，请重新查询。",14,AssistantUi.MUTED));if(box.getParent()==null)parent.addView(box);}return box;
    }
    static void cards(Context c,LinearLayout parent,JSONArray cards){
        if(cards==null||cards.length()==0)return;int first=Math.min(3,cards.length());for(int i=0;i<first;i++)render(c,parent,cards.optJSONObject(i));
        if(cards.length()>first){LinearLayout extra=column(c);extra.setVisibility(View.GONE);parent.addView(extra);Button toggle=action(c,"更多查询卡片（"+(cards.length()-first)+"）",()->{});parent.addView(toggle);boolean[] populated={false};toggle.setOnClickListener(v->{boolean open=extra.getVisibility()!=View.VISIBLE;if(open&&!populated[0]){for(int i=first;i<cards.length();i++)render(c,extra,cards.optJSONObject(i));populated[0]=true;}extra.setVisibility(open?View.VISIBLE:View.GONE);toggle.setText(open?"收起更多卡片":"更多查询卡片（"+(cards.length()-first)+"）");});}
    }
    /** 2 columns when labels have room; large fonts and narrow phones use 1 column. */
    static final class MetricGrid extends ViewGroup {
        int columns=1;final int gap;final java.util.List<Integer> heights=new java.util.ArrayList<>();
        MetricGrid(Context c){super(c);gap=dp(c,8);}
        @Override protected LayoutParams generateDefaultLayoutParams(){return new LayoutParams(-1,-2);}
        @Override protected void onMeasure(int w,int h){int width=MeasureSpec.getSize(w);columns=width>=dp(getContext(),Math.round(272*getResources().getConfiguration().fontScale))?2:1;int cell=Math.max(0,(width-(columns-1)*gap)/columns),height=0;heights.clear();for(int i=0;i<getChildCount();i+=columns){int row=0;for(int j=i;j<Math.min(i+columns,getChildCount());j++){View v=getChildAt(j);v.measure(MeasureSpec.makeMeasureSpec(cell,MeasureSpec.EXACTLY),MeasureSpec.makeMeasureSpec(0,MeasureSpec.UNSPECIFIED));row=Math.max(row,v.getMeasuredHeight());}heights.add(row);height+=row+(i==0?0:gap);}setMeasuredDimension(width,resolveSize(height,h));}
        @Override protected void onLayout(boolean changed,int l,int t,int r,int b){int width=(getWidth()-(columns-1)*gap)/columns,y=0;for(int i=0;i<getChildCount();i++){int row=i/columns,col=i%columns;if(i>0&&col==0)y+=heights.get(row-1)+gap;getChildAt(i).layout(col*(width+gap),y,col*(width+gap)+width,y+heights.get(row));}}
    }
}
