package local.studyplanner;

import org.json.*;
import java.time.*;
import java.util.*;
import static local.studyplanner.AssistantProtocol.*;

/** Proposals contain complete local states; only the short native summary is sent to the model. */
final class AssistantActions {
    interface Check {void run()throws Exception;}
    interface CheckedStore extends StateMutation.Store<JSONObject> {void saveChecked(JSONObject state,Check check)throws Exception;}
    static final class Proposal {
        final String id=Planner.id(),title,summary,beforeID,afterID;final JSONObject before,after;
        final List<String> details=new ArrayList<>();final Snapshot snapshot;final double expires;
        Proposal(String title,JSONObject next,Snapshot shot)throws Exception {
            this.title=title;snapshot=shot;before=CourseTools.copy(shot.state);after=CourseTools.copy(next);beforeID=signature(before);afterID=signature(after);
            if(beforeID.equals(afterID))throw new Failure("当前课表已经符合此方案，无需修改，也没有写入。");
            double expiry=Planner.now()+120;for(JSONObject state:Arrays.asList(before,after))for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(task)&&Planner.planningStart(task)>shot.now)expiry=Math.min(expiry,Planner.planningStart(task));expires=expiry;
            List<String> counts=new ArrayList<>();
            for(String key:new String[]{"courses","fixedEvents","tasks","completions"}){
                Map<String,JSONObject> old=index(before,key),fresh=index(after,key);int added=0,removed=0,changed=0;String label=label(key);
                for(JSONObject row:Planner.list(before.getJSONArray(key))){JSONObject value=fresh.get(row.getString("id"));if(value==null){removed++;details.add("删除"+label+"："+describe(key,row));}
                    else if(!SyncLedger.canonical(row).equals(SyncLedger.canonical(value))){changed++;details.add("修改"+label+"\n原："+describe(key,row)+"\n新："+describe(key,value));}}
                for(JSONObject row:Planner.list(after.getJSONArray(key)))if(!old.containsKey(row.getString("id"))){added++;details.add("新增"+label+"："+describe(key,row));}
                counts.add(label+"：新增 "+added+"，修改 "+changed+"，删除 "+removed);
            }
            if(!SyncLedger.canonical(before.getJSONObject("settings")).equals(SyncLedger.canonical(after.getJSONObject("settings"))))details.add("更新当天任务顺序或立即学习安排，与上方预览一致。\n原："+safeSettings(before)+"\n新："+safeSettings(after));
            for(JSONObject risk:Planner.list(ScheduleHealth.array(after,"androidRisks")))if(risk.optLong("unscheduledMinutes")>0)details.add("预览排程提醒：截至 "+snapshot.day(risk.getDouble("deadline"))+"，未排入 "+risk.optLong("unscheduledMinutes")+" 分钟；这不代表无解。");
            summary=String.join("\n",counts)+"\n未排入量不代表无解，请展开全部差异核对。";
            if(details.size()>10000)throw new Failure("修改范围过大，请分步操作。");
        }
        void validate(JSONObject current,double now)throws Exception {
            if(now>=expires||!snapshot.today.equals(snapshot.day(now))||!snapshot.zone.equals(Planner.ZONE)||!beforeID.equals(signature(current)))throw new Failure("修改方案已过期或日程已变化，未写入；请重新发送指令并核对新预览。");
        }
        private String safeSettings(JSONObject state)throws Exception{JSONObject s=state.getJSONObject("settings");return object("dailyTaskOrders",s.optJSONArray("dailyTaskOrders"),"immediateStudy",s.optJSONObject("immediateStudy")).toString();}
        private String describe(String key,JSONObject value)throws Exception{
            String id=value.getString("id");
            if(key.equals("courses"))return value.getString("name")+" · "+id+"\n"+snapshot.day(value.getDouble("startDate"))+" 至 "+snapshot.day(value.getDouble("deadline"))+" · 总量 "+value.getInt("totalMinutes")+" 分钟 · 优先级 "+value.optInt("priority",2)+" · 每日倍率 "+Planner.dailyWeight(value)+" · 最小块 "+value.optInt("minimumBlockMinutes")+" 分钟 · 自动排课"+(value.optBoolean("autoScheduleEnabled",true)?"开启":"关闭");
            if(key.equals("fixedEvents"))return value.getString("title")+" · "+id+"\n"+snapshot.day(value.getDouble("startDate"))+" 至 "+snapshot.day(value.getDouble("endDate"))+" · "+Planner.time(value.getInt("startMinute"))+"–"+Planner.time(value.getInt("endMinute"))+" · 星期（日=1）"+value.optJSONArray("weekdays")+" · 浮动分钟 "+value.opt("floatingDurationMinutes")+" · 跳过日期 "+excluded(value);
            if(key.equals("tasks")){JSONObject c=Planner.course(after,value.optString("courseID"));if(c==null)c=Planner.course(before,value.optString("courseID"));return (c==null?"未知课程":c.optString("name"))+" · "+value.optString("lessonName")+" · "+id+"\n"+snapshot.stamp(Planner.planningStart(value))+" 至 "+snapshot.stamp(Planner.planningEnd(value))+" · "+value.getInt("durationMinutes")+" 分钟 · "+(AssistantTools.floatingTask(value)?"浮动窗口":"固定时段")+" · "+value.optString("status");}
            return id+" · "+value.optInt("minutes")+" 分钟 · 学习日期 "+(value.has("studyDate")?snapshot.day(value.getDouble("studyDate")):"待核对");
        }
        private String excluded(JSONObject value)throws Exception{List<String> days=new ArrayList<>();JSONArray dates=value.optJSONArray("excludedDates");if(dates!=null)for(int i=0;i<dates.length();i++)days.add(snapshot.day(dates.getDouble(i)).toString());return String.join(",",days);}
    }
    static Map<String,JSONObject> index(JSONObject state,String key)throws Exception{Map<String,JSONObject> out=new LinkedHashMap<>();for(JSONObject row:Planner.list(state.getJSONArray(key)))out.put(row.getString("id"),row);return out;}
    static String label(String key){switch(key){case "courses":return "课程";case "fixedEvents":return "事项";case "tasks":return "学习任务";default:return "学习记录";}}
    static final class Result {final JSONObject evidence;final Proposal proposal;Result(JSONObject evidence,Proposal proposal){this.evidence=evidence;this.proposal=proposal;}}
    static Result execute(String name,JSONObject input,Snapshot snapshot,String id,boolean proposed)throws Exception{
        if(name.equals("list_events")){
            List<JSONObject> events=new ArrayList<>(Planner.list(snapshot.state.getJSONArray("fixedEvents")));events.sort(Comparator.comparing(e->e.optString("id")));int start=AssistantTools.offset(input,events.size()),end=Math.min(start+20,events.size());JSONArray rows=new JSONArray();
            for(int i=start;i<end;i++){JSONObject e=events.get(i);JSONArray dates=new JSONArray();for(int j=0;j<e.getJSONArray("excludedDates").length();j++)dates.put(snapshot.day(e.getJSONArray("excludedDates").getDouble(j)).toString());
                rows.put(object("event_id",e.getString("id"),"untrusted_title",trim(e.getString("title"),128),"start_date",snapshot.day(e.getDouble("startDate")).toString(),"end_date",snapshot.day(e.getDouble("endDate")).toString(),"start_time",Planner.time(e.getInt("startMinute")),"end_time",Planner.time(e.getInt("endMinute")),"weekdays",e.getJSONArray("weekdays"),"excluded_dates",dates,"floating_minutes",e.opt("floatingDurationMinutes")));}
            return new Result(AssistantTools.evidence(id,"事项名称、编号与重复规则",object("events",rows,"total",events.size(),"next_offset",end<events.size()?String.valueOf(end):null),snapshot),null);
        }
        Proposal proposal=null;JSONObject data;
        if(proposed)data=object("status","not_applied","message","本轮已有待确认方案，未生成第二个修改；请完成或取消当前方案后再发指令。");
        else try{proposal=prepare(name,input,snapshot);data=object("status","awaiting_local_confirmation","untrusted_title",proposal.title,"summary",proposal.summary,"message","尚未保存。完整差异仅在本机确认卡片展示；只有用户点击确认应用才会写入。");}
        catch(Exception error){data=object("status","not_applied","message",error instanceof DailyTaskOrdering.MoveFailure?error.getMessage():error instanceof Planner.EventConflictException||error instanceof FixedEventEditing.ReviewRequired?"事项与现有安排冲突，未修改或自动跳过。请调整后重新提出方案。":"参数无效、对象已变化或该操作不适用；没有保存。请核对ID、日期、字段和可用时段；信息不足时询问用户。");}
        return new Result(AssistantTools.evidence(id,"日程修改预览、事项名称、日期时间与影响范围",data,snapshot),proposal);
    }
    static LocalDate actionDate(String text,Snapshot shot)throws Exception{LocalDate day=date(text,null);if(day.isBefore(shot.today.minusYears(10))||day.isAfter(shot.today.plusYears(5)))throw invalid();return day;}
    static String title(String text)throws Exception{if(text.trim().isEmpty()||text.chars().anyMatch(Character::isISOControl))throw invalid();return text;}
    static int minute(String text)throws Exception{int n=Planner.minute(text);if(!Planner.time(n).equals(text))throw invalid();return n;}
    static Proposal prepare(String name,JSONObject in,Snapshot shot)throws Exception{
        JSONObject next=CourseTools.copy(shot.state);String title;boolean replan=true;
        switch(name){
        case "preview_add_course":{
            LocalDate start=actionDate(in.getString("start_date"),shot),deadline=actionDate(in.getString("deadline"),shot);if(start.isAfter(deadline)||deadline.isBefore(shot.today))throw invalid();
            JSONObject c=object("id",Planner.id(),"name",title(in.getString("name")),"type","录播课程","totalMinutes",integer(in.getString("total_minutes"),1,1000000),"initialCompletedMinutes",0,"startDate",shot.at(start,0),"deadline",shot.at(deadline,0),"minimumBlockMinutes",integer(in.getString("minimum_block"),1,1440),"priority",2,"color","blue","notes","","autoScheduleEnabled",true,"isArchived",false);
            CourseTools.updateCourse(next,c,shot.now);title="新增课程："+c.getString("name");break;
        }
        case "preview_edit_course":{
            JSONObject original=AssistantTools.course(next,in.getString("course"),false);if(original.optBoolean("isArchived"))throw invalid();JSONObject c=CourseTools.copy(original);String field=in.getString("field"),value=in.getString("value");
            switch(field){case "name":c.put("name",title(value));replan=false;break;
            case "start_date":c.put("startDate",shot.at(actionDate(value,shot),0));break;case "deadline":c.put("deadline",shot.at(actionDate(value,shot),0));break;
            case "priority":c.put("priority",integer(value,1,5));break;case "daily_weight":double weight=Double.parseDouble(value);if(!Double.isFinite(weight)||weight<1||weight>3)throw invalid();c.put("dailyStudyWeight",weight);break;
            case "minimum_block":c.put("minimumBlockMinutes",integer(value,0,1440));break;
            case "auto_schedule":if(!value.equals("true")&&!value.equals("false"))throw invalid();c.put("autoScheduleEnabled",value.equals("true"));break;
            case "total_minutes":if(!c.optString("type").equals("录播课程")||c.has("manualLessons")||c.has("webCourse")||c.has("netdisk")||c.has("mergedSources"))throw invalid();int total=integer(value,1,1000000);if(total<Planner.completed(next,original))throw invalid();c.put("totalMinutes",total);break;
            default:throw invalid();}
            if(c.getDouble("startDate")>c.getDouble("deadline"))throw invalid();CourseTools.updateCourse(next,c,shot.now);title="修改课程："+original.getString("name");break;
        }
        case "preview_delete_course":{JSONObject c=AssistantTools.course(next,in.getString("course"),false);if(c.optBoolean("isArchived"))throw invalid();title="删除课程及其学习记录："+c.getString("name");Planner.removeCourse(next,c.getString("id"));break;}
        case "preview_add_event":case "preview_edit_event":{
            JSONObject original=null,e;
            if(name.equals("preview_add_event")){
                JSONArray weekdays=new JSONArray();Set<Integer> days=new HashSet<>();String text=in.getString("weekdays");if(!text.isEmpty())for(String part:text.split(",",-1)){int day=integer(part,1,7);if(!days.add(day))throw invalid();weekdays.put(day);}
                e=object("id",Planner.id(),"title",title(in.getString("title")),"startMinute",minute(in.getString("start_time")),"endMinute",minute(in.getString("end_time")),"startDate",shot.at(actionDate(in.getString("start_date"),shot),0),"endDate",shot.at(actionDate(in.getString("end_date"),shot),0),"weekdays",weekdays,"excludedDates",new JSONArray(),"notes","","color","orange");
            }else{
                original=index(next,"fixedEvents").get(in.getString("event"));if(original==null)throw invalid();e=CourseTools.copy(original);String value=in.getString("value");
                switch(in.getString("field")){case "title":e.put("title",title(value));break;
                case "start_date":e.put("startDate",shot.at(actionDate(value,shot),0));if(e.getJSONArray("weekdays").length()==0)e.put("endDate",e.getDouble("startDate"));break;
                case "end_date":e.put("endDate",shot.at(actionDate(value,shot),0));if(e.getJSONArray("weekdays").length()==0)e.put("startDate",e.getDouble("endDate"));break;
                case "start_time":e.put("startMinute",minute(value));break;case "end_time":e.put("endMinute",minute(value));break;default:throw invalid();}
            }
            if(e.getDouble("startDate")>e.getDouble("endDate")||e.getJSONArray("weekdays").length()==0&&!shot.day(e.getDouble("startDate")).equals(shot.day(e.getDouble("endDate"))))throw invalid();
            FixedEventEditing.save(next,e,original,shot.now,Collections.emptySet(),Collections.emptySet(),null);title=(original==null?"新增事项：":"修改事项：")+e.getString("title");break;
        }
        case "preview_delete_event":{JSONObject e=index(next,"fixedEvents").get(in.getString("event"));if(e==null)throw invalid();title="删除整个事项规则："+e.getString("title");FixedEventEditing.removeAll(next,e);break;}
        case "preview_replan":title="按当前规则重新排课";break;
        case "preview_move_task":{
            LocalDate target=actionDate(in.getString("target_date"),shot);String time=in.getString("start_time");
            DailyTaskOrdering.move(next,in.getString("task"),target,time.isEmpty()?null:minute(time),shot.now);
            title="单独移动学习任务至 "+target;replan=false;break;
        }
        case "preview_swap_tasks":next=new DailyTaskSwapDraft(next,in.getString("source"),in.getString("target"),shot.now).preview;title="交换当天两项学习任务";replan=false;break;
        default:throw invalid();}
        if(!name.equals("preview_move_task"))Planner.removeArchivedCourses(next);if(replan)Planner.replan(next,shot.now);else if(name.equals("preview_move_task"))Planner.refreshDiagnostics(next,shot.now);Planner.validate(next);PlannerBackupFile.businessState(next);return new Proposal(title,next,shot);
    }
    /** The same monitor as cloud/local commits; PlannerDatabase.save backs up before its transaction. */
    static JSONObject apply(StateMutation.Store<JSONObject> store,Proposal proposal,double now)throws Exception{
        return apply(store,proposal,()->now);
    }
    static JSONObject apply(StateMutation.Store<JSONObject> store,Proposal proposal,java.util.function.DoubleSupplier now)throws Exception{
        synchronized(store){
            JSONObject current=store.load();Check guard=()->proposal.validate(current,now.getAsDouble());guard.run();JSONObject next=CourseTools.copy(proposal.after);
            if(store instanceof CheckedStore)((CheckedStore)store).saveChecked(next,guard);else{guard.run();store.save(next);}return store.load();
        }
    }
    static JSONObject undo(StateMutation.Store<JSONObject> store,JSONObject before,String expected)throws Exception{
        synchronized(store){JSONObject current=store.load();if(!expected.equals(signature(current)))throw new Failure("修改后日程已有更新，不能直接撤销。请到数据与备份核对修改前的自动备份。");store.save(CourseTools.copy(before));return store.load();}
    }
}
