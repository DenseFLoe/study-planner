package local.studyplanner;

import org.json.*;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;
import static local.studyplanner.AssistantProtocol.*;

/** Read-only facts. Source URLs, notes, raw lesson identities and credentials never leave here. */
final class AssistantTools {
    static JSONObject evidence(String id,String category,JSONObject data,Snapshot snapshot)throws Exception{
        return object("evidence_id",id,"category",category,"captured_at",snapshot.stamp(snapshot.now),"time_zone",snapshot.zone.getId(),"snapshot_id",snapshot.id,"data",data);
    }
    static String lessonReference(String course,String lesson)throws Exception{return hash("assistant-lesson:"+course.toUpperCase(Locale.ROOT)+":"+lesson);}
    static int offset(JSONObject input,int count)throws Exception{return integer(input.getString("offset"),0,count);}
    static JSONObject course(JSONObject state,String id,boolean optional)throws Exception{
        if(optional&&id.isEmpty())return null;
        JSONObject course=Planner.course(state,id);if(course==null||!Planner.canonicalID(id))throw invalid();return course;
    }
    static String activity(String name){
        switch(name){case "list_courses":return "正在查找课程…";case "inspect_course":return "正在查询课程进度和课节…";
        case "inspect_schedule":return "正在查询日程安排…";case "inspect_progress":return "正在统计学习进度…";
        case "inspect_rules":return "正在核对排程设置…";case "inspect_time_conflicts":case "inspect_conflicts":return "正在检查时间冲突…";
        case "calculate":return "正在计算学习数据…";default:return "正在准备日程修改预览…";}
    }
    static JSONObject query(String name,JSONObject input,Snapshot snapshot,List<JSONObject> previous)throws Exception{
        try{return execute(name,input,snapshot,previous);}catch(Failure error){
            if(!error.getMessage().equals(INVALID))throw error;
            return object("category","查询范围或参数提示","error","未找到对应课程/数值，或日期、分页、字段不符合工具定义。没有可用事实；请核对已有ID和范围，必要时向用户澄清。");
        }
    }
    static JSONObject execute(String name,JSONObject in,Snapshot shot,List<JSONObject> previous)throws Exception{
        JSONObject state=shot.state,data;String category;String id="E"+(previous.size()+1);
        switch(name){
        case "list_courses":{
            category="课程名称、编号和类型";List<JSONObject> courses=new ArrayList<>(Planner.list(state.getJSONArray("courses")));courses.sort(Comparator.comparing(c->c.optString("id")));
            int start=offset(in,courses.size()),end=Math.min(start+20,courses.size());JSONArray rows=new JSONArray();
            for(int i=start;i<end;i++){JSONObject c=courses.get(i);rows.put(object("id",c.getString("id"),"untrusted_name",trim(c.getString("name"),160),"type",c.optString("type").equals("不定时录播课程")?"分节研习":"自主研习"));}
            data=object("courses",rows,"total",courses.size(),"next_offset",end<courses.size()?String.valueOf(end):null);break;
        }
        case "inspect_course":{
            category="课程名称及编号、课节名称及编号与顺序、开始及截止日期、有效学习进度和排课设置";
            JSONObject c=course(state,in.getString("course"),false);List<Planner.Work> lessons=Planner.lessonWorkAll(state,c);int start=offset(in,lessons.size()),end=Math.min(start+20,lessons.size());
            Map<String,JSONObject> raw=new HashMap<>();for(JSONObject lesson:CourseTools.lessons(c))raw.put(lesson.getString("id"),lesson);
            JSONArray rows=new JSONArray();for(int i=start;i<end;i++){Planner.Work w=lessons.get(i);JSONObject r=raw.get(w.lessonID);
                int duration=r==null?w.minutes:r.optInt("durationMinutes",(int)Math.ceil(r.optDouble("durationSeconds",w.minutes*60.0)/60));
                rows.put(object("lesson_id",lessonReference(c.getString("id"),w.lessonID),"position",i+1,"untrusted_name",trim(w.lessonName,160),"duration_minutes",duration,"remaining_minutes",w.minutes));}
            data=object("course_id",c.getString("id"),"untrusted_name",trim(c.getString("name"),160),"total_minutes",c.getInt("totalMinutes"),"completed_minutes",Planner.completed(state,c),"remaining_minutes",Planner.remaining(state,c),
                "start_date",shot.day(c.getDouble("startDate")).toString(),"deadline",shot.day(c.getDouble("deadline")).toString(),"auto_schedule",c.optBoolean("autoScheduleEnabled",true),
                "minimum_block_minutes",c.optInt("minimumBlockMinutes")>0?c.optInt("minimumBlockMinutes"):state.getJSONObject("settings").getInt("minimumScheduleUnit"),
                "priority",c.optInt("priority",2),"daily_weight",Planner.dailyWeight(c),"lessons",rows,"lesson_count",lessons.size(),"next_offset",end<lessons.size()?String.valueOf(end):null);break;
        }
        case "inspect_schedule":{
            category="课表日期与时间、课程及任务和事项编号、课节名称及编号与关联状态、学习时长与完成状态、事项占用和本机时间核对（不含事项名称）";
            LocalDate day=date(in.getString("date"),shot.today);double lower=shot.at(day,0),upper=shot.at(day.plusDays(1),0);JSONArray rows=new JSONArray();
            List<JSONObject> tasks=new ArrayList<>(Planner.list(state.getJSONArray("tasks")));tasks.sort(Comparator.comparingDouble(t->t.optDouble("start")));
            Map<String,Set<String>> lessons=new HashMap<>();
            for(JSONObject t:tasks)if(Planner.planningStart(t)<upper&&Planner.planningEnd(t)>lower){
                String cid=t.getString("courseID"),lid=t.optString("lessonID");
                if(!lessons.containsKey(cid)){Set<String> ids=new HashSet<>();JSONObject c=Planner.course(state,cid);if(c!=null)for(Planner.Work w:Planner.lessonWorkAll(state,c))ids.add(w.lessonID);lessons.put(cid,ids);}
                rows.put(object("kind","study","task_id",t.getString("id"),"course_id",cid,"lesson_id",lid.isEmpty()?null:lessonReference(cid,lid),
                    "lesson_match",lid.isEmpty()?"not_recorded":lessons.get(cid).contains(lid)?"matched":"not_found","untrusted_lesson_name",t.has("lessonName")?trim(t.optString("lessonName"),160):null,
                    "start",shot.stamp(Planner.planningStart(t)),"end",shot.stamp(Planner.planningEnd(t)),"duration_minutes",t.getInt("durationMinutes"),"floating",floatingTask(t),
                    "status",t.optString("status"),"completed_minutes",t.optInt("completedMinutes"),"is_unconfirmed",Planner.pending(t),"confirmed_at",t.has("confirmedAt")?shot.stamp(t.getDouble("confirmedAt")):null));
            }
            for(JSONObject e:Planner.list(state.getJSONArray("fixedEvents")))if(Planner.occurs(e,day))rows.put(object("kind","event","id",e.getString("id"),"start_minute",e.getInt("startMinute"),"end_minute",e.getInt("endMinute"),"occupied_minutes",Planner.occupied(e),"floating",Planner.floating(e)));
            int start=offset(in,rows.length());data=page(rows,start,40).put("date",day.toString()).put("time_check",timeCheck(shot,day,0))
                .put("note","跨日任务按区间相交列出；duration是整条任务时长，不是当日实际用时。浮动项仅表示窗口。课节只按同一课程下的lesson_id关联，not_found或not_recorded不能猜测对应关系。");break;
        }
        case "inspect_progress":{
            category="每日计划量、实际学习量及日期不明记录的汇总";JSONObject c=course(state,in.getString("course"),true);
            LocalDate first=date(in.getString("start_date"),shot.today),last=date(in.getString("end_date"),shot.today);long span=ChronoUnit.DAYS.between(first,last);if(span<0||span>=31)throw invalid();
            Map<String,JSONObject> tasks=new HashMap<>();for(JSONObject t:Planner.list(state.getJSONArray("tasks")))tasks.put(t.getString("id"),t);
            Map<LocalDate,Long> actual=new HashMap<>(),planned=new HashMap<>();long unknown=0;
            for(JSONObject r:Planner.list(state.getJSONArray("completions")))if(c==null||c.getString("id").equals(r.getString("courseID"))){
                LocalDate day=DailyConsequences.effectiveDayWithTask(r,tasks.get(r.optString("taskID")));long minutes=r.getInt("minutes");
                if(day==null)unknown=Math.addExact(unknown,minutes);else actual.put(day,Math.addExact(actual.getOrDefault(day,0L),minutes));
            }
            for(JSONObject t:tasks.values())if(c==null||c.getString("id").equals(t.getString("courseID"))){LocalDate day=shot.day(t.getDouble("start"));planned.put(day,Math.addExact(planned.getOrDefault(day,0L),t.getInt("durationMinutes")));}
            JSONArray days=new JSONArray();for(int i=0;i<=span;i++){LocalDate day=first.plusDays(i);days.put(object("date",day.toString(),"actual_minutes",actual.getOrDefault(day,0L),"planned_by_start_day_minutes",planned.getOrDefault(day,0L)));}
            data=object("days",days,"unknown_date_minutes",unknown,"note","实际学习量不同于有效课程进度；计划量按任务开始日统计，跨日任务未拆分。");break;
        }
        case "inspect_rules":{
            category="可学习时段、实际学习起始日期与时间、休息间隔、最小学习块和排课偏好";JSONObject settings=state.getJSONObject("settings");JSONArray availability=new JSONArray();
            if(settings.getJSONArray("availability").length()>1000)throw new Failure("可学习时段过多，请缩小查询。");
            for(JSONObject a:Planner.list(settings.getJSONArray("availability")))availability.put(object("weekday",a.getInt("weekday"),"start_minute",a.getInt("startMinute"),"end_minute",a.getInt("endMinute")));
            JSONArray priorities=new JSONArray();for(int index:new SchedulePriorities(settings).order)priorities.put(SchedulePriorities.TITLES[index]);
            data=object("break_minutes",15,"minimum_block_minutes",settings.getInt("minimumScheduleUnit"),"priority_order",priorities,"availability",availability,
                "actual_study_start",settings.has("actualStudyStart")?shot.stamp(settings.getDouble("actualStudyStart")):null,"rules","星期日=1。开始、截止、可用时段、整节顺序和休息优先；均摊和每日倍率是偏好，不是每日硬上限。最终余量可短于最小块。");break;
        }
        case "inspect_time_conflicts":category="课表日期与时间、任务及事项编号、本机核实的固定时段重叠与浮动窗口容量";data=timeCheck(shot,date(in.getString("date"),shot.today),integer(in.getString("offset"),0,Integer.MAX_VALUE));break;
        case "inspect_conflicts":{
            category="冲突涉及的课程名称、开始及截止日期，以及软件核算的当前课表冲突、可用时间和未排入量";JSONObject assessment=CourseTools.copy(state);SavedScheduleAssessment.refresh(assessment,shot.now);JSONArray rows=new JSONArray();
            for(JSONObject r:Planner.list(ScheduleHealth.array(assessment,"androidConflicts"))){
                JSONObject row=object("kind","constraint","start_date",shot.day(r.optDouble("windowStart",shot.now)).toString(),"deadline",shot.day(r.getDouble("deadline")).toString(),"required_minutes",r.optLong("requiredMinutes"),"available_minutes",r.optLong("availableMinutes"),"untrusted_course_names",r.optJSONArray("courseNames"),"proven_capacity_deficit",r.opt("provenDeficit"),"minimum_continuous_minutes",r.opt("minimumContinuousMinutes"));
                JSONObject rest=r.optJSONObject("restConflict");if(rest!=null)row.put("rest",rest);rows.put(row);
            }
            for(JSONObject r:Planner.list(ScheduleHealth.array(assessment,"androidRisks")))rows.put(object("kind","unbooked","deadline",shot.day(r.getDouble("deadline")).toString(),"unscheduled_minutes",r.optLong("unscheduledMinutes")));
            data=page(rows,offset(in,rows.length()),20).put("source","SavedScheduleAssessment").put("assessment_kind","capacity_and_rules").put("note","这是容量和排程约束评估，不是实际时段重叠。未排入不等于客观缺口；搜索未找到不代表无解。没有历史决策轨迹，不能推断唯一历史原因。");break;
        }
        case "calculate":{
            category="软件核算的数值与计算依据";double left=number(in.getString("left"),previous),right=number(in.getString("right"),previous),result;
            switch(in.getString("operation")){case "add":result=left+right;break;case "subtract":result=left-right;break;case "multiply":result=left*right;break;case "divide":if(right==0)throw invalid();result=left/right;break;default:throw invalid();}
            if(!Double.isFinite(result)||Math.abs(result)>1e12)throw invalid();
            data=object("left_reference",in.getString("left"),"right_reference",in.getString("right"),"left",left,"right",right,"operation",in.getString("operation"),"result",result,"note","仅核实算术，不证明单位一致或具有因果关系。");break;
        }
        default:throw invalid();
        }
        JSONObject result=evidence(id,category,data,shot);limit(result.toString(),128000);return result;
    }
    static JSONObject page(JSONArray rows,int start,int size)throws Exception{if(start<0||start>rows.length())throw invalid();JSONArray page=new JSONArray();int end=Math.min(rows.length(),start+size);for(int i=start;i<end;i++)page.put(rows.get(i));return object("rows",page,"total",rows.length(),"next_offset",end<rows.length()?String.valueOf(end):null);}
    static double number(String path,List<JSONObject> previous)throws Exception{
        String[] parts=path.split("\\.");if(parts.length<3)throw invalid();Object current=null;
        for(JSONObject row:previous)if(parts[0].equals(row.optString("evidence_id")))current=row;if(current==null)throw invalid();
        for(int i=1;i<parts.length;i++){if(current instanceof JSONObject)current=((JSONObject)current).opt(parts[i]);else if(current instanceof JSONArray)current=((JSONArray)current).opt(integer(parts[i],0,((JSONArray)current).length()-1));else throw invalid();}
        if(!(current instanceof Number))throw invalid();double result=((Number)current).doubleValue();if(!Double.isFinite(result)||Math.abs(result)>1e12)throw invalid();return result;
    }
    static boolean floatingTask(JSONObject task){return task.has("floatingWindowStart")&&!task.isNull("floatingWindowStart");}
    static final class Item {
        final String kind,id;final double start,end,minutes;
        Item(String kind,String id,double start,double end,double minutes){this.kind=kind;this.id=id;this.start=start;this.end=end;this.minutes=minutes;}
        JSONObject reference(Snapshot shot)throws Exception{return object("kind",kind,"id",id,"start",shot.stamp(start),"end",shot.stamp(end));}
    }
    static List<double[]> merge(List<double[]> spans){
        List<double[]> ordered=new ArrayList<>(spans),out=new ArrayList<>();ordered.sort(Comparator.comparingDouble(s->s[0]));
        for(double[] span:ordered){if(span[0]>=span[1])continue;if(!out.isEmpty()&&span[0]<=out.get(out.size()-1)[1])out.get(out.size()-1)[1]=Math.max(span[1],out.get(out.size()-1)[1]);else out.add(span.clone());}return out;
    }
    static List<double[]> free(List<double[]> windows,List<Item> fixed){
        List<double[]> result=merge(windows);for(Item block:fixed){List<double[]> next=new ArrayList<>();for(double[] span:result){if(block.start>=span[1]||block.end<=span[0])next.add(span);else{if(span[0]<block.start)next.add(new double[]{span[0],block.start});if(block.end<span[1])next.add(new double[]{block.end,span[1]});}}result=next;}return result;
    }
    static JSONObject timeCheck(Snapshot shot,LocalDate day,int offset)throws Exception{
        double start=shot.at(day,0),end=shot.at(day.plusDays(1),0);List<Item> fixed=new ArrayList<>(),floating=new ArrayList<>();int historical=0,invalid=0,count=0;
        for(JSONObject t:Planner.list(shot.state.getJSONArray("tasks")))if(Planner.planningStart(t)<end&&Planner.planningEnd(t)>start){
            count++;if(!Planner.pending(t)){historical++;continue;}Item item=new Item("study",t.getString("id"),Planner.planningStart(t),Planner.planningEnd(t),t.optInt("durationMinutes"));
            if(item.minutes<=0||!Double.isFinite(item.start)||!Double.isFinite(item.end)||item.start>=item.end){invalid++;continue;}(floatingTask(t)?floating:fixed).add(item);
        }
        for(JSONObject e:Planner.list(shot.state.getJSONArray("fixedEvents")))if(Planner.occurs(e,day)){count++;Item item=new Item("event",e.getString("id"),shot.at(day,e.getInt("startMinute")),shot.at(day,e.getInt("endMinute")),Planner.occupied(e));if(e.getInt("startMinute")<0||e.getInt("endMinute")>1440||item.start>=item.end||item.minutes<=0||item.minutes*60>item.end-item.start){invalid++;continue;}(Planner.floating(e)?floating:fixed).add(item);}
        if(count>500)throw new Failure("单日超过500项，无法完整核对，请缩小日程。");
        fixed.sort(Comparator.comparingDouble(i->i.start));floating.sort(Comparator.comparingDouble(i->i.start));JSONArray rows=new JSONArray();int overlaps=0,deficits=0,joint=0;
        for(int i=0;i<fixed.size();i++)for(int j=i+1;j<fixed.size();j++){Item a=fixed.get(i),b=fixed.get(j);if(b.start>=a.end)break;double lower=Math.max(start,Math.max(a.start,b.start)),upper=Math.min(end,Math.min(a.end,b.end));if(lower<upper){overlaps++;rows.put(object("kind","fixed_overlap","first",a.reference(shot),"second",b.reference(shot),"overlap_start",shot.stamp(lower),"overlap_end",shot.stamp(upper),"overlap_minutes",(upper-lower)/60));}}
        List<List<Item>> groups=new ArrayList<>();double upper=0;
        for(Item item:floating){
            if(item.start<start||item.end>end){rows.put(object("kind","floating_window","item",item.reference(shot),"required_minutes",item.minutes,"result","outside_day_not_checked"));continue;}
            List<double[]> gaps=free(Collections.singletonList(new double[]{item.start,item.end}),fixed);double available=0,longest=0;for(double[] g:gaps){available+=(g[1]-g[0])/60;longest=Math.max(longest,(g[1]-g[0])/60);}boolean deficit=longest<item.minutes;if(deficit)deficits++;
            rows.put(object("kind","floating_window","item",item.reference(shot),"required_minutes",item.minutes,"available_minutes",available,"longest_free_minutes",longest,"result",deficit?"proven_continuous_deficit":"individually_fits","note","仅核对单项连续空档；不代表实际安排，不证明多项浮动任务能同时排入。"));
            if(groups.isEmpty()||item.start>=upper){groups.add(new ArrayList<>());upper=item.end;}else upper=Math.max(upper,item.end);groups.get(groups.size()-1).add(item);
        }
        for(List<Item> group:groups)if(group.size()>1){double required=0,available=0;List<double[]> windows=new ArrayList<>();JSONArray items=new JSONArray();for(Item i:group){required+=i.minutes;windows.add(new double[]{i.start,i.end});items.put(i.reference(shot));}for(double[] gap:free(windows,fixed))available+=(gap[1]-gap[0])/60;if(required>available){deficits++;joint++;rows.put(object("kind","floating_total_deficit","items",items,"required_minutes",required,"available_minutes",available,"deficit_minutes",required-available));}}
        return page(rows,offset,20).put("date",day.toString()).put("fixed_interval_count",fixed.size()).put("fixed_overlap_count",overlaps).put("floating_window_count",floating.size()).put("proven_floating_deficit_count",deficits)
            .put("excluded_confirmed_task_count",historical).put("invalid_entry_count",invalid).put("fixed_check_complete",invalid==0).put("joint_floating_status",joint>0?"proven_deficit":floating.size()>1?"not_verified":"not_applicable")
            .put("note","只核对已存计划；首尾相接不算重叠，已确认任务不作为待执行占用。浮动窗口不是实际占用；未核实或无效数据不能说成没有冲突。休息与容量约束另查inspect_conflicts。");
    }
}
