package local.studyplanner;

import android.app.*;import android.content.*;import android.graphics.Typeface;import android.view.*;import android.widget.*;import android.text.*;import org.json.*;import java.time.*;import java.util.*;

/** Mobile entry points for the desktop planner features; business logic remains independently testable. */
final class PlannerFeatures {
 final MainActivity app;PlannerFeatures(MainActivity app){this.app=app;}
 void overview()throws Exception{
  JSONObject health=ScheduleHealth.assess(app.state,Planner.now(),app.consequences.warning());
  if(health.optInt("remainingMinutes")>0){
   LinearLayout box=app.card(app.body);String kind=health.optString("kind");int tint=kind.equals("shortage")?0xffbd3333:kind.equals("scheduled")?0xff126346:0xff874b00;
   box.addView(app.text(ScheduleHealth.title(kind),17,tint));
   box.addView(app.text(kind.equals("pending")?"尚未找到完整排法，不等于客观上学不完。请查看未排入内容和可调整时段。":kind.equals("shortage")?"已发现总时长或连续空档无法满足的硬约束，请查看具体原因。":"截止日期保持不变；科目混排和倍率会在需要时让步。",15,app.muted));
   box.addView(app.text("剩余学习量 "+app.hours(health.optInt("remainingMinutes"))+" · 暂未排入 "+app.hours(health.optInt("unplacedMinutes")),15,app.ink));
   if(health.optInt("pausedMinutes")>0)box.addView(app.text("暂停自动排程 "+app.hours(health.optInt("pausedMinutes"))+"，恢复后再核对。",15,app.muted));
   box.addView(app.text("后续最重一天 "+app.hours(health.optInt("peakMinutes"))+" · 有安排的日均 "+app.hours(health.optInt("averageMinutes"))+"\n"+health.optInt("heavyDays")+" 天超过每日负担提醒线",15,app.ink));
   if(health.optInt("reviewedMinutes")>0)box.addView(app.text("今日已确认：实际学习 "+app.hours(health.optInt("creditedMinutes"))+" / 原计划 "+app.hours(health.optInt("reviewedMinutes")),15,app.muted));
   box.addView(app.pill("查看补回安排与每日负担",()->app.run(()->healthDetails(health))));
  }
  LinearLayout threshold=app.card(app.body);threshold.addView(app.text("每日负担提醒线 · "+app.hours(app.consequences.warning()),16,app.ink));
  threshold.addView(app.pill("调整提醒线",()->{LinearLayout form=app.col();EditText minutes=app.field(form,"每天超过多少分钟提醒（至少30）",String.valueOf(app.consequences.warning()),true);
   AlertDialog dialog=app.editor("每日负担提醒线",form);dialog.setOnShowListener(v->dialog.getButton(-1).setOnClickListener(x->app.run(()->{int n=app.integer(minutes);if(n<30||n>1440)throw new IllegalArgumentException("提醒线应在30–1440分钟之间");app.getPreferences(0).edit().putInt("dailyStudyLoadWarningMinutes",n).apply();dialog.dismiss();app.render();})));dialog.show();}));
  threshold.addView(app.text("提醒线只用于提示学习负担，不会减少可学习时间或改动截止日，仅保存在本机。",15,app.muted));
  threshold.addView(app.pill("查看理论容量估算",()->app.run(()->{StudyLoad.Assessment load=StudyLoad.assess(app.state,Planner.now());if(load==null){app.alert("理论容量估算","当前没有待学课程。");return;}
   app.alert("理论容量估算（粗略）",String.format(Locale.CHINA,"日均最低 %.2f 小时 · 临界日均上限 %.2f 小时\n按此粗略模型，连续停学约 %d 天后容量紧张，约 %d 天后容量不足。\n最紧张区间：%s 至 %s。\n按完整自然日估算，包含暂停课程，仅扣每天重复事项；未计入整节、课间休息及非每日事项。实际能否排完以上方实时排程为准。",load.dailyRequired(),load.dailyCapacity(),load.warningAfter,load.criticalAfter,load.start,load.deadline));})));
  weekly();
 }
 void healthDetails(JSONObject health)throws Exception{
  StringBuilder details=new StringBuilder();
  for(JSONObject proof:Planner.list(ScheduleHealth.array(app.state,"androidConflicts"))){details.append(Planner.date(proof.optDouble("windowStart"))).append(" 至 ").append(Planner.date(proof.optDouble("deadline"))).append(" · ").append(DailyConsequencesView.names(proof.optJSONArray("courseNames"))).append("\n");
   if(proof.has("provenDeficit"))details.append("已证实至少缺少 ").append(proof.optInt("provenDeficit")).append(" 分钟；需要 ").append(proof.optInt("requiredMinutes")).append("，乐观容量上界 ").append(proof.optInt("availableMinutes"));
   else details.append("需要连续 ").append(proof.optInt("minimumContinuousMinutes")).append(" 分钟，最长空档只有 ").append(proof.optInt("availableMinutes")).append(" 分钟");details.append("\n\n");}
  for(JSONObject day:Planner.list(health.getJSONArray("recovery")))details.append("待补内容 · ").append(Planner.date(day.optDouble("date"))).append(" · ").append(day.optInt("plannedMinutes")).append(" 分钟\n");
  details.append("\n每日预排 / 可用分钟\n");for(JSONObject day:Planner.list(ScheduleHealth.array(app.state,"androidDayPlans")))if(day.optInt("plannedMinutes")>0)details.append(Planner.date(day.optDouble("date"))).append(" · ").append(day.optInt("plannedMinutes")).append(" / ").append(day.optInt("availableMinutes")).append("\n");
  JSONArray notes=ScheduleHealth.array(app.state,"androidWarnings");for(int i=0;i<notes.length();i++)details.append("\n").append(notes.getString(i));
  JSONArray adjustments=ScheduleHealth.array(app.state,"androidAdjustments");for(int i=0;i<adjustments.length();i++)details.append("\n").append(adjustments.getString(i));
  app.alert("补回安排与每日负担",details.toString());
 }
 void weekly(){
  WeeklyStudyStats stats=WeeklyStudyStats.calculate(app.state,app.selected);long max=1;
  for(int day=0;day<7;day++)max=Math.max(max,stats.studied(day));
  LinearLayout box=app.card(app.body);box.addView(app.title("周学习统计"));
  box.addView(app.text(stats.monday+" 至 "+stats.monday.plusDays(6)+"\n实际已学 "+app.hours(stats.studiedMinutes)+" · 课表计划 "+app.hours(stats.plannedMinutes),14,app.ink));
  box.addView(app.text("色条表示实际已学，按确认时填写的学习日期统计；计划按当前课表的原定日期统计。",12,app.muted));
  for(int day=0;day<7;day++){
   LinearLayout row=app.row();row.addView(app.text("周"+"一二三四五六日".charAt(day),12,app.muted),new LinearLayout.LayoutParams(app.dp(32),-2));
   LinearLayout detail=app.col();detail.addView(app.text("已学 "+app.hours(stats.studied(day))+" / 计划 "+app.hours(stats.planned(day)),12,app.muted));
   LinearLayout bar=app.row();for(WeeklyStudyStats.Course course:stats.courses){long n=course.studied(day);if(n>0){View segment=new View(app);segment.setBackgroundColor(app.color(course.color));bar.addView(segment,new LinearLayout.LayoutParams(0,app.dp(8),(float)n));}}
   View spacer=new View(app);bar.addView(spacer,new LinearLayout.LayoutParams(0,app.dp(8),(float)Math.max(1,max-stats.studied(day))));detail.addView(bar);
   row.addView(detail,new LinearLayout.LayoutParams(0,-2,1));box.addView(row);
  }
  StringBuilder legend=new StringBuilder();for(WeeklyStudyStats.Course course:stats.courses){if(legend.length()>0)legend.append(" · ");legend.append(course.name);}box.addView(app.text(legend.toString(),12,app.muted));
  if(stats.undatedMinutes>0)box.addView(app.text("全部历史中另有 "+app.hours(stats.undatedMinutes)+" 的旧记录无法确定学习日期，未计入本周实学；原进度与记录均保留。",12,app.muted));
 }
 void search(){
  LinearLayout form=app.col();form.setPadding(app.dp(16),0,app.dp(16),0);
  EditText query=app.field(form,"课程、课节或日期（YYYY-MM-DD）","",false);
  TaskSearch.Scope[] scopes=TaskSearch.Scope.values();
  Spinner scope=app.spinner(form,"搜索范围",new String[]{scopes[0].title,scopes[1].title,scopes[2].title},0);
  TextView explanation=app.text(scopes[0].explanation,12,app.muted);form.addView(explanation);
  String hint="可组合多个关键词，点结果跳转到当天。";
  TextView count=app.text(hint,12,app.muted);form.addView(count);
  LinearLayout rows=app.col();ScrollView scroll=new ScrollView(app);scroll.addView(rows);form.addView(scroll,new LinearLayout.LayoutParams(-1,app.dp(300)));
  PlannerUi.Flow navigation=new PlannerUi.Flow(app);form.addView(navigation);
  AlertDialog dialog=new AlertDialog.Builder(app).setTitle("搜索课程日期").setView(form).setNegativeButton("关闭",null).create();
  TaskSearch.Result[] result={null};int[] page={0};Button[] pages=new Button[2];
  Runnable render=()->{
   rows.removeAllViews();int total=result[0]==null?0:result[0].count(),number=result[0]==null?0:result[0].pageCount();
   pages[0].setEnabled(page[0]>0);pages[1].setEnabled(page[0]+1<number);
   if(result[0]==null)return;
   count.setText(total==0?"没有找到匹配的安排，可切换范围或缩短关键词":"找到 "+total+" 项安排 · 第 "+(page[0]+1)+" / "+number+" 页");
   for(TaskSearch.Hit hit:result[0].page(page[0]))rows.addView(app.button(hit.label(),()->{
    app.selected=Planner.day(hit.start);app.month=app.selected.withDayOfMonth(1);app.page=0;dialog.dismiss();app.render();
   }));scroll.scrollTo(0,0);
  };
  pages[0]=app.button("上一页",()->{page[0]--;render.run();});pages[1]=app.button("下一页",()->{page[0]++;render.run();});
  navigation.addView(pages[0]);navigation.addView(pages[1]);render.run();
  TaskSearchController controller=new TaskSearchController(app.worker,app::runOnUiThread,value->{
   if(app.isDestroyed()||!dialog.isShowing())return;result[0]=value;page[0]=0;render.run();
  },error->{if(!app.isDestroyed()&&dialog.isShowing())count.setText("搜索失败："+error.getMessage());});
  Runnable[] pending={null};
  Runnable search=()->{
   if(pending[0]!=null)app.handler.removeCallbacks(pending[0]);controller.clear();result[0]=null;page[0]=0;render.run();
   TaskSearch.Scope selected=scopes[scope.getSelectedItemPosition()];explanation.setText(selected.explanation);
   String term=query.getText().toString();if(TaskSearch.normalize(term).isEmpty()){count.setText(hint);return;}
   count.setText("正在搜索…");JSONObject snapshot=app.state;double now=Planner.now();
   pending[0]=()->controller.search(snapshot,term,selected,now);app.handler.postDelayed(pending[0],200);
  };
  query.addTextChangedListener(new TextWatcher(){
   public void beforeTextChanged(CharSequence s,int start,int n,int after){}
   public void onTextChanged(CharSequence s,int start,int before,int n){search.run();}
   public void afterTextChanged(Editable s){}
  });
  scope.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener(){
   public void onItemSelected(android.widget.AdapterView<?> parent,View view,int position,long id){search.run();}
   public void onNothingSelected(android.widget.AdapterView<?> parent){}
  });
  dialog.setOnDismissListener(d->{controller.close();if(pending[0]!=null)app.handler.removeCallbacks(pending[0]);});dialog.show();
 }
 void coursesHeader(PlannerUi.Flow actions){actions.addView(app.button("继续未完成导入",app::pendingCourseImports));actions.addView(app.button("合并课程",this::merge));actions.addView(app.button("从网站抓取全部课程",()->app.startActivityForResult(new Intent(app,CourseImportActivity.class).putExtra("mode","website"),MainActivity.IMPORT_COURSES)));actions.addView(app.button("从夸克网盘分享导入",()->app.startActivityForResult(new Intent(app,CourseImportActivity.class).putExtra("mode","netdisk"),MainActivity.IMPORT_COURSES)));}
 void courseCatalog(LinearLayout parent){
  JSONObject snapshot=app.state;EditText query=app.field(parent,"搜索名称、备注或截止日期（可组合关键词）",app.courseQuery,false);
  CourseCatalog.Scope[] scopes=CourseCatalog.Scope.values();Spinner scope=app.spinner(parent,"排程状态",new String[]{scopes[0].title,scopes[1].title,scopes[2].title},app.courseScope.ordinal());
  TextView count=app.text("正在读取课程…",12,app.muted);parent.addView(count);
  PlannerUi.Flow top=new PlannerUi.Flow(app),bottom=new PlannerUi.Flow(app);parent.addView(top);LinearLayout rows=app.col();parent.addView(rows);parent.addView(bottom);
  Button[] previous=new Button[2],next=new Button[2];CourseCatalog.Page[] result={null};
  Runnable controls=()->{for(int i=0;i<2;i++){previous[i].setEnabled(result[0]!=null&&result[0].index>0);next[i].setEnabled(result[0]!=null&&result[0].index+1<result[0].pageCount);}};
  LatestWork<CourseCatalog.Page> work=new LatestWork<>(app.worker,app::runOnUiThread,value->{
   if(app.isDestroyed()||app.body!=parent||app.state!=snapshot)return;result[0]=value;app.coursePage=value.index;rows.removeAllViews();
   count.setText(value.count==0?"当前范围没有匹配课程，可切换状态或清除筛选":value.count+" 门课程 · 第 "+(value.index+1)+" / "+value.pageCount+" 页 · 按截止日期排序");
   app.run(()->{for(CourseCatalog.Row row:value.rows){JSONObject course=Planner.course(snapshot,row.id);if(course!=null)app.courseCard(rows,course,row.completedMinutes);}});
   controls.run();query.requestRectangleOnScreen(new android.graphics.Rect(0,0,query.getWidth(),query.getHeight()),true);
  },error->{if(!app.isDestroyed()&&app.body==parent)count.setText("读取课程失败："+error.getMessage());});
  CourseCatalog[] index={null};Runnable[] pending={null};
  Runnable search=()->{
   if(pending[0]!=null)app.handler.removeCallbacks(pending[0]);work.clear();result[0]=null;rows.removeAllViews();controls.run();count.setText("正在读取课程…");
   String term=app.courseQuery;int page=app.coursePage;CourseCatalog.Scope range=app.courseScope;
   pending[0]=()->work.submit(()->{if(index[0]==null)index[0]=new CourseCatalog(snapshot);return index[0].find(term,range,page);});app.handler.postDelayed(pending[0],200);
  };
  for(int i=0;i<2;i++){previous[i]=app.button("上一页",()->{app.coursePage--;search.run();});next[i]=app.button("下一页",()->{app.coursePage++;search.run();});PlannerUi.Flow navigation=i==0?top:bottom;navigation.addView(previous[i]);navigation.addView(next[i]);}
  app.closeCatalog=()->{work.close();if(pending[0]!=null)app.handler.removeCallbacks(pending[0]);};
  query.addTextChangedListener(new TextWatcher(){
   public void beforeTextChanged(CharSequence s,int start,int count,int after){}
   public void onTextChanged(CharSequence s,int start,int before,int count){app.courseQuery=s.toString();app.coursePage=0;search.run();}
   public void afterTextChanged(Editable value){}
  });
  scope.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener(){
   public void onItemSelected(android.widget.AdapterView<?> parent,View view,int position,long id){if(app.courseScope!=scopes[position]){app.courseScope=scopes[position];app.coursePage=0;search.run();}}
   public void onNothingSelected(android.widget.AdapterView<?> parent){}
  });
  top.addView(app.button("清除筛选",()->{app.courseScope=CourseCatalog.Scope.ALL;app.coursePage=0;scope.setSelection(0);query.setText("");search.run();}));
  search.run();
 }
 static final double[] DAILY_WEIGHTS={1,1.5,2,3};
 static final String[] DAILY_WEIGHT_NAMES={"标准","多学50%（1.5倍）","多学一倍（2倍）","多学两倍（3倍）"};
 static int dailyWeightIndex(double weight){int best=0;for(int i=1;i<DAILY_WEIGHTS.length;i++)if(Math.abs(weight-DAILY_WEIGHTS[i])<Math.abs(weight-DAILY_WEIGHTS[best]))best=i;return best;}
 static String dailyWeightName(double weight){int index=dailyWeightIndex(weight);return Math.abs(weight-DAILY_WEIGHTS[index])<.001?DAILY_WEIGHT_NAMES[index]:String.format(Locale.CHINA,"自定义 %.2f 倍",weight);}
 void dailyWeightControl(LinearLayout box,JSONObject course){
  double current=Planner.dailyWeight(course);
  box.addView(app.button("每日加量 · "+dailyWeightName(current),()->{
   int checked=dailyWeightIndex(current);
   AlertDialog.Builder builder=new AlertDialog.Builder(app);
   builder.setTitle("每日加量 · "+course.optString("name"));
   builder.setSingleChoiceItems(DAILY_WEIGHT_NAMES,checked,(target,index)->{
    target.dismiss();
    if(index==checked&&Math.abs(current-DAILY_WEIGHTS[index])<.001)return;
    app.mutate(s->CourseEditing.setDailyWeight(s,course.getString("id"),current,DAILY_WEIGHTS[index]),true,null,error->app.alert("每日加量未保存",error.getMessage()+"\n原有设置已保留。"));
   });
   builder.setNegativeButton("取消",null);
   builder.show();
  }));
  box.addView(app.text("提高后，未完成的学习量会优先多排到前面的日期；实际能加多少受每日可用时段和完整课节限制，可能无法一次排完。每门课程可分别设置。",12,app.muted));
 }
 void netdiskFiles(JSONObject course){app.run(()->{
  JSONObject net=course.getJSONObject("netdisk");LinearLayout form=app.col(),rows=app.col();form.setPadding(app.dp(16),0,app.dp(16),0);
  form.addView(app.text(net.optString("shareTitle")+" / "+net.optString("folderPath")+"\n"+net.optInt("videoCount")+" 个视频 · "+net.optLong("totalBytes")+" 字节 · "+net.optInt("unknownDurations")+" 个估算时长",13,app.muted));
  JSONObject dup=net.optJSONObject("duplicates");if(dup!=null)for(String key:new String[]{"groups","relatedPackages","relatedCourses","requiresReview"}){JSONArray notes=dup.optJSONArray(key);if(notes!=null)for(int i=0;i<notes.length();i++)form.addView(app.text(notes.getString(i),12,app.muted));}
  EditText query=app.field(form,"搜索课节或文件路径（可组合关键词）","",false);TextView count=app.text("正在读取文件列表…",12,app.muted);form.addView(count);
  ScrollView scroll=new ScrollView(app);scroll.addView(rows);form.addView(scroll,new LinearLayout.LayoutParams(-1,app.dp(360)));
  PlannerUi.Flow navigation=new PlannerUi.Flow(app);form.addView(navigation);Button[] pages=new Button[2];int[] page={0};CourseFileSearch.Result[] result={null};
  AlertDialog dialog=new AlertDialog.Builder(app).setTitle("网盘课节与文件").setView(form).setPositiveButton("关闭",null).create();
  Runnable render=()->{
   rows.removeAllViews();int number=result[0]==null?0:result[0].pageCount();pages[0].setEnabled(page[0]>0);pages[1].setEnabled(page[0]+1<number);
   if(result[0]==null)return;
   count.setText(result[0].count()==0?"没有匹配的课节或文件":result[0].count()+" 项 · 第 "+(page[0]+1)+" / "+number+" 页");
   for(CourseFileSearch.Row file:result[0].page(page[0]))rows.addView(app.text(file.label(),14,app.ink));scroll.scrollTo(0,0);
  };
  pages[0]=app.button("上一页",()->{page[0]--;render.run();});pages[1]=app.button("下一页",()->{page[0]++;render.run();});navigation.addView(pages[0]);navigation.addView(pages[1]);render.run();
  LatestWork<CourseFileSearch.Result> work=new LatestWork<>(app.worker,app::runOnUiThread,value->{if(!app.isDestroyed()&&dialog.isShowing()){result[0]=value;page[0]=0;render.run();}},error->{if(!app.isDestroyed()&&dialog.isShowing())count.setText("读取失败："+error.getMessage());});
  CourseFileSearch[] index={null}; // Accessed only by the shared serial worker.
  java.util.function.Consumer<String> search=term->work.submit(()->{if(index[0]==null)index[0]=new CourseFileSearch(course);return index[0].find(term);});
  Runnable[] pending={null};query.addTextChangedListener(new TextWatcher(){
   public void beforeTextChanged(CharSequence s,int start,int n,int after){}
   public void onTextChanged(CharSequence s,int start,int before,int n){if(pending[0]!=null)app.handler.removeCallbacks(pending[0]);work.clear();result[0]=null;page[0]=0;render.run();count.setText("正在筛选…");String term=s.toString();pending[0]=()->search.accept(term);app.handler.postDelayed(pending[0],200);}
   public void afterTextChanged(Editable s){}
  });
  dialog.setOnDismissListener(d->{work.close();if(pending[0]!=null)app.handler.removeCallbacks(pending[0]);});dialog.show();search.accept("");
 });}
 void sample(){app.mutate(state->{for(String key:new String[]{"courses","fixedEvents","tasks","completions"})if(state.getJSONArray(key).length()>0)throw new IllegalArgumentException("示例仅能载入空白日程。");LocalDate day=Planner.day(Planner.now());for(int i=0;i<2;i++){JSONObject course=new JSONObject().put("id",Planner.id()).put("name",i==0?"示例 · 高等数学":"示例 · 英语基础").put("type","录播课程").put("totalMinutes",i==0?720:480).put("initialCompletedMinutes",0).put("startDate",Planner.at(day,0)).put("deadline",Planner.at(day.plusDays(14),0)).put("priority",2).put("minimumBlockMinutes",60).put("color",i==0?"blue":"purple").put("isArchived",false).put("autoScheduleEnabled",true).put("notes","这是可删除的示例课程。");state.getJSONArray("courses").put(course);}},true,null);}
 void merge(){app.run(()->{List<JSONObject> courses=Planner.list(app.state.getJSONArray("courses"));courses.removeIf(c->c.optBoolean("isArchived"));if(courses.size()<2)throw new IllegalArgumentException("请先添加至少两门课程。");LinearLayout form=app.col();Set<String> ids=new HashSet<>();EditText name=app.field(form,"合并后的课程名称","合并课程",false);for(JSONObject c:courses){CheckBox choice=new CheckBox(app);choice.setText(c.getString("name")+" · "+app.hours(Planner.remaining(app.state,c)));choice.setOnCheckedChangeListener((button,checked)->{if(checked)ids.add(c.optString("id"));else ids.remove(c.optString("id"));});form.addView(choice);}form.addView(app.text("采用最早开始日和截止日；来源、课节和完成记录迁入合并课程。",12,app.muted));form.addView(app.button("预览合并后的编排",()->app.run(()->{Set<String> selected=new HashSet<>(ids);String title=app.value(name);preview(next->CourseTools.merge(next,selected,title).getString("id"));})));AlertDialog dialog=app.editor("合并课程",form);dialog.setOnShowListener(v->dialog.getButton(-1).setOnClickListener(x->app.run(()->{Set<String> selected=new HashSet<>(ids);String title=app.value(name);app.mutate(s->CourseTools.merge(s,selected,title),true,dialog::dismiss);})));dialog.show();});}
 interface PreviewChange{String apply(JSONObject state)throws Exception;}
 void preview(PreviewChange change){
  if(app.busy)return;app.busy=true;
  ProgressDialog progress=ProgressDialog.show(app,"","正在计算编排预览…",true,false);
  app.worker.execute(()->{try{
   JSONObject next=app.database.load();String courseID=change.apply(next);
   SchedulePreview result=SchedulePreview.calculate(next,courseID,Planner.now());
   app.runOnUiThread(()->{app.busy=false;progress.dismiss();if(app.isDestroyed())return;showPreview(result);app.resumeSyncRefresh();});
  }catch(Exception error){app.runOnUiThread(()->{app.busy=false;progress.dismiss();if(app.isDestroyed())return;app.alert("预览未生成",error.getMessage());app.resumeSyncRefresh();});}});
 }
 void showPreview(SchedulePreview result){
  LinearLayout form=app.col();form.setPadding(app.dp(18),app.dp(8),app.dp(18),app.dp(8));
  form.addView(app.text("已排 "+result.plannedMinutes+" 分钟 · 剩余 "+result.remainingMinutes+" 分钟 · 未排入 "+Math.max(0,result.remainingMinutes-result.plannedMinutes)+" 分钟\n预览不保存日程。",13,app.muted));
  TextView position=app.text("",12,app.muted);form.addView(position);
  LinearLayout rows=app.col();ScrollView scroll=new ScrollView(app);scroll.addView(rows);form.addView(scroll,new LinearLayout.LayoutParams(-1,app.dp(380)));
  PlannerUi.Flow navigation=new PlannerUi.Flow(app);form.addView(navigation);int[] page={0};Button[] buttons=new Button[2];
  Runnable render=()->{
   rows.removeAllViews();position.setText(result.count()==0?"没有可排入的未完成课节。":result.count()+" 项安排 · 第 "+(page[0]+1)+" / "+result.pageCount()+" 页");
   for(String line:result.page(page[0]))rows.addView(app.text(line,14,app.ink));
   buttons[0].setEnabled(page[0]>0);buttons[1].setEnabled(page[0]+1<result.pageCount());scroll.scrollTo(0,0);
  };
  buttons[0]=app.button("上一页",()->{page[0]--;render.run();});buttons[1]=app.button("下一页",()->{page[0]++;render.run();});
  navigation.addView(buttons[0]);navigation.addView(buttons[1]);render.run();
  new AlertDialog.Builder(app).setTitle(result.courseName+" · 编排预览").setView(form).setPositiveButton("关闭",null).show();
 }
 void lessonOrder(JSONObject course){app.run(()->{
  List<JSONObject> lessons=CourseTools.lessons(course);if(lessons.isEmpty())throw new IllegalArgumentException("这门课程没有可管理的独立课节。");
  Map<String,String> names=new LinkedHashMap<>();for(JSONObject l:lessons)names.put(l.getString("id"),l.getString("name"));
  LessonOrderDraft draft=new LessonOrderDraft(app.state,course.getString("id"));
  boolean[] followWebsite={false};
  List<String> order=draft.originalOrder();Set<String> selected=new HashSet<>(),deleted=new HashSet<>(),movable=new HashSet<>();for(Planner.Work w:Planner.lessonWork(app.state,course))movable.add(w.lessonID);
  LinearLayout form=app.col();form.addView(app.text("多选课节可移动或删除。删除在保存后生效，清除所选课节的安排和完成记录；请至少保留一节。",13,app.muted));
  LessonOrderPanel list=new LessonOrderPanel(app,order,names,selected,movable,deleted);form.addView(list.view);
  EditText target=app.field(form,"插入到完整列表的第几节之前（课节数 + 1 为末尾）","1",true);
  Runnable refresh=list::refresh;
  PlannerUi.Flow actions=new PlannerUi.Flow(app);form.addView(actions);
  actions.addView(app.button("删除所选课节",()->app.run(()->{
   if(selected.isEmpty())throw new IllegalArgumentException("请先选择要删除的课节。");Set<String> next=new HashSet<>(deleted);next.addAll(selected);
   List<String> retained=new ArrayList<>(order);retained.removeIf(next::contains);
   JSONObject check=CourseTools.copy(app.state);draft.apply(check,retained,next,followWebsite[0]);
   new AlertDialog.Builder(app).setTitle("删除所选的 "+selected.size()+" 节课？").setMessage("保存后将删除这些课节的全部安排和完成记录，重算总量并保留其余课节。取消或关闭窗口不会保存删除。").setNegativeButton("取消",null).setPositiveButton("删除所选课节",(d,w)->{deleted.clear();deleted.addAll(next);order.removeIf(deleted::contains);selected.clear();refresh.run();}).show();
  })));
  for(int position:new int[]{0,1,2}){String label=new String[]{"移到最前","移到最后","移动所选课节"}[position];actions.addView(app.button(label,()->app.run(()->{int at=position==0?0:position==1?order.size():app.integer(target)-1;if(at<0||at>order.size()||selected.isEmpty())throw new IllegalArgumentException("请选择课节并填写有效序号。");List<String> moved=app.movedLessons(order,selected,at);order.clear();order.addAll(moved);followWebsite[0]=false;refresh.run();})));}
  actions.addView(app.button("智能排序",()->{followWebsite[0]=false;order.clear();for(JSONObject l:CourseTools.intelligent(lessons))if(!deleted.contains(l.optString("id")))order.add(l.optString("id"));refresh.run();}));
  JSONObject web=course.optJSONObject("webCourse");if(web!=null)actions.addView(app.button("按网站顺序",()->{followWebsite[0]=true;order.clear();for(JSONObject l:lessons)if(!deleted.contains(l.optString("id")))order.add(l.optString("id"));refresh.run();}));
  actions.addView(app.button("编排预览",()->app.run(()->{List<String> previewOrder=new ArrayList<>(order);Set<String> previewDeleted=new HashSet<>(deleted);boolean previewFollow=followWebsite[0];preview(next->{draft.apply(next,previewOrder,previewDeleted,previewFollow);return course.getString("id");});})));
  AlertDialog dialog=app.editor("调整课节顺序与删除",form);dialog.setOnShowListener(v->{
   dialog.getButton(-1).setText("保存并重新排程");
   dialog.getButton(-1).setOnClickListener(x->{
    List<String> savedOrder=new ArrayList<>(order);Set<String> savedDeleted=new HashSet<>(deleted);boolean savedFollow=followWebsite[0];
    app.mutate(s->draft.apply(s,savedOrder,savedDeleted,savedFollow),true,dialog::dismiss);
   });
  });dialog.show();
 });}
 void taskDrag(LinearLayout box,PlannerUi.Flow actions,JSONObject task){if(!Planner.pending(task)||Planner.day(task.optDouble("start")).isBefore(Planner.day(Planner.now())))return;String id=task.optString("id");box.setContentDescription("长按交换 "+task.optString("lessonName",Planner.course(app.state,task.optString("courseID")).optString("name")));box.setOnLongClickListener(view->{if(app.busy)return false;return view.startDragAndDrop(ClipData.newPlainText("daily-task",id),new View.DragShadowBuilder(view),id,0);});box.setOnDragListener((view,event)->{Object local=event.getLocalState();if(!(local instanceof String)||id.equals(local))return false;JSONObject source=null;for(JSONObject t:Planner.list(app.state.optJSONArray("tasks")))if(t.optString("id").equals(local))source=t;if(source==null||!Planner.pending(source)||!Planner.day(source.optDouble("start")).equals(Planner.day(task.optDouble("start"))))return false;
   switch(event.getAction()){case DragEvent.ACTION_DRAG_STARTED:return true;case DragEvent.ACTION_DRAG_ENTERED:box.setAlpha(.65f);return true;case DragEvent.ACTION_DRAG_EXITED:case DragEvent.ACTION_DRAG_ENDED:box.setAlpha(1);return true;case DragEvent.ACTION_DROP:box.setAlpha(1);app.swapDailyTasks((String)local,id);return true;default:return true;}});
  actions.addView(app.taskAction("交换顺序",()->app.run(()->{List<JSONObject> targets=new ArrayList<>();for(JSONObject other:Planner.list(app.state.getJSONArray("tasks")))if(Planner.pending(other)&&!other.getString("id").equals(id)&&Planner.day(other.getDouble("start")).equals(Planner.day(task.getDouble("start"))))targets.add(other);if(targets.isEmpty())throw new IllegalArgumentException("当天没有其他未确认学习板块。");String[] labels=new String[targets.size()];for(int i=0;i<labels.length;i++){JSONObject t=targets.get(i),c=Planner.course(app.state,t.getString("courseID"));labels[i]=Planner.clock(t.getDouble("start"))+" · "+t.optString("lessonName",c.optString("name"));}new AlertDialog.Builder(app).setTitle("选择要交换的学习板块").setItems(labels,(dialog,index)->app.swapDailyTasks(id,targets.get(index).optString("id"))).setNegativeButton("取消",null).show();})));
 }
}
