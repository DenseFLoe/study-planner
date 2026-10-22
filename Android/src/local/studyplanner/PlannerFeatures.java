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
 void weekly()throws Exception{
  LocalDate monday=app.selected.minusDays(app.selected.getDayOfWeek().getValue()-1);List<JSONObject> courses=Planner.list(app.state.getJSONArray("courses"));Map<String,int[]> totals=new LinkedHashMap<>();int sum=0,max=1;
  for(JSONObject c:courses)if(!c.optBoolean("isArchived"))totals.put(c.getString("id"),new int[7]);
  for(JSONObject task:Planner.list(app.state.getJSONArray("tasks"))){int day=(int)java.time.temporal.ChronoUnit.DAYS.between(monday,Planner.day(task.getDouble("start")));int[] values=totals.get(task.optString("courseID"));if(day>=0&&day<7&&values!=null){int n=Planner.pending(task)?task.optInt("durationMinutes"):task.optInt("completedMinutes");values[day]+=n;sum+=n;}}
  for(int day=0;day<7;day++){int n=0;for(int[] values:totals.values())n+=values[day];max=Math.max(max,n);}
  LinearLayout box=app.card(app.body);box.addView(app.title("本周学习 · "+app.hours(sum)));
  for(int day=0;day<7;day++){LinearLayout row=app.row();TextView label=app.text("周"+"一二三四五六日".charAt(day),12,app.muted);row.addView(label,new LinearLayout.LayoutParams(app.dp(32),-2));LinearLayout bar=app.row();int used=0;for(JSONObject c:courses){int[] values=totals.get(c.optString("id"));int n=values==null?0:values[day];used+=n;if(n>0){View segment=new View(app);segment.setBackgroundColor(app.color(c.optString("color")));bar.addView(segment,new LinearLayout.LayoutParams(0,app.dp(8),n));}}View spacer=new View(app);bar.addView(spacer,new LinearLayout.LayoutParams(0,app.dp(8),Math.max(1,max-used)));row.addView(bar,new LinearLayout.LayoutParams(0,-2,1));TextView time=app.text(app.hours(used),11,app.muted);row.addView(time,new LinearLayout.LayoutParams(app.dp(76),-2));box.addView(row);}
  StringBuilder legend=new StringBuilder();for(JSONObject c:courses)if(totals.containsKey(c.optString("id"))){if(legend.length()>0)legend.append(" · ");legend.append(c.optString("name"));}box.addView(app.text(legend.toString(),12,app.muted));
 }
 void search(){LinearLayout form=app.col();form.setPadding(app.dp(16),0,app.dp(16),0);EditText query=app.field(form,"课程或课时关键词","",false);TextView count=app.text("搜索全部历史和未来安排，点结果跳转到当天。",12,app.muted);form.addView(count);LinearLayout rows=app.col();ScrollView scroll=new ScrollView(app);scroll.addView(rows);form.addView(scroll,new LinearLayout.LayoutParams(-1,app.dp(380)));AlertDialog dialog=new AlertDialog.Builder(app).setTitle("搜索课程日期").setView(form).setNegativeButton("关闭",null).create();
  query.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int n,int after){}public void onTextChanged(CharSequence s,int start,int before,int n){rows.removeAllViews();String raw=s.toString().trim().toLowerCase(Locale.ROOT);if(raw.isEmpty()){count.setText("搜索全部历史和未来安排，点结果跳转到当天。");return;}List<JSONObject> matches=new ArrayList<>();for(JSONObject t:Planner.list(app.state.optJSONArray("tasks"))){JSONObject c=Planner.course(app.state,t.optString("courseID"));String haystack=((c==null?"":c.optString("name"))+" "+t.optString("lessonName")).toLowerCase(Locale.ROOT);boolean found=true;for(String term:raw.split("\\s+"))if(!haystack.contains(term))found=false;if(found)matches.add(t);}matches.sort(Comparator.comparingDouble(t->t.optDouble("start")));count.setText("找到 "+matches.size()+" 项安排 · 按日期排序");for(JSONObject t:matches){JSONObject c=Planner.course(app.state,t.optString("courseID"));String name=t.optString("lessonName",c==null?"已删除课程":c.optString("name"));rows.addView(app.button(Planner.date(t.optDouble("start"))+" "+Planner.clock(Planner.planningStart(t))+" · "+name+(" · "+Planner.completionDescription(t)),()->{app.selected=Planner.day(t.optDouble("start"));app.month=app.selected.withDayOfMonth(1);app.page=0;dialog.dismiss();app.render();}));}}public void afterTextChanged(Editable s){}});dialog.show();
 }
 void coursesHeader(){app.body.addView(app.button("合并课程",this::merge));app.body.addView(app.button("从网站抓取全部课程",()->app.startActivityForResult(new Intent(app,CourseImportActivity.class).putExtra("mode","website"),MainActivity.IMPORT_COURSES)));app.body.addView(app.button("从夸克网盘分享导入",()->app.startActivityForResult(new Intent(app,CourseImportActivity.class).putExtra("mode","netdisk"),MainActivity.IMPORT_COURSES)));}
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
    app.mutate(s->{JSONObject latest=Planner.course(s,course.getString("id"));if(latest==null)throw new IllegalArgumentException("该课程已删除，请刷新课程列表。");latest.put("dailyStudyWeight",DAILY_WEIGHTS[index]);},true,null,error->app.alert("每日加量未保存",error.getMessage()+"\n原有设置已保留。"));
   });
   builder.setNegativeButton("取消",null);
   builder.show();
  }));
  box.addView(app.text("提高后，未完成的学习量会优先多排到前面的日期；实际能加多少受每日可用时段和完整课节限制，可能无法一次排完。每门课程可分别设置。",12,app.muted));
 }
 void netdiskFiles(JSONObject course){app.run(()->{JSONObject net=course.getJSONObject("netdisk"),files=course.optJSONObject("netdiskLessons");LinearLayout form=app.col(),rows=app.col();form.addView(app.text(net.optString("shareTitle")+" / "+net.optString("folderPath")+"\n"+net.optInt("videoCount")+" 个视频 · "+net.optLong("totalBytes")+" 字节 · "+net.optInt("unknownDurations")+" 个估算时长",13,app.muted));JSONObject dup=net.optJSONObject("duplicates");if(dup!=null)for(String key:new String[]{"groups","relatedPackages","relatedCourses","requiresReview"}){JSONArray notes=dup.optJSONArray(key);if(notes!=null)for(int i=0;i<notes.length();i++)form.addView(app.text(notes.getString(i),12,app.muted));}EditText query=app.field(form,"搜索课节或文件路径","",false);Runnable display=()->{rows.removeAllViews();try{String term=app.value(query).toLowerCase(Locale.ROOT);for(JSONObject lesson:CourseTools.lessons(course)){JSONObject file=files==null?null:files.optJSONObject(lesson.optString("id"));String path=file==null?"":file.optString("path");if(!(lesson.optString("name")+" "+path).toLowerCase(Locale.ROOT).contains(term))continue;rows.addView(app.text(lesson.optString("name")+"\n"+path+(file==null?"":"\n"+file.optLong("size")+" 字节 · "+(file.optBoolean("estimatedDuration")?"估算时长":"网站时长")),14,app.ink));}}catch(Exception error){app.alert("显示失败",error.getMessage());}};query.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int a,int c,int f){}public void onTextChanged(CharSequence s,int a,int b,int c){display.run();}public void afterTextChanged(Editable s){}});ScrollView scroll=new ScrollView(app);scroll.addView(rows);form.addView(scroll,new LinearLayout.LayoutParams(-1,app.dp(360)));display.run();new AlertDialog.Builder(app).setTitle("网盘课节与文件").setView(form).setPositiveButton("关闭",null).show();});}
 void sample(){app.mutate(state->{for(String key:new String[]{"courses","fixedEvents","tasks","completions"})if(state.getJSONArray(key).length()>0)throw new IllegalArgumentException("示例仅能载入空白日程。");LocalDate day=Planner.day(Planner.now());for(int i=0;i<2;i++){JSONObject course=new JSONObject().put("id",Planner.id()).put("name",i==0?"示例 · 高等数学":"示例 · 英语基础").put("type","录播课程").put("totalMinutes",i==0?720:480).put("initialCompletedMinutes",0).put("startDate",Planner.at(day,0)).put("deadline",Planner.at(day.plusDays(14),0)).put("priority",2).put("minimumBlockMinutes",60).put("color",i==0?"blue":"purple").put("isArchived",false).put("autoScheduleEnabled",true).put("notes","这是可删除的示例课程。");state.getJSONArray("courses").put(course);}},true,null);}
 void merge(){app.run(()->{List<JSONObject> courses=Planner.list(app.state.getJSONArray("courses"));courses.removeIf(c->c.optBoolean("isArchived"));if(courses.size()<2)throw new IllegalArgumentException("请先添加至少两门课程。");LinearLayout form=app.col();Set<String> ids=new HashSet<>();EditText name=app.field(form,"合并后的课程名称","合并课程",false);for(JSONObject c:courses){CheckBox choice=new CheckBox(app);choice.setText(c.getString("name")+" · "+app.hours(Planner.remaining(app.state,c)));choice.setOnCheckedChangeListener((button,checked)->{if(checked)ids.add(c.optString("id"));else ids.remove(c.optString("id"));});form.addView(choice);}form.addView(app.text("采用最早开始日和截止日；来源、课节和完成记录迁入合并课程。",12,app.muted));form.addView(app.button("预览合并后的编排",()->app.run(()->{JSONObject next=CourseTools.copy(app.state);JSONObject merged=CourseTools.merge(next,ids,app.value(name));preview(next,merged);})));AlertDialog dialog=app.editor("合并课程",form);dialog.setOnShowListener(v->dialog.getButton(-1).setOnClickListener(x->app.mutate(s->CourseTools.merge(s,ids,app.value(name)),true,dialog::dismiss)));dialog.show();});}
 void preview(JSONObject state,JSONObject course)throws Exception{
  List<JSONObject> tasks=CourseTools.preview(state,course,Planner.now());LinearLayout rows=app.col();Map<String,Integer> booked=new HashMap<>();for(JSONObject t:tasks)booked.merge(t.optString("lessonID"),t.optInt("durationMinutes"),Integer::sum);
  int total=0;for(JSONObject t:tasks){total+=t.optInt("durationMinutes");rows.addView(app.text(Planner.date(t.getDouble("start"))+" "+Planner.clock(Planner.planningStart(t))+"–"+Planner.clock(Planner.planningEnd(t))+"\n"+t.optString("lessonName",course.optString("name"))+" · "+t.getInt("durationMinutes")+" 分钟",14,app.ink));}
  if(tasks.isEmpty())rows.addView(app.text("没有可排入的未完成课节。",14,app.muted));int remaining=Planner.remaining(state,course);rows.addView(app.text("已排 "+total+" 分钟 · 剩余 "+remaining+" 分钟 · 未排入 "+Math.max(0,remaining-total)+" 分钟",13,app.muted));ScrollView scroll=new ScrollView(app);scroll.addView(rows);new AlertDialog.Builder(app).setTitle(course.optString("name")+" · 编排预览").setView(scroll).setPositiveButton("关闭",null).show();
 }
 void lessonOrder(JSONObject course){app.run(()->{
  List<JSONObject> lessons=CourseTools.lessons(course);if(lessons.isEmpty())throw new IllegalArgumentException("这门课程没有可管理的独立课节。");
  Map<String,String> names=new LinkedHashMap<>();for(JSONObject l:lessons)names.put(l.getString("id"),l.getString("name"));
  List<String> order=CourseTools.order(course);Set<String> selected=new HashSet<>(),deleted=new HashSet<>(),movable=new HashSet<>();for(Planner.Work w:Planner.lessonWork(app.state,course))movable.add(w.lessonID);
  LinearLayout form=app.col(),rows=app.col();form.addView(app.text("多选课节可移动或删除。删除在保存后生效，清除所选课节的安排和完成记录；请至少保留一节。",13,app.muted));
  TextView summary=app.text("",13,app.muted);form.addView(summary);
  ScrollView scroll=new ScrollView(app);scroll.addView(rows);form.addView(scroll,new LinearLayout.LayoutParams(-1,app.dp(280)));EditText target=app.field(form,"插入到第几节之前（课节数 + 1 为末尾）","1",true);
  Runnable refresh=()->{app.renderLessonOrderRows(rows,order,names,selected,movable);summary.setText("待删除 "+deleted.size()+" 节 · 保存后重新排程");};refresh.run();
  form.addView(app.button("删除所选课节",()->app.run(()->{
   if(selected.isEmpty())throw new IllegalArgumentException("请先选择要删除的课节。");Set<String> next=new HashSet<>(deleted);next.addAll(selected);
   JSONObject check=CourseTools.copy(app.state);CourseTools.removeLessons(check,course.getString("id"),next);
   new AlertDialog.Builder(app).setTitle("删除所选的 "+selected.size()+" 节课？").setMessage("保存后将删除这些课节的全部安排和完成记录，重算总量并保留其余课节。取消或关闭窗口不会保存删除。").setNegativeButton("取消",null).setPositiveButton("删除所选课节",(d,w)->{deleted.clear();deleted.addAll(next);order.removeIf(deleted::contains);selected.clear();refresh.run();}).show();
  })));
  for(int position:new int[]{0,1,2}){String label=new String[]{"移到最前","移到最后","移动所选课节"}[position];form.addView(app.button(label,()->app.run(()->{int at=position==0?0:position==1?order.size():app.integer(target)-1;if(at<0||at>order.size()||selected.isEmpty())throw new IllegalArgumentException("请选择课节并填写有效序号。");List<String> moved=app.movedLessons(order,selected,at);order.clear();order.addAll(moved);refresh.run();})));}
  form.addView(app.button("智能排序",()->{order.clear();for(JSONObject l:CourseTools.intelligent(lessons))if(!deleted.contains(l.optString("id")))order.add(l.optString("id"));refresh.run();}));
  JSONObject web=course.optJSONObject("webCourse");if(web!=null)form.addView(app.button("按网站顺序",()->{order.clear();for(JSONObject l:lessons)if(!deleted.contains(l.optString("id")))order.add(l.optString("id"));refresh.run();}));
  form.addView(app.button("编排预览",()->app.run(()->{JSONObject draft=CourseTools.copy(app.state);if(!deleted.isEmpty())CourseTools.removeLessons(draft,course.getString("id"),deleted);JSONObject current=Planner.course(draft,course.getString("id"));current.put("lessonOrder",new JSONArray(order));preview(draft,current);})));
  AlertDialog dialog=app.editor("调整课节顺序与删除",form);dialog.setOnShowListener(v->{dialog.getButton(-1).setText("保存并重新排程");dialog.getButton(-1).setOnClickListener(x->app.mutate(s->{
   if(!deleted.isEmpty())CourseTools.removeLessons(s,course.getString("id"),deleted);JSONObject current=Planner.course(s,course.getString("id"));if(current==null)throw new IllegalArgumentException("课程已删除，请刷新。");List<String> website=sourceOrder(lessons);website.removeIf(deleted::contains);boolean follows=web!=null&&order.equals(website);current.put("lessonOrder",new JSONArray(order)).put("lessonOrderCustomized",!follows);
  },true,dialog::dismiss));});dialog.show();
 });}
 static List<String> sourceOrder(List<JSONObject> lessons){List<String> ids=new ArrayList<>();for(JSONObject l:lessons)ids.add(l.optString("id"));return ids;}
 void taskDrag(LinearLayout box,PlannerUi.Flow actions,JSONObject task){if(!Planner.pending(task)||Planner.day(task.optDouble("start")).isBefore(Planner.day(Planner.now())))return;String id=task.optString("id");box.setContentDescription("长按交换 "+task.optString("lessonName",Planner.course(app.state,task.optString("courseID")).optString("name")));box.setOnLongClickListener(view->{if(app.busy)return false;return view.startDragAndDrop(ClipData.newPlainText("daily-task",id),new View.DragShadowBuilder(view),id,0);});box.setOnDragListener((view,event)->{Object local=event.getLocalState();if(!(local instanceof String)||id.equals(local))return false;JSONObject source=null;for(JSONObject t:Planner.list(app.state.optJSONArray("tasks")))if(t.optString("id").equals(local))source=t;if(source==null||!Planner.pending(source)||!Planner.day(source.optDouble("start")).equals(Planner.day(task.optDouble("start"))))return false;
   switch(event.getAction()){case DragEvent.ACTION_DRAG_STARTED:return true;case DragEvent.ACTION_DRAG_ENTERED:box.setAlpha(.65f);return true;case DragEvent.ACTION_DRAG_EXITED:case DragEvent.ACTION_DRAG_ENDED:box.setAlpha(1);return true;case DragEvent.ACTION_DROP:box.setAlpha(1);app.swapDailyTasks((String)local,id);return true;default:return true;}});
  actions.addView(app.taskAction("交换顺序",()->app.run(()->{List<JSONObject> targets=new ArrayList<>();for(JSONObject other:Planner.list(app.state.getJSONArray("tasks")))if(Planner.pending(other)&&!other.getString("id").equals(id)&&Planner.day(other.getDouble("start")).equals(Planner.day(task.getDouble("start"))))targets.add(other);if(targets.isEmpty())throw new IllegalArgumentException("当天没有其他未确认学习板块。");String[] labels=new String[targets.size()];for(int i=0;i<labels.length;i++){JSONObject t=targets.get(i),c=Planner.course(app.state,t.getString("courseID"));labels[i]=Planner.clock(t.getDouble("start"))+" · "+t.optString("lessonName",c.optString("name"));}new AlertDialog.Builder(app).setTitle("选择要交换的学习板块").setItems(labels,(dialog,index)->app.swapDailyTasks(id,targets.get(index).optString("id"))).setNegativeButton("取消",null).show();})));
 }
}
