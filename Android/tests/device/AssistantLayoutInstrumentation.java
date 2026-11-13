package local.studyplanner;

import android.app.Instrumentation;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.*;
import android.view.*;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import org.json.*;
import java.io.*;
import java.lang.reflect.Field;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;
import static local.studyplanner.AssistantProtocol.*;

/** Packaged phone layout checks. Only synthetic data in a disposable emulator; no API or vault. */
public final class AssistantLayoutInstrumentation extends Instrumentation {
    AssistantActivity activity;AssistantSession session;Bundle args;int checks;
    void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    boolean main(BooleanSupplier read){AtomicBoolean ok=new AtomicBoolean();runOnMainSync(()->ok.set(read.getAsBoolean()));return ok.get();}
    void await(BooleanSupplier ready)throws Exception{long end=System.currentTimeMillis()+10000;while(System.currentTimeMillis()<end){if(main(ready))return;Thread.sleep(40);}throw new AssertionError("UI did not settle");}
    TextView find(View v,String label){if(v instanceof TextView&&((TextView)v).getText().toString().equals(label))return (TextView)v;if(v instanceof android.view.ViewGroup){ViewGroup g=(ViewGroup)v;for(int i=0;i<g.getChildCount();i++){TextView found=find(g.getChildAt(i),label);if(found!=null)return found;}}return null;}
    void inspect(View v){
        if(v.getVisibility()!=View.VISIBLE)return;
        if(v instanceof TextView&&!(v instanceof EditText)){
            TextView t=(TextView)v;if(t.getLayout()!=null&&t.length()>0)check(t.getLayout().getHeight()<=t.getHeight()-t.getCompoundPaddingTop()-t.getCompoundPaddingBottom()+2,"Text vertically clipped");
        }
        if(v instanceof ViewGroup){ViewGroup g=(ViewGroup)v;for(int i=0;i<g.getChildCount();i++){View child=g.getChildAt(i);if(child.getVisibility()!=View.VISIBLE)continue;
            if(!(g instanceof HorizontalScrollView))check(child.getLeft()>=0&&child.getRight()<=g.getWidth()+1,"Horizontal overflow: "+g.getClass().getSimpleName());inspect(child);}}
    }
    void capture(String name)throws Exception{
        waitForIdleSync();Thread.sleep(150);runOnMainSync(()->{
            inspect(activity.surface);check(activity.composer.getWidth()>0&&activity.send.getHeight()>=activity.dp(48),"Composer touch targets missing");
            int[] input=new int[2],root=new int[2];activity.composer.getLocationInWindow(input);activity.surface.getLocationInWindow(root);
            check(input[1]+activity.composer.getHeight()<=root[1]+activity.surface.getHeight(),"Composer below visible viewport");
            Bitmap b=Bitmap.createBitmap(activity.surface.getWidth(),activity.surface.getHeight(),Bitmap.Config.ARGB_8888);activity.surface.draw(new android.graphics.Canvas(b));
            File dir=new File(getTargetContext().getExternalFilesDir(null),"assistant-layout");dir.mkdirs();
            try(FileOutputStream out=new FileOutputStream(new File(dir,args.getString("prefix","phone")+"-"+name+".png"))){b.compress(Bitmap.CompressFormat.PNG,100,out);}catch(IOException e){throw new RuntimeException(e);}finally{b.recycle();}
        });
    }
    void edit(AssistantSession.Edit action)throws Exception{session.edit(action);session.queue.submit(()->{}).get(10,TimeUnit.SECONDS);waitForIdleSync();}
    public void onCreate(Bundle args){super.onCreate(args);this.args=args;start();}
    public void onStart(){
        Bundle result=new Bundle();int code=-1;Field shared=null;Object old=null;boolean injected=false;File isolated=new File(getTargetContext().getFilesDir(),"assistant-layout-"+System.nanoTime());
        try{
            check("true".equals(args.getString("isolated"))&&(Build.FINGERPRINT.contains("generic")||Build.FINGERPRINT.contains("emulator")||Build.MODEL.startsWith("Android SDK built for")),"Disposable emulator required");
            check(isolated.mkdirs(),"Cannot create test workspace");Contract contract=new Contract(new JSONObject(read(getTargetContext().getAssets().open("assistant-contract.json"),100000)));
            JSONObject empty=PlannerBackupFile.readLegacyState(getTargetContext().getAssets().open("initial-state.json"));
            StateMutation.Store<JSONObject> store=new StateMutation.Store<JSONObject>(){public JSONObject load()throws Exception{return CourseTools.copy(empty);}public void save(JSONObject value){throw new AssertionError("Layout wrote planner data");}};
            session=new AssistantSession(new AssistantHistory(isolated,contract),store,(request,key,token)->{throw new AssertionError("Layout accessed network");},()->{});
            shared=AssistantActivity.class.getDeclaredField("shared");shared.setAccessible(true);synchronized(AssistantActivity.class){old=shared.get(null);shared.set(null,session);injected=true;}
            activity=(AssistantActivity)startActivitySync(new Intent(getTargetContext(),AssistantActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));await(()->activity.state!=null&&activity.state.ready);capture("welcome");
            check(main(()->!activity.send.isEnabled()&&activity.stop.getVisibility()==View.GONE),"Empty composer can send");
            runOnMainSync(()->find(activity.chat,"今天有哪些学习安排？").performClick());check(main(()->activity.question.getText().toString().equals("今天有哪些学习安排？")&&activity.send.isEnabled()),"Suggestion did not fill draft");
            runOnMainSync(()->activity.historyButton.performClick());check(main(()->activity.drawer.isShown()),"History drawer did not open");runOnMainSync(()->activity.onBackPressed());check(main(()->!activity.drawer.isShown()&&activity.question.length()>0&&!activity.isFinishing()),"Back lost draft or exited assistant");
            runOnMainSync(()->activity.newButton.performClick());await(()->activity.state.workspace.optJSONArray("conversations").length()==2&&activity.question.length()==0);
            edit(w->{session.append("你","今天有哪些学习安排？","完成");session.append("助手","## 今天的学习安排\n\n先复习高等数学，再完成英语阅读。\n\n- 09:00–10:00 高等数学\n- 14:00–14:45 英语阅读\n\n需要调整时，可以告诉我希望的时间。","完成");});capture("conversation");
            String chatID=mainID();runOnMainSync(()->activity.historyButton.performClick());capture("history");
            runOnMainSync(()->activity.historyQuery.setText("不匹配的合成关键词"));check(main(()->activity.visibleHistory.isEmpty()),"Search did not filter");
            runOnMainSync(()->activity.historyQuery.setText("高等数学"));check(main(()->activity.visibleHistory.size()==1),"Search did not find message text");
            runOnMainSync(()->{find(activity.drawer,"管理聊天记录").performClick();find(activity.drawer,"全选结果").performClick();});check(main(()->activity.historySelection.contains(chatID)),"History multi-select lost searched conversation");
            runOnMainSync(()->activity.closeHistory());
            session.queue.submit(()->{session.busy=true;session.activity="正在查询日程…";session.publish();}).get(10,TimeUnit.SECONDS);await(()->activity.stop.isShown());
            check(main(()->activity.send.getVisibility()==View.GONE),"Send overlaps stop");runOnMainSync(()->activity.stop.performClick());await(()->!activity.state.busy&&activity.send.isShown());
            session.queue.submit(()->{try{Configuration c=new Configuration(object("provider","openai","baseURL","https://fixture.invalid/v1","model","synthetic-tool-model"));session.approval=new AssistantRunner.Request(c,object("model",c.model,"messages",new JSONArray()),contract,"");session.busy=true;session.message="";session.publish();}catch(Exception e){throw new RuntimeException(e);}}).get(10,TimeUnit.SECONDS);
            await(()->find(activity.chat,"确认本轮发送")!=null);capture("approval");
            session.queue.submit(()->{session.stopInternal();session.message="";session.publish();}).get(10,TimeUnit.SECONDS);await(()->!activity.state.busy);
            session.queue.submit(()->{try{Snapshot shot=new Snapshot(empty,Planner.now());session.change=AssistantActions.execute("preview_add_course",object("name","合成课程","total_minutes","60","start_date",shot.today,"deadline",shot.today,"minimum_block","30"),shot,"E1",false).proposal;session.publish();}catch(Exception e){throw new RuntimeException(e);}}).get(10,TimeUnit.SECONDS);
            await(()->find(activity.chat,"核对全部差异")!=null);capture("proposal");runOnMainSync(()->find(activity.chat,"取消方案").performClick());await(()->activity.state.change==null);
            runOnMainSync(()->{activity.question.setText("把明天的学习调整到下午，保留课程顺序。");activity.question.requestFocus();((InputMethodManager)activity.getSystemService(android.content.Context.INPUT_METHOD_SERVICE)).showSoftInput(activity.question,InputMethodManager.SHOW_IMPLICIT);});
            await(()->activity.getWindow().getDecorView().getRootWindowInsets().isVisible(WindowInsets.Type.ime()));capture("keyboard");
            result.putString("stream","PASS "+checks+" assistant layout/navigation checks; isolated synthetic content, no API or credentials\n");
        }catch(Throwable error){code=1;result.putString("stream","FAIL: "+error.getClass().getSimpleName()+" "+error.getMessage()+"\n");}
        finally{
            if(activity!=null){runOnMainSync(()->{activity.hideKeyboard();activity.finish();});waitForIdleSync();}
            if(session!=null){try{session.queue.submit(()->{}).get(10,TimeUnit.SECONDS);}catch(Exception ignored){}session.queue.shutdownNow();session.network.shutdownNow();}
            if(injected)try{synchronized(AssistantActivity.class){shared.set(null,old);}}catch(Exception ignored){}
            AssistantStartupInstrumentation.delete(isolated);
        }finish(code,result);
    }
    String mainID(){final String[] id={""};runOnMainSync(()->id[0]=activity.selected);return id[0];}
}
