package local.studyplanner;

import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;
import android.text.InputType;
import android.util.AtomicFile;
import android.net.Uri;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;

public class MainActivity extends Activity {
    TextView cloudLabel;
    CloudSettingsPanel cloudPanel;
    SettingsMenu settingsMenu;
    SettingsDraft settingsDraft;
    Checked captureSettingsDraft;
    String restoredSettingsDraft;
    Intent pendingCourseResult;
    LinearLayout syncProgress;
    DeferredRefresh<SyncRead> syncRefresh;
    static final class SyncRead {
        final JSONObject state;final String summary;
        SyncRead(JSONObject state,String summary){this.state=state;this.summary=summary;}
    }
    String settingsSection="";
    String courseQuery="",eventQuery="";int coursePage=0,eventPage=0;Runnable closeCatalog;
    FixedEventCatalog.Scope eventScope=FixedEventCatalog.Scope.CURRENT;
    static final int EXPORT_BACKUP=101,IMPORT_BACKUP=102,SCAN_PAIRING_QR=103,IMPORT_COURSES=104,IMPORT_SSH_KEY=105;
    JSONObject state; String syncSummary=""; LinearLayout root,body,nav; int page=0; LocalDate selected=LocalDate.now(Planner.ZONE),month=selected.withDayOfMonth(1),lastDay=selected;
    final int ink=0xff191919,blue=0xff07c160,muted=0xff555555,bg=0xffededed;
    boolean calendarExpanded=false;DailyConsequenceController consequences;LinearLayout consequencePanel;
    boolean busy=false,ready=false,reviewShown=false; AtomicFile storage; PlannerDatabase database; SyncWindow syncServer; String syncStatus="尚未同步"; TextView syncLabel; ExecutorService worker;Handler handler=new Handler();
    final Runnable ticker=new Runnable(){public void run(){if(ready&&!busy){LocalDate today=LocalDate.now(Planner.ZONE);if(!today.equals(lastDay)){lastDay=today;mutate(s->{},true,null);}else showReviewNotice();}handler.postDelayed(this,30000);}};
    interface Change{void run(JSONObject s)throws Exception;}
    interface Checked{void run()throws Exception;}
    @Override public void onCreate(Bundle b){super.onCreate(b);getWindow().setStatusBarColor(bg);getWindow().setNavigationBarColor(Color.WHITE);getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);storage=new AtomicFile(new File(getFilesDir(),"planner-v1.json"));if(b!=null){pendingCourseResult=b.getParcelable("pendingCourseResult");restoredSettingsDraft=b.getString("studySettingsDraft");selected=LocalDate.parse(b.getString("selected",selected.toString()));month=selected.withDayOfMonth(1);page=b.getInt("page",0);settingsSection=b.getString("settingsSection","");calendarExpanded=b.getBoolean("calendarExpanded",false);month=LocalDate.parse(b.getString("month",month.toString()));}PlannerRuntime runtime=PlannerRuntime.get(this);database=runtime.database;worker=runtime.worker;
        syncRefresh=new DeferredRefresh<>(worker,this::runOnUiThread,()->ready&&!busy&&!isDestroyed(),
            ()->{JSONObject latest=database.load();Planner.refreshDiagnostics(latest,Planner.now());return new SyncRead(latest,syncSummary(database.metadata()));},
            latest->{state=latest.state;syncSummary=latest.summary;render();resumeCourseResult();},
            error->{syncStatus="读取同步结果失败："+error.getMessage();updateSyncLabel();},this::updateSyncProgress);

