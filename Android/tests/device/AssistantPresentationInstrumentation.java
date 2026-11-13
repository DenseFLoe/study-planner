package local.studyplanner;

import android.app.Instrumentation;
import android.content.Context;
import android.content.res.Configuration;
import android.graphics.*;
import android.os.Bundle;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.util.concurrent.atomic.AtomicReference;
import static local.studyplanner.AssistantProtocol.*;

/** Offscreen synthetic views only. Safe on a connected phone: no Activity, files, database or API. */
public final class AssistantPresentationInstrumentation extends Instrumentation {
    int checks;
    void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    void inspect(View view){
        if(view.getVisibility()!=View.VISIBLE)return;
        if(view instanceof TextView){TextView t=(TextView)view;if(t.getLayout()!=null){check(t.getLayout().getHeight()<=t.getHeight()-t.getCompoundPaddingTop()-t.getCompoundPaddingBottom()+2,"Clipped card text");for(int i=0;i<t.getLineCount();i++)check(t.getLayout().getEllipsisCount(i)==0,"Truncated card label");}}
        if(view instanceof Button)check(view.getHeight()>=PlannerUi.dp(view.getContext(),48),"Small button target");
        if(view instanceof ViewGroup){ViewGroup g=(ViewGroup)view;for(int i=0;i<g.getChildCount();i++){View child=g.getChildAt(i);if(child.getVisibility()!=View.VISIBLE)continue;if(!(g instanceof HorizontalScrollView))check(child.getLeft()>=0&&child.getRight()<=g.getWidth()+1,"Card/action horizontal overflow");inspect(child);}}
    }
    TextView find(View view,String text){if(view instanceof TextView&&((TextView)view).getText().toString().equals(text))return (TextView)view;if(view instanceof ViewGroup)for(int i=0;i<((ViewGroup)view).getChildCount();i++){TextView result=find(((ViewGroup)view).getChildAt(i),text);if(result!=null)return result;}return null;}
    void layout(LinearLayout root,int width){int pixels=PlannerUi.dp(root.getContext(),width);root.measure(View.MeasureSpec.makeMeasureSpec(pixels,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(0,View.MeasureSpec.UNSPECIFIED));root.layout(0,0,pixels,root.getMeasuredHeight());inspect(root);Bitmap b=Bitmap.createBitmap(pixels,Math.min(4096,root.getHeight()),Bitmap.Config.ARGB_8888);root.draw(new Canvas(b));b.recycle();}
    void components()throws Exception{
        for(float scale:new float[]{1,1.5f,2})for(int width:new int[]{320,360,600}){
            Configuration config=new Configuration(getTargetContext().getResources().getConfiguration());config.fontScale=scale;Context c=new ContextThemeWrapper(getTargetContext().createConfigurationContext(config),getTargetContext().getApplicationInfo().theme);
            LinearLayout root=AssistantInsightView.column(c);root.setPadding(PlannerUi.dp(c,20),0,PlannerUi.dp(c,20),0);String stamp="2026-11-13 12:00 Asia/Singapore";
            JSONObject course=AssistantInsights.card("course","高等数学 · 含长课节名称的强化课程进度","课程进度 · 截止 2026-12-31",new JSONArray().put(AssistantInsights.metric("有效完成",123456)).put(AssistantInsights.metric("剩余学习量",60)).put(AssistantInsights.metric("课程总量",123516)),AssistantInsights.notes("有效进度与实际学习用时不同。"),stamp).put("progress",.6);
            AssistantInsightView.render(c,root,course);AssistantChart chart=AssistantChart.create("每日实际与计划","line",new String[]{"2026-11-11","2026-11-12","2026-11-13"},new String[]{"实际学习","计划学习"},new double[][]{{0,90,120},{120,60,100}},stamp);AssistantChartView.render(c,root,chart,true);layout(root,width);
            find(root,"柱状图").performClick();layout(root,width);find(root,"查看数值").performClick();layout(root,width);check(find(root,"2026-11-11\n实际学习：0 分钟\n计划学习：120 分钟")!=null,"Numeric chart alternative missing");find(root,"收起数值").performClick();layout(root,width);
            LinearLayout donut=AssistantInsightView.column(c);AssistantChartView.render(c,donut,AssistantChart.create("完成占比","donut",new String[]{"已完成","剩余"},new String[]{"进度"},new double[][]{{30,70}},stamp),true);layout(donut,width);find(donut,"折线图").performClick();layout(donut,width);
        }
    }
    @Override public void onCreate(Bundle args){super.onCreate(args);start();}
    @Override public void onStart(){Bundle result=new Bundle();AtomicReference<Throwable> failure=new AtomicReference<>();runOnMainSync(()->{try{components();}catch(Throwable e){failure.set(e);}});Throwable error=failure.get();result.putString("stream",error==null?"PASS "+checks+" assistant card/chart layout checks; 320/360/600dp, fonts 1/1.5/2; no files, API or planner writes\n":"FAIL "+error.getClass().getSimpleName()+": "+error.getMessage()+"\n");finish(error==null?-1:1,result);}
}
