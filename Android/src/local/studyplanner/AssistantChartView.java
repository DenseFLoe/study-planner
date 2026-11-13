package local.studyplanner;

import android.content.Context;
import android.graphics.*;
import android.view.*;
import android.widget.*;
import java.util.*;

/** No WebView or external assets. Long axes scroll without shrinking text. */
final class AssistantChartView {
    static final int[] COLORS={0xff325bd4,0xffb15e12,0xff087e75,0xff9251b5,0xffc04064,0xff61772b,0xff527589};
    static void render(Context c,LinearLayout parent,AssistantChart chart,boolean standalone){
        LinearLayout box=AssistantInsightView.column(c);if(standalone){box.setPadding(dp(c,14),dp(c,12),dp(c,14),dp(c,12));box.setBackground(AssistantUi.shape(c,AssistantUi.SURFACE,18));}LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,-2);params.topMargin=dp(c,10);parent.addView(box,params);
        TextView title=AssistantInsightView.label(c,chart.title,16,AssistantUi.INK);title.setTypeface(null,Typeface.BOLD);box.addView(title);
        PlannerUi.Flow choices=new PlannerUi.Flow(c);box.addView(choices,new LinearLayout.LayoutParams(-1,-2));LinearLayout visual=AssistantInsightView.column(c);box.addView(visual,new LinearLayout.LayoutParams(-1,-2));
        LinearLayout table=AssistantInsightView.column(c);table.setVisibility(View.GONE);box.addView(table,new LinearLayout.LayoutParams(-1,-2));
        for(int i=0;i<chart.labels.length;i++){StringBuilder row=new StringBuilder(chart.labels[i]);for(int j=0;j<chart.names.length;j++)row.append("\n").append(chart.names[j]).append("：").append(AssistantChart.format(chart.values[j][i])).append(' ').append(chart.unit);TextView value=AssistantInsightView.label(c,row.toString(),14,AssistantUi.INK);value.setPadding(dp(c,10),dp(c,8),dp(c,10),dp(c,8));value.setBackgroundColor(i%2==0?AssistantUi.WHITE:AssistantUi.SURFACE);table.addView(value,new LinearLayout.LayoutParams(-1,-2));}
        Map<String,Button> buttons=new LinkedHashMap<>();String[] mode={chart.kind};Runnable redraw=()->{
            visual.removeAllViews();for(Map.Entry<String,Button> entry:buttons.entrySet()){boolean selected=entry.getKey().equals(mode[0]);entry.getValue().setSelected(selected);AssistantUi.tone(entry.getValue(),selected);}
            PlannerUi.Flow legend=new PlannerUi.Flow(c);String[] names=mode[0].equals("donut")?chart.labels:chart.names;for(int i=0;i<names.length;i++){TextView label=AssistantInsightView.label(c,(mode[0].equals("donut")?"● ":i%2==0?"● ━ ":"■ ┄ ")+names[i],13,COLORS[i]);legend.addView(label);}visual.addView(legend,new LinearLayout.LayoutParams(-1,-2));
            HorizontalScrollView scroller=new HorizontalScrollView(c);scroller.setFillViewport(true);scroller.setHorizontalScrollBarEnabled(true);Plot plot=new Plot(c,chart,mode[0]);scroller.addView(plot,new HorizontalScrollView.LayoutParams(-2,-2));visual.addView(scroller,new LinearLayout.LayoutParams(-1,-2));
            visual.addView(AssistantInsightView.label(c,"单位："+chart.unit+" · 横向滑动查看，数值见下方明细",12,AssistantUi.MUTED));
        };
        for(String kind:chart.supportsDonut()?new String[]{"bar","line","donut"}:new String[]{"bar","line"}){Button b=AssistantInsightView.action(c,kind.equals("bar")?"柱状图":kind.equals("line")?"折线图":"环形图",()->{mode[0]=kind;redraw.run();});buttons.put(kind,b);choices.addView(b);}redraw.run();
        PlannerUi.Flow actions=new PlannerUi.Flow(c);box.addView(actions,new LinearLayout.LayoutParams(-1,-2));Button detail=AssistantInsightView.action(c,"查看数值",()->{});detail.setOnClickListener(v->{boolean open=table.getVisibility()!=View.VISIBLE;table.setVisibility(open?View.VISIBLE:View.GONE);detail.setText(open?"收起数值":"查看数值");});actions.addView(detail);actions.addView(AssistantInsightView.action(c,"复制数据",()->AssistantInsightView.copy(c,chart.title+"\n"+chart.table()+"\n快照 · "+chart.stamp)));
        if(standalone)box.addView(AssistantInsightView.label(c,"生成时的数据快照 · "+chart.stamp,11,AssistantUi.MUTED));
    }
    static int dp(Context c,int n){return PlannerUi.dp(c,n);}
    static final class Plot extends View {
        final AssistantChart chart;final String kind;final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);final float font;float left,slot;double low,high;
        Plot(Context c,AssistantChart chart,String kind){super(c);this.chart=chart;this.kind=kind;font=12*getResources().getDisplayMetrics().scaledDensity;setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);setContentDescription(chart.title+"，"+(kind.equals("line")?"折线图":kind.equals("bar")?"柱状图":"环形图")+"。完整日期、标签与数值请展开“查看数值”。");setFocusable(true);}
        @Override protected void onMeasure(int w,int h){paint.setTextSize(font);low=0;high=0;for(double[] series:chart.values)for(double v:series){low=Math.min(low,v);high=Math.max(high,v);}if(high==low)high=low+1;left=Math.max(dp(getContext(),36),Math.max(paint.measureText(tick(low)),paint.measureText(tick(high)))+dp(getContext(),10));slot=dp(getContext(),chart.names.length>2?96:64);for(String label:chart.labels)slot=Math.max(slot,paint.measureText(AssistantChart.axis(label))+dp(getContext(),20));int width=kind.equals("donut")?dp(getContext(),220):(int)(left+slot*chart.labels.length+dp(getContext(),12));setMeasuredDimension(resolveSize(width,w),dp(getContext(),216)+(int)(font*2));}
        static String tick(double n){return Math.abs(n)>=1000000?AssistantChart.format(n/1000000)+"百万":Math.abs(n)>=10000?AssistantChart.format(n/10000)+"万":AssistantChart.format(n);}
        float y(double value,float top,float bottom){return bottom-(float)((value-low)/(high-low))*(bottom-top);}
        @Override protected void onDraw(Canvas c){super.onDraw(c);paint.setStyle(Paint.Style.FILL);paint.setPathEffect(null);paint.setTextSize(font);float top=font+dp(getContext(),8),bottom=getHeight()-font*2-dp(getContext(),12);
            if(kind.equals("donut")){float size=Math.min(getWidth()-dp(getContext(),32),bottom-top),x=(getWidth()-size)/2f;RectF oval=new RectF(x,top,x+size,top+size);double total=0;for(double v:chart.values[0])total+=v;float angle=-90;for(int i=0;i<chart.labels.length;i++){paint.setColor(COLORS[i]);float sweep=(float)(chart.values[0][i]/total*360);c.drawArc(oval,angle,sweep,true,paint);angle+=sweep;}paint.setColor(AssistantUi.SURFACE);c.drawCircle(oval.centerX(),oval.centerY(),size*.30f,paint);paint.setColor(AssistantUi.INK);paint.setTextAlign(Paint.Align.CENTER);String text=AssistantChart.format(total);paint.setTextSize(Math.min(font*1.25f,(size*.52f)/Math.max(1,paint.measureText(text))*font));c.drawText(text,oval.centerX(),oval.centerY(),paint);paint.setTextSize(font);c.drawText(chart.unit,oval.centerX(),oval.centerY()+font*1.5f,paint);return;}
            float end=getWidth()-dp(getContext(),10);slot=(end-left)/chart.labels.length;paint.setStrokeWidth(dp(getContext(),1));for(int i=0;i<4;i++){double value=low+(high-low)*i/3;float y=y(value,top,bottom);paint.setColor(AssistantUi.LINE);c.drawLine(left,y,end,y,paint);paint.setColor(AssistantUi.MUTED);paint.setTextAlign(Paint.Align.RIGHT);c.drawText(tick(value),left-dp(getContext(),6),y+font*.3f,paint);}float zero=y(0,top,bottom);paint.setColor(AssistantUi.MUTED);c.drawLine(left,zero,end,zero,paint);
            for(int s=0;s<chart.names.length;s++){paint.setColor(COLORS[s]);paint.setStrokeWidth(dp(getContext(),2));float previousX=0,previousY=0;for(int i=0;i<chart.labels.length;i++){float x=left+slot*(i+.5f),y=y(chart.values[s][i],top,bottom);if(kind.equals("bar")){float width=slot*.72f/chart.names.length,l=left+slot*i+slot*.14f+s*width;c.drawRect(l,Math.min(zero,y),l+width-dp(getContext(),2),Math.max(zero,y),paint);}else{if(i>0){paint.setPathEffect(s%2==0?null:new DashPathEffect(new float[]{dp(getContext(),6),dp(getContext(),4)},0));c.drawLine(previousX,previousY,x,y,paint);paint.setPathEffect(null);}if(s%2==0)c.drawCircle(x,y,dp(getContext(),3),paint);else c.drawRect(x-dp(getContext(),3),y-dp(getContext(),3),x+dp(getContext(),3),y+dp(getContext(),3),paint);previousX=x;previousY=y;}}}
            paint.setTextAlign(Paint.Align.CENTER);paint.setColor(AssistantUi.MUTED);for(int i=0;i<chart.labels.length;i++)c.drawText(AssistantChart.axis(chart.labels[i]),left+slot*(i+.5f),bottom+font*1.7f,paint);
        }
    }
}