        consequences=new DailyConsequenceController(this);
        syncServer=new SyncWindow(this,message->{syncStatus=message;updateSyncLabel();});
        IntentFilter filter=new IntentFilter(SyncWindowService.ACTION_STATUS);
        filter.addAction(CloudSync.ACTION);
        if(Build.VERSION.SDK_INT>=33)registerReceiver(syncReceiver,filter,Context.RECEIVER_NOT_EXPORTED);else registerReceiver(syncReceiver,filter);
        TextView loading=new TextView(this);loading.setText("正在打开本地日程…");setContentView(loading);
        worker.execute(()->{try{
            JSONObject loaded;
            synchronized(database){
            if(database.initialized())loaded=database.load();
            else{if(storage.getBaseFile().exists()||new File(storage.getBaseFile()+".bak").exists())loaded=new JSONObject(read(storage.openRead()));else loaded=new JSONObject(read(getAssets().open("initial-state.json")));}
            Planner.prepareForOpen(loaded,Planner.now());database.save(loaded);
            }
            JSONObject finalState=loaded;String summary=syncSummary(database.metadata());runOnUiThread(()->{if(isDestroyed())return;state=finalState;syncSummary=summary;ready=true;render();resumeSyncRefresh();handler.postDelayed(ticker,1000);syncServer.start(false,false);CloudSync.get(this).start();});
        }catch(Exception e){runOnUiThread(()->errorScreen(e));}});
    }
    @Override protected void onResume(){super.onResume();if(ready&&syncServer!=null){refreshSyncData();syncStatus=SyncWindowService.lastStatus;updateSyncLabel();syncServer.start(false,false);CloudSync.get(this).start();}}
    // A bounded foreground service owns the window; onStop must not invalidate pairing.

    @Override public void onSaveInstanceState(Bundle b){
        super.onSaveInstanceState(b);
        if(pendingCourseResult!=null)b.putParcelable("pendingCourseResult",pendingCourseResult);
        try{
            if(captureSettingsDraft!=null)captureSettingsDraft.run();
            if(settingsDraft!=null&&settingsDraft.isDirty())b.putString("studySettingsDraft",settingsDraft.snapshot().toString());
            else if(restoredSettingsDraft!=null)b.putString("studySettingsDraft",restoredSettingsDraft);
        }catch(Exception error){android.util.Log.w("StudyPlanner","Unable to retain settings draft",error);}
        b.putString("selected",selected.toString());b.putInt("page",page);b.putString("settingsSection",settingsSection);
        b.putBoolean("calendarExpanded",calendarExpanded);b.putString("month",month.toString());
    }
    @Override public void onDestroy(){if(closeCatalog!=null)closeCatalog.run();if(syncRefresh!=null)syncRefresh.close();handler.removeCallbacks(ticker);if(consequences!=null)consequences.close();unregisterReceiver(syncReceiver);super.onDestroy();}
    @Override public void onBackPressed(){if(busy){Toast.makeText(this,"正在保存，请稍后",Toast.LENGTH_SHORT).show();return;}if(page==3&&!settingsSection.isEmpty()&&settingsMenu!=null){settingsMenu.show("");}else if(page!=0){page=0;render();}else super.onBackPressed();}
    static String read(InputStream stream)throws Exception{try(InputStream in=stream;ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1)out.write(b,0,n);return out.toString("UTF-8");}}

    void errorScreen(Exception e){TextView t=new TextView(this);t.setPadding(30,60,30,30);t.setText("无法打开本地日程\n\n"+e.getMessage()+"\n\n已有数据未被覆盖。请保留应用数据后重试。");setContentView(t);}
    void alert(String title,String message){new AlertDialog.Builder(this).setTitle(title).setMessage(message).setPositiveButton("知道了",null).show();}
    void run(Checked c){try{c.run();}catch(Exception e){alert("请检查",e.getMessage());}}
    void mutate(Change change,boolean replan,Runnable done){mutate(change,replan,done,null);}
    void mutate(Change change,boolean replan,Runnable done,java.util.function.Consumer<Exception> failure){
        if(busy)return;
        busy=true;ProgressDialog progress=new ProgressDialog(this);
        progress.setMessage(replan?"正在保存并重新安排学习任务…":"正在保存…");progress.setCancelable(false);progress.show();
        worker.execute(()->{try{
            JSONObject next=database.update(latest->{
                change.run(latest);
                if(replan)Planner.replan(latest,Planner.now());else Planner.refreshDiagnostics(latest,Planner.now());
            });
            runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;
                state=next;if(done!=null)done.run();render();resumeSyncRefresh();
            });
        }catch(Exception error){runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;
            if(failure!=null)failure.accept(error);else alert("操作未保存",error.getMessage());
            // Reload after conflicts as well as I/O failures; modal editor drafts stay open.
            refreshSyncData();
        });}});
    }
    void swapDailyTasks(String source,String target){
        if(busy)return;
        run(()->{
            JSONObject before=state;DailyTaskSwapDraft draft=new DailyTaskSwapDraft(state,source,target,Planner.now());
            Planner.validate(draft.preview);busy=true;state=draft.preview;render();
            worker.execute(()->{try{
                JSONObject fresh=database.update(latest->{double now=Planner.now();draft.apply(latest,now);Planner.refreshDiagnostics(latest,now);});
                runOnUiThread(()->{state=fresh;busy=false;if(!isDestroyed()){render();resumeSyncRefresh();}});
            }catch(Exception error){
                JSONObject latest=before;try{latest=database.load();}catch(Exception ignored){}
                final JSONObject restored=latest;
                runOnUiThread(()->{state=restored;busy=false;if(!isDestroyed()){render();alert("交换未保存",error.getMessage());resumeSyncRefresh();}});
            }});
        });
    }
    void resumeCourseResult(){
        if(!ready||busy||isDestroyed()||pendingCourseResult==null)return;
        Intent data=pendingCourseResult;pendingCourseResult=null;run(()->receiveCourses(data));
    }
    void receiveCourses(Intent data)throws Exception{
        if(!ready||busy){pendingCourseResult=new Intent(data);return;}
        String courseID=data.getStringExtra("courseID");
        if(courseID!=null){JSONObject course=Planner.course(state,courseID);if(course==null)throw new Exception("该课程已删除。");page=1;render();courseEditor(course);return;}
        String path=data.getStringExtra("captureFile");if(path==null)throw new Exception("导入结果缺失");
        CourseImportReceipt receipt=new CourseImportReceipt(getCacheDir(),path);
        busy=true;ProgressDialog progress=ProgressDialog.show(this,"","正在读取并保存课程…",true,false);
        worker.execute(()->{try{
            CourseImportReceipt.Result saved=receipt.commit(database,Planner::now,data.getByteArrayExtra("captureReviewFingerprint"),
                data.hasExtra("captureReviewDeadline")?data.getDoubleExtra("captureReviewDeadline",Double.NaN):null);
            runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;
                state=saved.state;page=1;render();if(!saved.removed)alert("课程已导入","课程已保存，但临时导入文件未能清理。请勿重复导入同一份旧结果。");resumeSyncRefresh();
            });
        }catch(Exception error){boolean retained=receipt.exists();runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;
            AlertDialog.Builder notice=new AlertDialog.Builder(this).setTitle("导入未保存").setMessage(error.getMessage()+(retained?"\n抓取结果仍保留，可重试，也可稍后从课程页继续未完成导入。":"\n没有可重试的临时文件，请重新抓取课程。")).setNegativeButton("关闭",null);
            if(retained)notice.setPositiveButton("重试导入",(d,w)->run(()->receiveCourses(data)));notice.show();refreshSyncData();
        });}});
    }
    void pendingCourseImports(){
        if(busy||!ready)return;busy=true;
        worker.execute(()->{List<File> files=CourseImportReceipt.pending(getCacheDir());runOnUiThread(()->{
            busy=false;if(isDestroyed())return;
            if(files.isEmpty())alert("未完成的导入","没有待继续的抓取结果。临时文件可能被系统清理；如有需要，请重新抓取课程。");
            else{
                String[] labels=new String[files.size()];java.text.SimpleDateFormat format=new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm",Locale.CHINA);format.setTimeZone(java.util.TimeZone.getTimeZone(Planner.ZONE));
                for(int i=0;i<labels.length;i++)labels[i]=format.format(new java.util.Date(files.get(i).lastModified()))+" · "+files.get(i).length()/1024+" KB";
                new AlertDialog.Builder(this).setTitle("选择未完成的导入").setItems(labels,(d,index)->reviewPendingCourseImport(files.get(index))).setNegativeButton("取消",null).show();
            }
            resumeSyncRefresh();
        });});
    }
    void reviewPendingCourseImport(File file){
        if(busy||!ready)return;busy=true;ProgressDialog progress=ProgressDialog.show(this,"","正在读取待导入课程…",true,false);
        worker.execute(()->{try{
            CourseImportReceipt.Preview preview=new CourseImportReceipt(getCacheDir(),file.getAbsolutePath()).preview();
            runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;showPendingCourseImport(file,preview);resumeSyncRefresh();});
        }catch(Exception error){runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;alert("无法预览导入",error.getMessage()+"\n没有修改日程。");resumeSyncRefresh();});}});
    }
    void showPendingCourseImport(File file,CourseImportReceipt.Preview preview){
        LinearLayout form=col(),rows=col();form.setPadding(dp(16),0,dp(16),0);
        form.addView(text(preview.count()+" 门课程 · 总量 "+hours(preview.totalMinutes)+"\n已有课程保留当前起止日期和本地学习记录；保存时再次检查课程更新。",13,muted));
        EditText deadline=dateField(form,"新课程截止日期（可调整）",preview.deadline);
        if(LocalDate.parse(preview.deadline).isBefore(LocalDate.now(Planner.ZONE)))form.addView(text("原截止日期已过期，请先调整后继续导入。",13,0xffa56618));
        TextView position=text("",12,muted);form.addView(position);ScrollView scroll=new ScrollView(this);scroll.addView(rows);form.addView(scroll,new LinearLayout.LayoutParams(-1,dp(300)));
        PlannerUi.Flow navigation=new PlannerUi.Flow(this);form.addView(navigation);int[] page={0};Button[] buttons=new Button[2];
        Runnable render=()->{rows.removeAllViews();position.setText("第 "+(page[0]+1)+" / "+preview.pageCount()+" 页");
            for(String description:preview.page(page[0]))rows.addView(text(description,14,ink));
            buttons[0].setEnabled(page[0]>0);buttons[1].setEnabled(page[0]+1<preview.pageCount());scroll.scrollTo(0,0);
        };
        buttons[0]=button("上一页",()->{page[0]--;render.run();});buttons[1]=button("下一页",()->{page[0]++;render.run();});navigation.addView(buttons[0]);navigation.addView(buttons[1]);render.run();
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("核对未完成的导入").setView(form).setNegativeButton("暂不导入",null)
            .setPositiveButton("继续导入",null)
            .setNeutralButton("删除这份结果",null).create();
        dialog.setOnShowListener(d->{
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{if(busy)return;run(()->{
                double desired=dateValue(deadline);LocalDate chosen=Planner.day(desired),today=LocalDate.now(Planner.ZONE);
                if(chosen.isBefore(today)||chosen.isAfter(today.plusYears(10)))throw new IllegalArgumentException("截止日期须在今天起十年以内，请调整后再导入。");
                receiveCourses(new Intent().putExtra("captureFile",file.getAbsolutePath())
                    .putExtra("captureReviewFingerprint",preview.fingerprint()).putExtra("captureReviewDeadline",desired));dialog.dismiss();
            });});
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v->{
            if(busy)return;
            new AlertDialog.Builder(this).setTitle("删除这份未完成的导入？")
                .setMessage("这份抓取结果包含 "+preview.count()+" 门课程。删除后需要重新抓取；已经保存的课程、进度和日程不会删除。")
                .setNegativeButton("保留",null).setPositiveButton("删除临时结果",(confirm,w)->discardCourseImport(file,preview,dialog)).show();
        });});dialog.show();
    }
    void discardCourseImport(File file,CourseImportReceipt.Preview preview,AlertDialog review){
        if(busy)return;busy=true;ProgressDialog progress=ProgressDialog.show(this,"","正在删除临时抓取结果…",true,false);
        worker.execute(()->{try{
            boolean removed=new CourseImportReceipt(getCacheDir(),file.getAbsolutePath()).discard(preview.fingerprint());
            runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;review.dismiss();
                alert("未完成的导入",removed?"这份临时抓取结果已删除，已保存的日程未改动。":"这份临时结果已不存在，已保存的日程未改动。");resumeSyncRefresh();
            });
        }catch(Exception error){runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;alert("未删除导入结果",error.getMessage());resumeSyncRefresh();});}});
    }
    int dp(int n){return (int)(n*getResources().getDisplayMetrics().density+.5f);}
    LinearLayout col(){LinearLayout v=new LinearLayout(this);v.setOrientation(1);return v;}
    LinearLayout row(){LinearLayout v=new LinearLayout(this);v.setOrientation(0);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    GradientDrawable rounded(int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;}
    TextView text(String s,int size,int color){TextView t=new TextView(this);t.setText(s);t.setTextSize(size>=12&&size<15?15:size);t.setTypeface(Typeface.create("sans-serif",Typeface.NORMAL));t.setLineSpacing(dp(2),1.08f);t.setTextColor(color);t.setPadding(0,dp(4),0,dp(4));return t;}
    TextView title(String s){TextView t=text(s,20,ink);t.setTypeface(null,Typeface.BOLD);return t;}
    Button button(String s,Runnable action){return PlannerUi.compactButton(this,s,()->{if(!busy)action.run();});}
    void weighted(LinearLayout r,View v){r.addView(v,new LinearLayout.LayoutParams(0,-2,1));}
    LinearLayout card(LinearLayout p){LinearLayout c=col();c.setPadding(dp(16),dp(12),dp(16),dp(12));c.setBackground(rounded(Color.WHITE,16));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.setMargins(0,dp(7),0,dp(7));p.addView(c,lp);return c;}
    void cardBorder(LinearLayout box,int tint){GradientDrawable background=rounded(Color.WHITE,16);background.setStroke(dp(2),tint);box.setBackground(background);}
    void render(){
        if(!ready)return;
        try{if(captureSettingsDraft!=null)captureSettingsDraft.run();}catch(Exception error){alert("草稿未刷新",error.getMessage());return;}
        captureSettingsDraft=null;settingsMenu=null;
        if(closeCatalog!=null){closeCatalog.run();closeCatalog=null;}
        consequences.refresh(state);consequencePanel=null;
        root=col();root.setBackgroundColor(bg);root.setFitsSystemWindows(true);setContentView(root);
        if(page!=0){LinearLayout top=row();top.setPadding(dp(18),dp(12),dp(18),dp(8));top.addView(title("学习日程"));root.addView(top);}
        syncProgress=row();syncProgress.setPadding(dp(18),dp(6),dp(18),dp(6));ProgressBar syncSpinner=new ProgressBar(this);syncProgress.addView(syncSpinner,new LinearLayout.LayoutParams(dp(22),dp(22)));syncProgress.addView(text("  正在同步中",15,blue));root.addView(syncProgress);updateSyncProgress();
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);body=col();body.setPadding(dp(12),dp(8),dp(12),dp(20));scroll.addView(body);root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        View divider=new View(this);divider.setBackgroundColor(0xffdcdcdc);root.addView(divider,new LinearLayout.LayoutParams(-1,dp(1)));
        nav=row();nav.setPadding(0,dp(5),0,dp(5));nav.setBackgroundColor(0xfff7f7f7);
        String[] labels={"日历","课程","固定课表","设置","学习"};
        int[] pages={0,4,1,2,3};
        for(int i:pages){
            final int n=i;boolean active=i==page;LinearLayout tab=col();tab.setGravity(Gravity.CENTER);tab.setPadding(0,dp(3),0,dp(3));
            tab.addView(new PlannerUi.Icon(this,i==4?5:i,active?blue:ink),new LinearLayout.LayoutParams(dp(25),dp(25)));
            TextView label=text(labels[i],11,active?blue:ink);label.setGravity(Gravity.CENTER);tab.addView(label);
            tab.setSelected(active);tab.setContentDescription(labels[i]+(active?"，已选中":""));tab.setFocusable(true);
            tab.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0xffdddddd),null,null));
            tab.setOnClickListener(v->{if(!busy){page=n;render();}});nav.addView(tab,new LinearLayout.LayoutParams(0,-2,1));
        }
        root.addView(nav);try{if(page==0)calendar();else if(page==1)courses();else if(page==2)events();else if(page==4)learning();else settings();}catch(Exception e){alert("显示失败",e.getMessage());}
    }
    void calendarSearch(){
        LinearLayout search=row();search.setGravity(Gravity.CENTER);search.setPadding(dp(12),dp(8),dp(12),dp(8));search.setBackground(rounded(Color.WHITE,8));
        search.addView(new PlannerUi.Icon(this,4,muted),new LinearLayout.LayoutParams(dp(18),dp(18)));
        TextView label=text("  搜索",16,muted);search.addView(label);search.setMinimumHeight(dp(44));search.setFocusable(true);search.setContentDescription("搜索课程或课时，查找安排日期");
        search.setOnClickListener(v->{if(!busy)new PlannerFeatures(this).search();});body.addView(search,new LinearLayout.LayoutParams(-1,-2));
    }
    void moveCalendar(int direction){
        if(calendarExpanded){month=month.plusMonths(direction);selected=month.withDayOfMonth(Math.min(selected.getDayOfMonth(),month.lengthOfMonth()));}
        else{selected=selected.plusWeeks(direction);month=selected.withDayOfMonth(1);}render();
    }
    Button pill(String label,Runnable action){return button(label,action);}
    Button taskAction(String label,Runnable action){Button b=pill(label,action);b.setPadding(dp(8),dp(4),dp(8),dp(4));return b;}
    int color(String c){switch(c){case "green":return 0xff168875;case "purple":return 0xff8b60ba;case "orange":return 0xffc17d30;case "pink":return 0xffc45f92;default:return 0xff2766c3;}}
    String hours(long n){return String.format(Locale.CHINA,"%.1f 小时",n/60.0);}
    void calendar()throws Exception{
        calendarSearch();
        LinearLayout c=card(body),bar=row();weighted(bar,title(month.getYear()+" 年 "+month.getMonthValue()+" 月"));bar.addView(pill("今天",()->{selected=LocalDate.now(Planner.ZONE);month=selected.withDayOfMonth(1);render();}));bar.addView(pill("‹",()->moveCalendar(-1)));bar.addView(pill("›",()->moveCalendar(1)));c.addView(bar);
        Set<LocalDate> marked=new HashSet<>();for(JSONObject t:Planner.list(state.getJSONArray("tasks")))marked.add(Planner.day(t.getDouble("start")));LinearLayout week=row();for(String w:new String[]{"一","二","三","四","五","六","日"}){TextView v=text(w,12,muted);v.setGravity(Gravity.CENTER);weighted(week,v);}c.addView(week);
        int offset=month.getDayOfWeek().getValue()-1;LocalDate first=calendarExpanded?month.minusDays(offset):selected.minusDays(selected.getDayOfWeek().getValue()-1);for(int r=0;r<(calendarExpanded?6:1);r++){LinearLayout rr=row();for(int j=0;j<7;j++){LocalDate d=first.plusDays(r*7+j);boolean mark=marked.contains(d);if(!mark)for(JSONObject e:Planner.list(state.getJSONArray("fixedEvents")))if(Planner.occurs(e,d)){mark=true;break;}TextView v=text(d.getDayOfMonth()+(mark?"\n·":"\n "),14,d.getMonth()==month.getMonth()?ink:0xffb2b2b2);v.setGravity(Gravity.CENTER);v.setMinHeight(dp(43));v.setContentDescription(d.toString()+(mark?" 有安排":""));v.setSelected(d.equals(selected));if(d.equals(selected)){v.setTextColor(Color.WHITE);v.setBackground(rounded(blue,10));}else if(d.equals(LocalDate.now(Planner.ZONE)))v.setTextColor(blue);v.setOnClickListener(x->{selected=d;month=d.withDayOfMonth(1);render();});weighted(rr,v);}c.addView(rr);if(!first.plusDays((r+1)*7).isBefore(month.plusMonths(1)))break;}
        Button toggle=pill(calendarExpanded?"收起月历 ∧":"展开月历 ∨",()->{calendarExpanded=!calendarExpanded;month=selected.withDayOfMonth(1);render();});
        LinearLayout.LayoutParams toggleParams=new LinearLayout.LayoutParams(-2,-2);toggleParams.gravity=Gravity.CENTER_HORIZONTAL;c.addView(toggle,toggleParams);
        LinearLayout head=row();weighted(head,title(selected.getMonthValue()+" 月 "+selected.getDayOfMonth()+" 日 · "+new String[]{"一","二","三","四","五","六","日"}[selected.getDayOfWeek().getValue()-1]));head.addView(button("‹",()->{selected=selected.minusDays(1);month=selected.withDayOfMonth(1);render();}));head.addView(button("›",()->{selected=selected.plusDays(1);month=selected.withDayOfMonth(1);render();}));body.addView(head);
        List<JSONObject> tasks=new ArrayList<>(),events=new ArrayList<>();int planned=0;for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(Planner.day(t.getDouble("start")).equals(selected)){JSONObject owner=Planner.course(state,t.getString("courseID"));if(!owner.optBoolean("isArchived")||!Planner.pending(t)){tasks.add(t);if(Planner.pending(t))planned+=t.getInt("durationMinutes");}}for(JSONObject e:Planner.list(state.getJSONArray("fixedEvents")))if(Planner.occurs(e,selected))events.add(e);String confirmedText;
        try{confirmedText=hours(DailyConsequences.confirmed(selected,state));}
        catch(DailyConsequences.CalculationException e){confirmedText="无法计算（分钟数合计超出范围，记录已保留）";}
        body.addView(text("待学 "+hours(planned)+"   已确认 "+confirmedText+"   固定 "+events.size()+" 项",12,muted));
        List<JSONObject> timeline=new ArrayList<>(events);for(JSONObject t:tasks)if(Planner.pending(t))timeline.add(t);timeline.sort(Comparator.comparingDouble(t->t.has("courseID")?t.optDouble("start"):Planner.at(selected,t.optInt("startMinute"))));for(JSONObject item:timeline){if(item.has("courseID"))taskCard(body,item);else eventCard(body,item,false);}if(timeline.isEmpty())card(body).addView(text("这一天没有待进行的安排",15,muted));boolean label=false;for(JSONObject t:tasks)if(!Planner.pending(t)){if(!label){body.addView(title("完成记录"));label=true;}taskCard(body,t);}for(JSONObject e:Planner.list(state.getJSONArray("fixedEvents")))if(Planner.occurs(e,selected,true)&&!Planner.occurs(e,selected)){
            LinearLayout skipped=card(body);cardBorder(skipped,color(e.optString("color","orange")));skipped.addView(text(e.optString("title")+" · 本日已临时移除",16,muted));
            skipped.addView(text(Planner.time(e.optInt("startMinute"))+" — "+Planner.time(e.optInt("endMinute"))+" · 本日不占用时间，其他日期照常安排",12,muted));
            final LocalDate date=selected;
            if(!date.isBefore(LocalDate.now(Planner.ZONE)))skipped.addView(pill("恢复本日并重排",()->mutate(s->FixedEventEditing.setSkipped(s,e,date,false,Planner.now()),true,null)));
        }
    }
    void learning()throws Exception{
        body.addView(title("学习概览"));
        List<JSONObject> review=Planner.review(state,Planner.now());if(!review.isEmpty())body.addView(pill("学习完成确认 · "+review.size()+" 项待确认",this::review));
        new PlannerFeatures(this).overview();
        consequencePanel=col();body.addView(consequencePanel);new DailyConsequencesView(this).render(consequencePanel);
        if(state.getJSONArray("courses").length()==0&&state.getJSONArray("fixedEvents").length()==0&&state.getJSONArray("tasks").length()==0&&state.getJSONArray("completions").length()==0)body.addView(button("载入示例，体验自动排程",()->new PlannerFeatures(this).sample()));
        LinearLayout startCard=card(body);startCard.addView(title("今日实际开课时间"));
        double inputNow=Planner.now();Double actualStart=Planner.actualStudyStart(state,inputNow);
        EditText startTime=field(startCard,"开始时间（HH:mm）",Planner.clock(actualStart==null?inputNow:actualStart),false);
        startCard.addView(text("从这个时间重排今天的未确认课程及后续日期，保留固定事项和已确认进度。每天可重新输入，仅对今天生效。",13,muted));
        if(actualStart!=null)startCard.addView(text("已按 "+Planner.clock(actualStart)+" 更新今天及后续课表",13,ink));
        startCard.addView(button("生成新课表",()->run(()->{int minute=Planner.minute(value(startTime));if(minute>=1440)throw new Exception("实际开课时间须为 00:00–23:59");mutate(s->Planner.recordActualStudyStart(s,minute,Planner.now()),true,()->{selected=LocalDate.now(Planner.ZONE);month=selected.withDayOfMonth(1);});})));
        body.addView(pill("重新排程",()->mutate(s->{},true,null)));
    }
    void taskCard(LinearLayout parent,JSONObject t)throws Exception{
        JSONObject c=Planner.course(state,t.getString("courseID"));
        LinearLayout box=card(parent);cardBorder(box,color(c.optString("color")));
        if(Planner.floatingTask(t))floatingStyle(box,color(c.optString("color")));
        box.addView(text((Planner.floatingTask(t)?"预估 ":"")+Planner.clock(t.getDouble("start"))+" — "+Planner.clock(Planner.end(t))+"   "+t.getInt("durationMinutes")+" 分钟"+(Planner.floatingTask(t)?" · 按当前顺序预估":""),12,muted));
        if(Planner.floatingTask(t))box.addView(text("完成窗口："+Planner.clock(Planner.planningStart(t))+"–"+Planner.clock(Planner.planningEnd(t))+" · 顺序调整后预估时间更新",12,muted));
        TextView name=text(c.getString("name"),18,ink);name.setTypeface(null,Typeface.BOLD);box.addView(name);
        if(!t.optString("lessonName").isEmpty())box.addView(text(t.optString("lessonName"),16,ink));
        if(Planner.pending(t)){
            PlannerUi.Flow actions=new PlannerUi.Flow(this);
            actions.addView(taskAction(Planner.planningStart(t)>Planner.now()?"提前完成":"全部完成",()->run(()->confirmTasks(new ConfirmationDraft(Collections.singletonList(t)),Collections.singletonMap(t.getString("id"),t.getInt("durationMinutes")),Collections.singletonMap(t.getString("id"),Planner.day(Planner.now())),null))));
            actions.addView(taskAction("部分/未完成",()->completion(t)));
            box.addView(actions);
            new PlannerFeatures(this).taskDrag(box,actions,t);
        }else{
            ConfirmationDraft.Undo undo=new ConfirmationDraft.Undo(state,t);
            LinearLayout result=row();
            weighted(result,text(t.optString("status").equals("missed")?"未完成 · 已保留剩余学习量":"已确认 "+t.optInt("completedMinutes")+" 分钟",13,muted));
            result.addView(pill("撤销",()->mutate(s->undo.apply(s,Planner.now()),true,null)));
            box.addView(result);
        }
    }
    void confirmTasks(ConfirmationDraft draft,Map<String,Integer> minutes,Map<String,LocalDate> studyDates,Runnable done){
        // Copy all widget values on the UI thread; the worker only touches immutable inputs.
        Map<String,Integer> filled=new LinkedHashMap<>(minutes);Map<String,LocalDate> dates=new LinkedHashMap<>(studyDates);
        mutate(s->{double now=Planner.now();if(draft.apply(s,filled,dates,now))Planner.replan(s,now);},false,done);
    }
    void completion(JSONObject t){run(()->{
        ConfirmationDraft draft=new ConfirmationDraft(Collections.singletonList(t));String id=t.getString("id");
        LinearLayout form=col();form.setPadding(dp(20),dp(8),dp(20),0);
        EditText actual=field(form,"实际完成分钟（0 = 未完成）",""+t.optInt("durationMinutes"),true);
        EditText studyDate=dateField(form,"实际学习日期（补录请核对）",Planner.date(Math.min(t.optDouble("start"),Planner.now())));
        AlertDialog d=new AlertDialog.Builder(this).setTitle("确认学习进度").setView(form).setNegativeButton("取消",null).setPositiveButton("确认",null).create();
        d.setOnShowListener(v->d.getButton(-1).setOnClickListener(x->run(()->{
            int n=Integer.parseInt(value(actual));LocalDate date=LocalDate.parse(value(studyDate));
            confirmTasks(draft,Collections.singletonMap(id,n),Collections.singletonMap(id,date),d::dismiss);
        })));d.show();
    });}
    void review(){run(()->{
        double now=Planner.now();List<JSONObject> displayed=Planner.review(state,now);
        if(displayed.isEmpty()){alert("学习完成确认","当前没有待确认的任务。");return;}
        ConfirmationReview review=new ConfirmationReview(state,displayed,now);int[] page={0};Button[] buttons=new Button[2];
        LinearLayout form=col(),list=col();form.setPadding(dp(16),0,dp(16),dp(8));
        form.addView(text("留空不处理，翻页保留输入。保存会提交所有页面已填写的项目。",13,muted));TextView position=text("",12,muted);form.addView(position);
        ScrollView sv=new ScrollView(this);sv.addView(list);form.addView(sv,new LinearLayout.LayoutParams(-1,dp(340)));
        PlannerUi.Flow navigation=new PlannerUi.Flow(this);form.addView(navigation);
        Map<String,EditText> values=new LinkedHashMap<>(),studyDates=new LinkedHashMap<>();
        Runnable capture=()->{for(ConfirmationReview.Row row:review.page(page[0])){row.minutes=value(values.get(row.id));row.studyDate=value(studyDates.get(row.id));}};
        Runnable render=()->{
            list.removeAllViews();values.clear();studyDates.clear();position.setText("共 "+review.count()+" 项 · 第 "+(page[0]+1)+" / "+review.pageCount()+" 页");
            for(ConfirmationReview.Row row:review.page(page[0])){
                EditText minutes=field(list,row.label(),row.minutes,true);minutes.setHint("留空暂不确认，0 表示未完成");values.put(row.id,minutes);
                studyDates.put(row.id,dateField(list,"实际学习日期（补录请核对）",row.studyDate));
            }
            buttons[0].setEnabled(page[0]>0);buttons[1].setEnabled(page[0]+1<review.pageCount());sv.scrollTo(0,0);
        };
        buttons[0]=button("上一页",()->{capture.run();page[0]--;render.run();});buttons[1]=button("下一页",()->{capture.run();page[0]++;render.run();});navigation.addView(buttons[0]);navigation.addView(buttons[1]);render.run();
        AlertDialog d=new AlertDialog.Builder(this).setTitle("逐项确认实际学习分钟").setView(form).setNegativeButton("稍后",null).setPositiveButton("保存所有已填写项",null).create();
        d.setOnShowListener(v->d.getButton(-1).setOnClickListener(x->run(()->{
            capture.run();ConfirmationReview.Submission submission;
            try{submission=review.submission(Planner.now());}catch(ConfirmationReview.InputError error){page[0]=error.index/ConfirmationReview.PAGE_SIZE;render.run();throw error;}
            confirmTasks(review.draft,submission.minutes,submission.dates,d::dismiss);
        })));d.show();
    });}
    void showReviewNotice(){if(!reviewShown&&!Planner.review(state,Planner.now()).isEmpty()){reviewShown=true;render();}}
    void courses()throws Exception{body.addView(title("课程管理"));CompressedPreviewPanel.render(this,body);body.addView(text("学习量、截止日期与课程进度",13,muted));PlannerUi.Flow courseActions=new PlannerUi.Flow(this);body.addView(courseActions);courseActions.addView(button("＋ 添加课程",()->courseEditor(null)));new PlannerFeatures(this).coursesHeader(courseActions);new PlannerFeatures(this).courseCatalog(body);}
    void courseCard(LinearLayout parent,JSONObject c,int done)throws Exception{LinearLayout box=card(parent);cardBorder(box,color(c.optString("color")));TextView courseName=text(c.getString("name"),19,ink);courseName.setTypeface(null,Typeface.BOLD);box.addView(courseName);int total=c.getInt("totalMinutes");box.addView(text(hours(done)+" / "+hours(total)+" · 截止 "+Planner.date(c.getDouble("deadline")),13,muted));ProgressBar p=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);p.setMax(Math.max(1,total));p.setProgress(done);box.addView(p);int days=(int)Math.max(1,java.time.temporal.ChronoUnit.DAYS.between(LocalDate.now(Planner.ZONE),Planner.day(c.getDouble("deadline")))+1);box.addView(text("剩余 "+hours(Math.max(0,total-done))+" · 按截止日期日均约 "+(int)Math.ceil(Math.max(0,total-done)/(double)days)+" 分钟（不含每日加量）",13,muted));if(!c.optString("notes").isEmpty())box.addView(text(c.optString("notes"),13,ink));new PlannerFeatures(this).dailyWeightControl(box,c);PlannerUi.Flow actions=new PlannerUi.Flow(this);box.addView(actions);if("不定时录播课程".equals(c.optString("type")))actions.addView(button("调整课节顺序",()->new PlannerFeatures(this).lessonOrder(c)));actions.addView(button("编排预览",()->run(()->new PlannerFeatures(this).preview(next->c.getString("id")))));if(c.optJSONObject("netdisk")!=null)actions.addView(button("网盘课节与文件",()->new PlannerFeatures(this).netdiskFiles(c)));actions.addView(button("编辑课程",()->courseEditor(c)));}
    EditText field(LinearLayout p,String label,String value,boolean number){p.addView(text(label,13,muted));EditText e=new EditText(this);e.setText(value);e.setTextSize(16);e.setSingleLine(true);e.setPadding(dp(6),dp(8),dp(6),dp(8));if(number)e.setInputType(InputType.TYPE_CLASS_NUMBER|InputType.TYPE_NUMBER_FLAG_DECIMAL);p.addView(e,new LinearLayout.LayoutParams(-1,-2));return e;}
    EditText dateField(LinearLayout p,String label,String value){EditText e=field(p,label,value,false);e.setFocusable(false);e.setOnClickListener(v->{LocalDate d=LocalDate.parse(e.getText().toString());new DatePickerDialog(this,(picker,y,m,day)->e.setText(LocalDate.of(y,m+1,day).toString()),d.getYear(),d.getMonthValue()-1,d.getDayOfMonth()).show();});return e;}
    Spinner spinner(LinearLayout p,String label,String[] options,int selected){p.addView(text(label,13,muted));Spinner v=new Spinner(this);ArrayAdapter<String> a=new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,options);v.setAdapter(a);v.setSelection(Math.max(0,selected));p.addView(v);return v;}
    AlertDialog editor(String title,LinearLayout form){ScrollView sv=new ScrollView(this);form.setPadding(dp(22),dp(8),dp(22),dp(24));sv.addView(form);return new AlertDialog.Builder(this).setTitle(title).setView(sv).setNegativeButton("取消",null).setPositiveButton("保存",null).create();}
    String value(EditText e){return e.getText().toString().trim();}int integer(EditText e){return Integer.parseInt(value(e));}double dateValue(EditText e){return Planner.at(LocalDate.parse(value(e)),0);}int minutes(EditText e){double n=Double.parseDouble(value(e));if(!Double.isFinite(n)||n<0||n>100000)throw new IllegalArgumentException("小时数应在 0–100000 之间");return (int)Math.round(n*60);}
    List<String> movedLessons(List<String> order,Set<String> selected,int before){List<String> picked=new ArrayList<>(),rest=new ArrayList<>();int removed=0;for(int i=0;i<order.size();i++){String id=order.get(i);if(selected.contains(id)){picked.add(id);if(i<before)removed++;}else rest.add(id);}rest.addAll(Math.max(0,Math.min(rest.size(),before-removed)),picked);return rest;}
    String manualLessonText(JSONObject course){JSONArray lessons=course.optJSONArray("manualLessons");if(lessons==null)return "";StringBuilder out=new StringBuilder();for(JSONObject lesson:Planner.list(lessons)){if(out.length()>0)out.append("\n");out.append(lesson.optString("name")).append(":").append(lesson.optInt("durationMinutes"));}return out.toString();}
    JSONArray parseManualLessons(String lines,JSONObject course)throws Exception{return Planner.parseManualLessons(lines,course);}
    void courseEditor(JSONObject original){run(()->{final CourseEditing.Draft editSession=new CourseEditing.Draft(state,original);JSONObject c=original==null?new JSONObject().put("id",Planner.id()).put("name","").put("totalMinutes",60).put("initialCompletedMinutes",0).put("startDate",Planner.at(selected,0)).put("deadline",Planner.at(selected.plusDays(30),0)).put("minimumBlockMinutes",60).put("autoScheduleEnabled",true).put("priority",2).put("type","录播课程").put("color","blue").put("isArchived",false).put("notes",""):new JSONObject(original.toString());LinearLayout f=col();EditText name=field(f,"课程名称",c.optString("name"),false);
        // Preserve legacy total-duration values when editing, while offering only two scheduling modes.
        String[] types={"录播课程","不定时录播课程"};
        String storedType=c.optString("type");
        if("补习回放".equals(storedType)||"其他学习".equals(storedType))types[0]=storedType;
        Spinner type=spinner(f,"上课方式",new String[]{"自主研习（按总时长）","分节研习（按课节）"},"不定时录播课程".equals(storedType)?1:0);
        f.addView(text("自主研习：只填总学习时长，按时间块分配。\n分节研习：录入或导入各节名称和时长，按课节安排。",12,muted));
        EditText total=field(f,"总学习量（小时）",""+c.optInt("totalMinutes")/60.0,true),initial=field(f,"导入前已完成量（小时，不含应用内记录）",""+c.optInt("initialCompletedMinutes")/60.0,true);EditText lessonLines=field(f,"网课课节（每行：名称：分钟，中英文冒号均可）",manualLessonText(c),false);lessonLines.setSingleLine(false);lessonLines.setMinLines(3);lessonLines.setVisibility(Planner.isManualLessonCourse(c,c.optString("type"))?View.VISIBLE:View.GONE);type.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener(){public void onItemSelected(android.widget.AdapterView<?> parent,View view,int position,long id){lessonLines.setVisibility(Planner.isManualLessonCourse(c,types[position])?View.VISIBLE:View.GONE);}public void onNothingSelected(android.widget.AdapterView<?> parent){}});boolean mergedCourse=c.optJSONArray("mergedSources")!=null;type.setEnabled(!mergedCourse);total.setEnabled(!mergedCourse);initial.setEnabled(!mergedCourse);if(mergedCourse)f.addView(text("合并课程的课节、总量与基础进度由来源课程保留，可修改名称、日期和排程规则。",12,muted));EditText start=dateField(f,"开始日期",Planner.date(c.getDouble("startDate"))),deadline=dateField(f,"截止日期（包含当天）",Planner.date(c.getDouble("deadline")));CheckBox published=new CheckBox(this);published.setText("设置发布时间");published.setChecked(c.has("publishedDate"));f.addView(published);EditText publish=dateField(f,"发布时间",Planner.date(c.optDouble("publishedDate",c.getDouble("startDate"))));Spinner priority=spinner(f,"优先级",new String[]{"低","中","高"},c.optInt("priority",2)-1);EditText block=field(f,"最小时间块（分钟，0 跟随全局）",""+c.optInt("minimumBlockMinutes"),true);String[] keys={"blue","green","purple","orange","pink"};Spinner color=spinner(f,"颜色",new String[]{"蓝色","绿色","紫色","橙色","粉色"},Arrays.asList(keys).indexOf(c.optString("color")));CheckBox auto=new CheckBox(this);auto.setText("自动排程");auto.setChecked(c.optBoolean("autoScheduleEnabled",true));f.addView(auto);EditText notes=field(f,"备注",c.optString("notes"),false);notes.setSingleLine(false);f.addView(button("编排预览",()->run(()->{JSONObject draft=CourseTools.copy(c);if(value(name).isEmpty())throw new Exception("请填写课程名称");draft.put("name",value(name)).put("type",types[type.getSelectedItemPosition()]).put("startDate",dateValue(start)).put("deadline",dateValue(deadline)).put("minimumBlockMinutes",integer(block)).put("priority",priority.getSelectedItemPosition()+1).put("autoScheduleEnabled",auto.isChecked());if(!mergedCourse){draft.put("totalMinutes",minutes(total)).put("initialCompletedMinutes",minutes(initial));if(Planner.isManualLessonCourse(draft,draft.getString("type")))Planner.updateManualLessons(draft,parseManualLessons(value(lessonLines),draft));}if(published.isChecked())draft.put("publishedDate",dateValue(publish));else draft.remove("publishedDate");new PlannerFeatures(this).preview(next->{editSession.save(next,draft,Planner.now());return draft.getString("id");});})));AlertDialog d=editor(original==null?"添加课程":"编辑课程",f);if(original!=null)f.addView(button("删除课程",()->new AlertDialog.Builder(this).setTitle("删除此课程？").setMessage("所有安排和完成记录都会删除。").setNegativeButton("取消",null).setPositiveButton("删除",(a,b)->mutate(s->editSession.remove(s),true,d::dismiss)).show()));d.setOnShowListener(v->d.getButton(-1).setOnClickListener(x->run(()->{if(value(name).isEmpty())throw new Exception("请填写课程名称");int t=mergedCourse?c.getInt("totalMinutes"):minutes(total),i=mergedCourse?c.getInt("initialCompletedMinutes"):minutes(initial),u=integer(block);if(Planner.isManualLessonCourse(c,types[type.getSelectedItemPosition()])){JSONArray lessons=parseManualLessons(value(lessonLines),c);Planner.updateManualLessons(c,lessons);t=c.getInt("totalMinutes");}final int finalTotal=t;if(t<=0||u<0||u>1440)throw new Exception("学习量或最小时间块无效");double a=dateValue(start),b=dateValue(deadline);if(b<a)throw new Exception("截止日期早于开始日期");c.put("name",value(name)).put("type",types[type.getSelectedItemPosition()]).put("totalMinutes",finalTotal).put("initialCompletedMinutes",i).put("startDate",a).put("deadline",b).put("minimumBlockMinutes",u).put("priority",priority.getSelectedItemPosition()+1).put("color",keys[color.getSelectedItemPosition()]).put("autoScheduleEnabled",auto.isChecked()).put("notes",value(notes));if(published.isChecked())c.put("publishedDate",dateValue(publish));else c.remove("publishedDate");final JSONObject edited=CourseTools.copy(c);mutate(s->editSession.save(s,edited,Planner.now()),true,d::dismiss);})));d.show();});}
    String repeat(JSONObject e){JSONArray w=e.optJSONArray("weekdays");if(w==null||w.length()==0)return "单次";String[] names={"","日","一","二","三","四","五","六"};List<Integer> a=new ArrayList<>();for(int i=0;i<w.length();i++)a.add(w.optInt(i));Collections.sort(a);String r="每周 ";for(int i:a)r+=names[i]+" ";return r;}
    void floatingStyle(LinearLayout box,int tint){android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(Color.WHITE);bg.setCornerRadius(dp(16));bg.setStroke(dp(2),tint,dp(5),dp(4));box.setBackground(bg);box.setContentDescription("时段内浮动，具体时间未定");}
    void eventCard(LinearLayout parent,JSONObject e,boolean detail)throws Exception{LinearLayout box=card(parent);cardBorder(box,color(e.optString("color","orange")));if(Planner.floating(e)){floatingStyle(box,color(e.optString("color","orange")));box.addView(text("↔ 固定占用 "+Planner.occupied(e)+" / "+(e.optInt("endMinute")-e.optInt("startMinute"))+" 分钟 · 位置未定",12,muted));}box.addView(text(Planner.time(e.getInt("startMinute"))+" — "+Planner.time(e.getInt("endMinute"))+(Planner.floating(e)?" · ↔ 时段内浮动":" · 固定事项"),12,muted));TextView eventName=text(e.getString("title"),18,ink);eventName.setTypeface(null,Typeface.BOLD);box.addView(eventName);if(detail)box.addView(text(repeat(e)+"\n"+Planner.date(e.getDouble("startDate"))+" 至 "+Planner.date(e.getDouble("endDate")),12,muted));if(!e.optString("notes").isEmpty())box.addView(text(e.optString("notes"),13,muted));PlannerUi.Flow actions=new PlannerUi.Flow(this);box.addView(actions);actions.addView(pill("编辑事项",()->eventEditor(e)));if(detail)actions.addView(pill("复制为新事项",()->run(()->eventEditor(FixedEventEditing.duplicate(e,selected,Planner.now()),true))));
        final LocalDate date=selected;
        if(!detail&&!date.isBefore(LocalDate.now(Planner.ZONE))){
            actions.addView(pill("仅此日移除并重排",()->mutate(s->FixedEventEditing.setSkipped(s,e,date,true,Planner.now()),true,null)));
            box.addView(text("仅移除本日这一次安排，并重排今天及未来未确认任务。",12,muted));
        }
    }
    void events()throws Exception{body.addView(title("固定课表"));FixedEventRecognitionPanel.render(this,body);body.addView(text("固定时间或时段内的固定时长优先保留",13,muted));body.addView(button("＋ 添加固定事项",()->eventEditor(null)));FixedEventCatalogPanel.render(this,body);}
    void saveEventResolvingConflicts(JSONObject event,JSONObject baseline,AlertDialog editor,AlertDialog review,
                                     Set<LocalDate> skipped,Set<LocalDate> skippedLocal,List<Planner.EventConflict> reviewed){
        run(()->{
            JSONObject draft=CourseTools.copy(event);
            Set<LocalDate> confirmed=new HashSet<>(skipped),confirmedLocal=new HashSet<>(skippedLocal);
            mutate(s->FixedEventEditing.save(s,draft,baseline,Planner.now(),confirmed,confirmedLocal,reviewed),true,
                ()->{if(review!=null)review.dismiss();editor.dismiss();},error->{
                    if(error instanceof FixedEventEditing.ReviewRequired){
                        if(review!=null)review.dismiss();
                        showEventConflicts(event,baseline,editor,(FixedEventEditing.ReviewRequired)error);
                    }else alert("操作未保存",error.getMessage());
                });
        });
    }
    void showEventConflicts(JSONObject event,JSONObject baseline,AlertDialog editor,FixedEventEditing.ReviewRequired issue){
        List<Planner.EventConflict> conflicts=issue.conflicts;
        JSONObject displayed=issue.event;
        LinearLayout form=col();form.setPadding(dp(20),dp(10),dp(20),dp(10));
        form.addView(text("「"+displayed.optString("title")+"」 "+Planner.time(displayed.optInt("startMinute"))+"–"+Planner.time(displayed.optInt("endMinute"))+(Planner.floating(displayed)?" · 浮动占用 "+Planner.occupied(displayed)+" 分钟":""),16,ink));
        form.addView(text("每个冲突日期可跳过新课程、保留本地安排；或跳过当天冲突的本地固定事项、保留新课程。同一天的多个冲突一起处理，其他日期照常安排。",13,muted));
        if(displayed.optJSONArray("weekdays")==null||displayed.optJSONArray("weekdays").length()==0)form.addView(text("这是单次事项；选择跳过新课程后，该事项不会产生安排。",13,muted));
        TextView summary=text("",13,muted);form.addView(summary);
        Map<LocalDate,List<Planner.EventConflict>> grouped=new TreeMap<>();
        for(Planner.EventConflict conflict:conflicts)grouped.computeIfAbsent(conflict.date,key->new ArrayList<>()).add(conflict);
        Set<LocalDate> skipped=new HashSet<>(),skippedLocal=new HashSet<>();
        Map<LocalDate,RadioGroup> choices=new LinkedHashMap<>();Map<LocalDate,Integer> newIDs=new HashMap<>(),localIDs=new HashMap<>();
        for(Map.Entry<LocalDate,List<Planner.EventConflict>> entry:grouped.entrySet()){
            LinearLayout box=card(form);box.addView(text(entry.getKey().format(java.time.format.DateTimeFormatter.ofPattern("yyyy年M月d日 EEEE",Locale.CHINA)),16,ink));
            boolean canSkipLocal=true;
            for(Planner.EventConflict conflict:entry.getValue()){
                box.addView(text("与本地「"+conflict.title+"」冲突",15,ink));box.addView(text(conflict.timeDescription()+"\n"+conflict.explanation(),13,muted));
                if(conflict.reason.equals("active"))canSkipLocal=false;
            }
            RadioGroup group=new RadioGroup(this);
            RadioButton skipNew=new RadioButton(this);skipNew.setId(View.generateViewId());skipNew.setText("跳过新课程（不植入），保留本地");group.addView(skipNew);
            RadioButton skipLocal=new RadioButton(this);skipLocal.setId(View.generateViewId());skipLocal.setText("跳过本地固定事项，保留新课程");skipLocal.setEnabled(canSkipLocal);group.addView(skipLocal);
            if(skipped.contains(entry.getKey()))group.check(skipNew.getId());else if(skippedLocal.contains(entry.getKey())&&canSkipLocal)group.check(skipLocal.getId());
            box.addView(group);box.addView(text("仅跳过上列本地事项在当天的安排，可在主页恢复。",12,muted));
            choices.put(entry.getKey(),group);newIDs.put(entry.getKey(),skipNew.getId());if(canSkipLocal)localIDs.put(entry.getKey(),skipLocal.getId());
        }
        ScrollView scroll=new ScrollView(this);scroll.addView(form);
        AlertDialog review=new AlertDialog.Builder(this).setTitle("逐日处理时间冲突").setView(scroll).setNegativeButton("返回修改",null).setNeutralButton("清除选择",null).setPositiveButton("保存选择",null).create();
        Runnable refresh=()->{int remaining=0;for(LocalDate day:grouped.keySet())if(!skipped.contains(day)&&!skippedLocal.contains(day))remaining++;summary.setText(conflicts.size()+" 处冲突 · "+grouped.size()+" 天 · "+remaining+" 天未确认");review.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(remaining==0);};
        for(Map.Entry<LocalDate,RadioGroup> choice:choices.entrySet())choice.getValue().setOnCheckedChangeListener((group,id)->{
            LocalDate day=choice.getKey();skipped.remove(day);skippedLocal.remove(day);
            if(id==newIDs.get(day))skipped.add(day);else if(localIDs.containsKey(day)&&id==localIDs.get(day))skippedLocal.add(day);refresh.run();
        });
        PlannerUi.Flow bulkActions=new PlannerUi.Flow(this);form.addView(bulkActions);
        bulkActions.addView(button("全部跳过新课程并保存",()->{skipped.addAll(grouped.keySet());skippedLocal.removeAll(grouped.keySet());saveEventResolvingConflicts(event,baseline,editor,review,skipped,skippedLocal,conflicts);}));
        Button allLocal=button("全部跳过本地并保存",()->{skippedLocal.addAll(grouped.keySet());skipped.removeAll(grouped.keySet());saveEventResolvingConflicts(event,baseline,editor,review,skipped,skippedLocal,conflicts);});allLocal.setEnabled(localIDs.size()==grouped.size());bulkActions.addView(allLocal);
        review.setOnShowListener(dialog->{refresh.run();review.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->saveEventResolvingConflicts(event,baseline,editor,review,skipped,skippedLocal,conflicts));review.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v->{skipped.clear();skippedLocal.clear();for(RadioGroup group:choices.values())group.clearCheck();refresh.run();});});review.show();
    }
    void eventEditor(JSONObject original){eventEditor(original,false);}
    void eventEditor(JSONObject original,boolean recognized){run(()->{final JSONObject baseline=original==null||recognized?null:CourseTools.copy(original);JSONObject e=original==null?new JSONObject().put("id",Planner.id()).put("title","").put("startMinute",480).put("endMinute",540).put("startDate",Planner.at(selected,0)).put("endDate",Planner.at(selected.plusDays(112),0)).put("weekdays",new JSONArray()).put("excludedDates",new JSONArray()).put("color","orange").put("notes",""):new JSONObject(original.toString());LinearLayout f=col();Spinner timing=spinner(f,"时间方式",new String[]{"固定时间","时段内浮动"},Planner.floating(e)?1:0);EditText duration=field(f,"浮动占用分钟（仅时段内浮动生效）",""+(Planner.floating(e)?Planner.occupied(e):60),true);f.addView(text("浮动时：起止时间表示窗口，仅扣除固定占用分钟，学习任务也标记为时段内完成。",12,muted));EditText title=field(f,"事项名称",e.optString("title"),false),start=field(f,"开始时间（HH:mm）",Planner.time(e.getInt("startMinute")),false),end=field(f,"结束时间（HH:mm）",Planner.time(e.getInt("endMinute")),false),first=dateField(f,"开始日期",Planner.date(e.getDouble("startDate"))),last=dateField(f,"结束日期",Planner.date(e.getDouble("endDate")));f.addView(text("重复星期（不选为单次）",13,muted));CheckBox[] checks=new CheckBox[7];String[] names={"星期日","星期一","星期二","星期三","星期四","星期五","星期六"};for(int i=0;i<7;i++){checks[i]=new CheckBox(this);checks[i].setText(names[i]);for(int j=0;j<e.getJSONArray("weekdays").length();j++)if(e.getJSONArray("weekdays").getInt(j)==i+1)checks[i].setChecked(true);f.addView(checks[i]);}String excluded="";JSONArray exc=e.optJSONArray("excludedDates");if(exc!=null)for(int i=0;i<exc.length();i++)excluded+=Planner.date(exc.getDouble(i))+" ";EditText exclusions=field(f,"跳过日期（YYYY-MM-DD，空格分隔）",excluded.trim(),false);exclusions.setSingleLine(false);EditText notes=field(f,"备注",e.optString("notes"),false);String[] keys={"blue","green","purple","orange","pink"};Spinner color=spinner(f,"颜色",new String[]{"蓝色","绿色","紫色","橙色","粉色"},Arrays.asList(keys).indexOf(e.optString("color")));AlertDialog d=editor(original==null||recognized?"添加固定事项":"编辑固定事项",f);if(original!=null&&!recognized)f.addView(button("删除未来安排",()->new AlertDialog.Builder(this).setTitle("删除此事项的未来安排？").setMessage("历史和今天已开始的安排会保留。").setNegativeButton("取消",null).setPositiveButton("删除",(a,b)->mutate(s->FixedEventEditing.removeFuture(s,baseline,Planner.now()),true,d::dismiss)).show()));d.setOnShowListener(v->d.getButton(-1).setOnClickListener(x->run(()->{if(value(title).isEmpty())throw new Exception("请填写事项名称");JSONArray weeks=new JSONArray(),ex=new JSONArray();for(int i=0;i<7;i++)if(checks[i].isChecked())weeks.put(i+1);if(!value(exclusions).isEmpty())for(String token:value(exclusions).split("[\\s,，]+"))ex.put(Planner.at(LocalDate.parse(token),0));double a=dateValue(first),b=weeks.length()==0?a:dateValue(last);e.put("title",value(title)).put("startMinute",Planner.minute(value(start))).put("endMinute",Planner.minute(value(end))).put("startDate",a).put("endDate",b).put("weekdays",weeks).put("excludedDates",ex).put("notes",value(notes)).put("color",keys[color.getSelectedItemPosition()]);if(timing.getSelectedItemPosition()==1)e.put("floatingDurationMinutes",integer(duration));else e.remove("floatingDurationMinutes");saveEventResolvingConflicts(e,baseline,d,null,Collections.emptySet(),Collections.emptySet(),null);})));d.show();});}
    void settings()throws Exception{
        SettingsMenu menu=new SettingsMenu(this,body);settingsMenu=menu;
        if(restoredSettingsDraft!=null){
            try{settingsDraft=SettingsDraft.restore(new JSONObject(restoredSettingsDraft));}
            catch(Exception error){alert("设置草稿无法恢复","已保存设置未被修改，请重新输入未保存的设置。");}
            restoredSettingsDraft=null;
        }
        if(settingsDraft==null||!settingsDraft.isDirty())settingsDraft=new SettingsDraft(state.getJSONObject("settings"));
        final SettingsDraft draft=settingsDraft;
        JSONObject settings=CourseTools.copy(draft.baseline).put("schedulingRuleLevels",draft.levels);
        LinearLayout rules=menu.page("priorities","排课逻辑权重",3,true);
        SchedulePrioritiesPanel priorities=new SchedulePrioritiesPanel(this,rules,settings);
        LinearLayout explanation=card(menu.page("explanation","排课原因",4,false));
        explanation.addView(title("当前为什么这样排课"));
        for(String reason:ScheduleExplanation.lines(state))explanation.addView(text(reason,14,ink));
        explanation.addView(text("依据已保存的设置与最近一次排程结果。修改权重后，保存设置并重排才会更新原因。",13,muted));
        LinearLayout f=card(menu.page("defaults","默认规则",3,true));
        f.addView(title("默认规则"));
        EditText unit=field(f,"全局最小学习时间块（分钟）",draft.unit,true);
        EditText notification=field(f,"应用内每日确认时间（HH:mm）",draft.notification,false);
        LinearLayout availabilityBox=card(menu.page("availability","每日可学习时间",2,true));
        availabilityBox.addView(title("每日可学习时间"));
        availabilityBox.addView(text("每行支持多个时段，以逗号分隔；留空为休息日。",13,muted));
        EditText[] availability=new EditText[7];
        for(int i=0;i<7;i++){
            availability[i]=field(availabilityBox,"星期"+new String[]{"一","二","三","四","五","六","日"}[i],draft.availability[i],false);
            availability[i].setHint("08:00-12:00, 14:00-22:00");
        }
        syncSettings(menu.page("localSync","热点局域网同步",0,false));
        CloudSettingsPanel.render(this,menu.page("cloudSync","云端同步",3,false));
        LinearLayout backup=card(menu.page("data","数据与备份",1,false));backup.addView(title("数据与备份"));backup.addView(text("安装包不含个人日程；首次安装以空白日程开始。覆盖安装不会替换手机进度。卸载会删除手机数据，请先导出备份。",13,muted));PlannerUi.Flow backupActions=new PlannerUi.Flow(this);backup.addView(backupActions);backupActions.addView(button("导出手机日程备份",()->{Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT);intent.setType("application/json");intent.addCategory(Intent.CATEGORY_OPENABLE);intent.putExtra(Intent.EXTRA_TITLE,"学习日程-"+LocalDate.now(Planner.ZONE)+".json");startActivityForResult(intent,EXPORT_BACKUP);}));backupActions.addView(button("从备份恢复",()->{Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT);intent.setType("application/json");intent.addCategory(Intent.CATEGORY_OPENABLE);startActivityForResult(intent,IMPORT_BACKUP);}));backupActions.addView(button("恢复前的日程",()->transferBackup(null,false)));backup.addView(text("每次从备份恢复前保留一份本机日程，可通过「恢复前的日程」找回。仅保留最近一次，卸载或清除数据也会删除；需要长期保存请导出文件。",13,muted));JSONObject meta=new JSONObject(read(getAssets().open("snapshot-info.json")));backup.addView(text("初始数据："+meta.getJSONObject("counts").getInt("courses")+" 门课程 · "+meta.getJSONObject("counts").getInt("fixedEvents")+" 条固定规则 · "+meta.getJSONObject("counts").getInt("tasks")+" 条任务 · "+meta.getJSONObject("counts").getInt("completions")+" 条完成记录\n安卓版 "+getPackageManager().getPackageInfo(getPackageName(),0).versionName+" · Android 8.0 及以上",12,muted));
        captureSettingsDraft=()->{
            draft.unit=unit.getText().toString();draft.notification=notification.getText().toString();
            for(int i=0;i<7;i++)draft.availability[i]=availability[i].getText().toString();
            draft.levels=priorities.levels();
        };
        menu.setSaveButton(button("保存设置并重排",()->run(()->{
            captureSettingsDraft.run();
            JSONObject edited=draft.editedSettings(),baseline=CourseTools.copy(draft.baseline);
            mutate(s->SettingsEditing.save(s,edited,baseline,Planner.now()),true,()->{settingsDraft=null;captureSettingsDraft=null;});
        })));
        menu.setRestoreButton(button("恢复已保存设置",()->new AlertDialog.Builder(this)
            .setTitle("恢复已保存设置？").setMessage("放弃当前未保存的设置输入，重新载入已保存值。")
            .setNegativeButton("取消",null).setPositiveButton("恢复",(dialog,which)->reloadStudySettings()).show()));
        menu.show(settingsSection);
    }
    void reloadStudySettings(){
        if(busy)return;
        busy=true;ProgressDialog progress=new ProgressDialog(this);progress.setMessage("正在读取已保存设置…");progress.setCancelable(false);progress.show();
        worker.execute(()->{try{
            JSONObject latest=database.load();Planner.refreshDiagnostics(latest,Planner.now());
            runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;
                state=latest;settingsDraft=null;captureSettingsDraft=null;render();resumeSyncRefresh();
            });
        }catch(Exception error){runOnUiThread(()->{busy=false;progress.dismiss();if(!isDestroyed()){alert("读取失败",error.getMessage()+"\n未保存输入仍保留。");resumeSyncRefresh();}});}});
    }
    final BroadcastReceiver syncReceiver=new BroadcastReceiver(){public void onReceive(Context c,Intent i){if(CloudSync.ACTION.equals(i.getAction())){if(cloudLabel!=null)cloudLabel.setText(CloudSync.summary(c));refreshSyncData();return;}syncStatus=SyncWindowService.lastStatus;updateSyncLabel();updateSyncProgress();if(i.getBooleanExtra("changed",false))refreshSyncData();}};
    void updateSyncProgress(){if(syncProgress!=null)syncProgress.setVisibility(CloudSync.get(this).isRunning()||(syncRefresh!=null&&syncRefresh.isRunning())||SyncWindowService.transferring()?View.VISIBLE:View.GONE);}
    void refreshSyncData(){if(syncRefresh!=null)syncRefresh.request();updateSyncProgress();}
    void resumeSyncRefresh(){resumeCourseResult();if(syncRefresh!=null)syncRefresh.resume();}


    static String syncSummary(JSONObject ledger){double time=ledger.optDouble("lastSuccess",0);return "今日自动同步："+(LocalDate.now(Planner.ZONE).toString().equals(ledger.optString("lastAutoDate"))?"已完成":"尚未完成")+"\n最后同步："+(time>0?Instant.ofEpochSecond((long)time).atZone(Planner.ZONE).format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")):"尚无");}
    void updateSyncLabel(){if(syncLabel!=null)syncLabel.setText(syncStatus+"\n"+syncSummary);}
    void syncSettings(LinearLayout parent)throws Exception{
        LinearLayout box=card(parent);box.addView(title("热点局域网同步"));syncLabel=text("",13,muted);syncLabel.setTextIsSelectable(true);box.addView(syncLabel);updateSyncLabel();
        box.addView(text("Mac 连接本机热点后同步。首次配对请扫描 Mac 生成的二维码；二维码不含日程内容。接收窗口最长 120 秒，完成或超时后自动关闭。",13,muted));
        PlannerUi.Flow actions=new PlannerUi.Flow(this);box.addView(actions);
        actions.addView(button("立即同步 · 开启接收窗口",()->syncServer.start(false,true)));
        actions.addView(button("扫描 Mac 配对二维码",()->{if(syncServer.isRunning()){syncStatus="请先关闭当前接收窗口，再扫描二维码";updateSyncLabel();}else startActivityForResult(new Intent(this,QrScannerActivity.class),SCAN_PAIRING_QR);}));
        actions.addView(button("关闭接收窗口",()->syncServer.close()));
        actions.addView(button("查看同步日志",()->run(()->{File file=new File(getFilesDir(),"sync.log");alert("同步日志",file.exists()?read(new FileInputStream(file)):"暂无日志");})));
    }
    static String pairingSecret(String payload)throws Exception{Uri uri=Uri.parse(payload);if(!"studyplanner".equals(uri.getScheme())||!"pair".equals(uri.getHost())||!"2".equals(uri.getQueryParameter("v")))throw new Exception("这不是学习日程配对二维码");String secret=uri.getQueryParameter("secret"),expires=uri.getQueryParameter("expires");if(secret==null||!secret.matches("[0-9a-fA-F]{64}")||expires==null)throw new Exception("配对二维码内容无效");long expiry=Long.parseLong(expires)*1000L,now=System.currentTimeMillis();if(expiry<=now||expiry-now>600000)throw new Exception("配对二维码已过期，请在 Mac 重新生成");return secret.toLowerCase(Locale.ROOT);}
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(result!=RESULT_OK||data==null)return;run(()->{if(request==IMPORT_SSH_KEY&&data.getData()!=null){if(cloudPanel==null)throw new Exception("请返回云同步设置重新导入私钥");cloudPanel.importKey(data.getData());}else if(request==IMPORT_COURSES){receiveCourses(data);}else if(request==SCAN_PAIRING_QR){String payload=data.getStringExtra(QrScannerActivity.EXTRA_RESULT);if(payload==null)throw new Exception("没有读取到二维码");syncServer.startPairing(pairingSecret(payload));}else if((request==EXPORT_BACKUP||request==IMPORT_BACKUP)&&data.getData()!=null){transferBackup(data.getData(),request==EXPORT_BACKUP);}});}
    void transferBackup(Uri uri,boolean exporting){
        if(busy||!ready){alert("请稍后","日程正在处理中，请稍后重试备份操作。");return;}
        busy=true;ProgressDialog progress=ProgressDialog.show(this,"",exporting?"正在导出最新日程…":"正在读取并检查备份…",true,false);
        worker.execute(()->{try{
            PlannerBackupFile.Restore review=null;
            if(exporting){PlannerBackupFile backup=PlannerBackupFile.create(database.load(),Planner.now());backup.write(getContentResolver().openOutputStream(uri,"wt"));}
            else{PlannerBackupFile imported=uri==null?PlannerRuntime.get(this).restoreBackup.load():PlannerBackupFile.read(getContentResolver().openInputStream(uri));review=new PlannerBackupFile.Restore(imported,database.load());}
            final PlannerBackupFile.Restore reviewed=review;
            runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;
                if(exporting)Toast.makeText(this,"备份已导出",Toast.LENGTH_LONG).show();else showBackupRestore(reviewed);
                resumeSyncRefresh();
            });
        }catch(Exception error){runOnUiThread(()->{busy=false;progress.dismiss();if(isDestroyed())return;
            alert(exporting?"备份未导出":"备份未读取",error.getMessage()+"\n手机日程未改动。"+(exporting?"导出文件可能不完整，请重新导出。":""));resumeSyncRefresh();
        });}});
    }
    void showBackupRestore(PlannerBackupFile.Restore restore){
        new AlertDialog.Builder(this).setTitle("恢复此备份？")
            .setMessage(restore.summary+"\n\n将替换手机当前日程。恢复前会先保存一份本机当前日程；启用云同步时，此次恢复也会同步到其他设备。")
            .setNegativeButton("取消",null).setPositiveButton("恢复",(a,b)->mutate(s->PlannerRuntime.get(this).restoreBackup.restore(s,restore,Planner.now()),false,()->{settingsDraft=null;restoredSettingsDraft=null;captureSettingsDraft=null;})).show();
    }

}
