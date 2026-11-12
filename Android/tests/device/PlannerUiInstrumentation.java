package local.studyplanner;

import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.os.Build;
import android.os.Bundle;
import android.view.ContextThemeWrapper;
import android.view.View;
import android.view.ViewGroup;
import android.widget.*;
import org.json.*;
import java.io.File;
import java.io.FileOutputStream;
import java.time.LocalDate;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;

/** Run only on a fresh disposable emulator: native layout, navigation and synthetic screenshots. */
public final class PlannerUiInstrumentation extends Instrumentation {
    private int checks;private MainActivity app;private Bundle arguments;
    private void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    private boolean main(BooleanSupplier read){AtomicBoolean result=new AtomicBoolean();runOnMainSync(()->result.set(read.getAsBoolean()));return result.get();}
    private void await(BooleanSupplier ready)throws Exception{
        long until=System.currentTimeMillis()+15000;
        while(System.currentTimeMillis()<until){if(main(ready))return;Thread.sleep(50);}
        throw new AssertionError("Native UI did not settle");
    }
    private TextView find(View view,String text){
        if(view instanceof TextView&&((TextView)view).getText().toString().equals(text))return (TextView)view;
        if(view instanceof ViewGroup)for(int i=0;i<((ViewGroup)view).getChildCount();i++){TextView child=find(((ViewGroup)view).getChildAt(i),text);if(child!=null)return child;}
        return null;
    }
    private EditText firstInput(View view){
        if(view instanceof EditText)return (EditText)view;
        if(view instanceof ViewGroup)for(int i=0;i<((ViewGroup)view).getChildCount();i++){EditText input=firstInput(((ViewGroup)view).getChildAt(i));if(input!=null)return input;}
        return null;
    }
    private void click(String text){runOnMainSync(()->{TextView target=find(app.root,text);check(target!=null,"Missing action: "+text);target.performClick();});waitForIdleSync();}
    private void inspect(View view){
        if(view.getVisibility()!=View.VISIBLE)return;
        check(view.getWidth()>=0&&view.getHeight()>=0,"Invalid view geometry");
        if(view instanceof TextView&&!(view instanceof EditText)){
            TextView text=(TextView)view;
            if(text.getLayout()!=null&&text.getText().length()>0){
                check(text.getLayout().getHeight()<=text.getHeight()-text.getCompoundPaddingTop()-text.getCompoundPaddingBottom()+2,"Clipped text: "+text.getText());
                for(int i=0;i<text.getLineCount();i++)check(text.getLayout().getEllipsisCount(i)==0,"Truncated text: "+text.getText());
            }
        }
        if(view instanceof ViewGroup){ViewGroup group=(ViewGroup)view;
            for(int i=0;i<group.getChildCount();i++){View child=group.getChildAt(i);if(child.getVisibility()!=View.VISIBLE)continue;
                check(child.getLeft()>=0&&child.getRight()<=group.getWidth()+1,"Horizontal overflow in "+group.getClass().getSimpleName());inspect(child);
            }
        }
    }
    private void components(){
        for(float scale:new float[]{1,1.5f,2})for(int width:new int[]{320,360,600}){
            Configuration config=new Configuration(getTargetContext().getResources().getConfiguration());config.fontScale=scale;
            Context context=new ContextThemeWrapper(getTargetContext().createConfigurationContext(config),getTargetContext().getApplicationInfo().theme);
            LinearLayout column=new LinearLayout(context);column.setOrientation(LinearLayout.VERTICAL);
            PlannerUi.Flow actions=new PlannerUi.Flow(context);actions.setPadding(16,8,16,8);
            for(String label:new String[]{"全部完成","部分/未完成","很长的课程操作名称也应该完整换行显示"})actions.addView(PlannerUi.compactButton(context,label,()->{}));column.addView(actions);
            LinearLayout nav=new LinearLayout(context);String[] names={"日历","学习","课程","固定课表","设置"};
            for(int i=0;i<5;i++)nav.addView(PlannerUi.navigationItem(context,i,names[i],i==0,()->{}),new LinearLayout.LayoutParams(0,-1,1));column.addView(nav);
            int pixels=PlannerUi.dp(context,width);column.measure(View.MeasureSpec.makeMeasureSpec(pixels,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(0,View.MeasureSpec.UNSPECIFIED));column.layout(0,0,pixels,column.getMeasuredHeight());inspect(column);
            int iconTop=((ViewGroup)nav.getChildAt(0)).getChildAt(0).getTop();
            for(int i=0;i<nav.getChildCount();i++){
                ViewGroup item=(ViewGroup)nav.getChildAt(i);check(item.getChildAt(0).getTop()==iconTop,"Navigation icons lost alignment");
                check(((TextView)item.getChildAt(1)).getLineCount()==1,"Navigation label wrapped");
            }
            for(int i=0;i<actions.getChildCount();i++){View child=actions.getChildAt(i);check(child.getHeight()>=PlannerUi.dp(context,48),"Action touch height below 48dp");if(i>0){View previous=actions.getChildAt(i-1);check(child.getTop()>=previous.getBottom()||child.getLeft()>=previous.getRight(),"Actions overlap");}}
        }
    }
    private JSONObject fixture()throws Exception{
        JSONObject state=PlannerBackupFile.readLegacyState(getTargetContext().getAssets().open("initial-state.json"));LocalDate day=LocalDate.now(Planner.ZONE);
        for(int i=0;i<2;i++){
            String id="ui-course-"+i;
            state.getJSONArray("courses").put(new JSONObject().put("id",id).put("name",i==0?"高等数学 · 强化训练":"英语 · 阅读与词汇")
                .put("type","录播课程").put("totalMinutes",720).put("initialCompletedMinutes",120).put("startDate",Planner.at(day,0)).put("deadline",Planner.at(day.plusDays(14),0)).put("priority",2).put("minimumBlockMinutes",60).put("color",i==0?"blue":"purple").put("isArchived",false).put("autoScheduleEnabled",true).put("notes",""));
            state.getJSONArray("tasks").put(new JSONObject().put("id","ui-task-"+i).put("courseID",id).put("start",Planner.at(day,900+i*90)).put("durationMinutes",60).put("status","planned").put("completedMinutes",0).put("lessonName",i==0?"第二章：一元函数微分学":"阅读理解 · 长难句分析"));
        }
        state.getJSONArray("fixedEvents").put(new JSONObject().put("id","ui-event").put("title","晚间运动").put("startMinute",1140).put("endMinute",1170).put("startDate",Planner.at(day,0)).put("endDate",Planner.at(day.plusDays(14),0)).put("weekdays",new JSONArray("[1,2,3,4,5,6,7]")).put("excludedDates",new JSONArray()).put("color","orange").put("notes",""));
        Planner.refreshDiagnostics(state,Planner.now());return state;
    }
    private void capture(String name)throws Exception{
        waitForIdleSync();Thread.sleep(300);runOnMainSync(()->inspect(app.root));
        Bitmap bitmap=getUiAutomation().takeScreenshot();check(bitmap!=null,"Screenshot unavailable");
        File folder=new File(getTargetContext().getExternalFilesDir(null),"ui-checks");if(!folder.isDirectory()&&!folder.mkdirs())throw new Exception("Screenshot directory unavailable");
        try(FileOutputStream stream=new FileOutputStream(new File(folder,name+".png"))){bitmap.compress(Bitmap.CompressFormat.PNG,100,stream);}bitmap.recycle();
    }
    private void page(int index)throws Exception{runOnMainSync(()->app.nav.getChildAt(index).performClick());waitForIdleSync();Thread.sleep(500);}
    @Override public void onCreate(Bundle args){super.onCreate(args);arguments=args;start();}
    @Override public void onStart(){Bundle result=new Bundle();int code=-1;
        try{
            check("true".equals(arguments.getString("isolated")),"Pass isolated=true only for a disposable emulator");
            check(Build.HARDWARE.contains("ranchu")||Build.HARDWARE.contains("goldfish"),"Refusing to run fixture on a physical device");
            check(getTargetContext().databaseList().length==0,"Requires fresh application data; use a dedicated emulator");
            runOnMainSync(this::components);
            app=(MainActivity)startActivitySync(new Intent(getTargetContext(),MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));await(()->app.ready&&!app.busy);
            check(main(()->app.state.optJSONArray("courses").length()==0),"Expected blank application");
            runOnMainSync(()->app.handler.removeCallbacks(app.ticker));capture("calendar-empty");
            JSONObject fixture=fixture();runOnMainSync(()->{app.state=fixture;app.render();});capture("calendar");
            click("展开月历");check(main(()->app.calendarExpanded),"Calendar did not expand");capture("calendar-month");click("收起月历");
            page(2);await(()->find(app.root,"高等数学 · 强化训练")!=null);capture("courses");
            click("导入课程");capture("course-import-menu");sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK);
            click("筛选与排序 · "+app.courseScope.title);capture("course-filters");
            runOnMainSync(()->firstInput(app.body).setText("英语"));await(()->find(app.root,"英语 · 阅读与词汇")!=null&&find(app.root,"高等数学 · 强化训练")==null);
            click("清除筛选");await(()->find(app.root,"高等数学 · 强化训练")!=null);
            page(3);await(()->find(app.root,"晚间运动")!=null);capture("events");click("从文字识别");capture("event-recognition");
            page(4);capture("settings");runOnMainSync(()->app.settingsMenu.grid.getChildAt(1).performClick());check(main(()->"display".equals(app.settingsSection)),"Settings route failed");capture("display-settings");
            runOnMainSync(app::onBackPressed);check(main(()->app.settingsSection.isEmpty()),"Settings back failed");
            page(1);capture("learning");page(0);
            // Rendering/navigation must not persist the synthetic courses or tasks.
            check(app.database.load().getJSONArray("courses").length()==0,"Presentation wrote fixture data");
            result.putString("stream","PASS "+checks+" native layout/navigation checks; synthetic screenshots in external files/ui-checks\n");
        }catch(Throwable error){code=1;result.putString("stream","FAIL "+error.getClass().getSimpleName()+": "+error.getMessage()+"\n");}
        finally{if(app!=null)runOnMainSync(app::finish);}
        finish(code,result);
    }
}
