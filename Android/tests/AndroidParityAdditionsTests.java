package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.time.*;
import java.util.*;

public final class AndroidParityAdditionsTests {
    static int checks;
    static void check(boolean ok,String text){checks++;if(!ok)throw new AssertionError(text);}
    static JSONObject state()throws Exception{
        JSONObject s=StudySettingsTests.state();s.getJSONArray("courses").getJSONObject(0).put("deadline",Planner.at(StudySettingsTests.TODAY.plusDays(3),0)).put("color","blue").put("notes","");return s;
    }
    static void immediate()throws Exception{
        LocalDate day=StudySettingsTests.TODAY;double now=Planner.at(day,480)+12;
        JSONObject s=state(),course=s.getJSONArray("courses").getJSONObject(0);String id=course.getString("id");
        Planner.replan(s,Planner.at(day,480));String originalCourse=course.toString();
        ImmediateStudy.startLesson(s,id,"B",now);JSONObject pin=ImmediateStudy.valid(s,now);
        check(pin!=null&&pin.getDouble("start")==Planner.at(day,481),"round up start");
        check(pin.getString("lessonID").equals("B"),"choose any lesson");
        check(Planner.completed(s,course)==0&&s.getJSONArray("completions").length()==0,"no fabricated progress");
        check(originalCourse.equals(course.toString()),"course/order untouched");
        Planner.replan(s,now+30);check(ImmediateStudy.valid(s,now+30).getString("id").equals(pin.getString("id")),"replan retains pin");
        SyncLedger ledger=new SyncLedger();ledger.capture(s);s=ledger.materialize();Planner.replan(s,now+40);
        check(s.getJSONArray("tasks").getJSONObject(0).getString("id").equals(pin.getString("id")),"sync retains selected start");
        int total=0;for(JSONObject t:Planner.list(s.getJSONArray("tasks")))if(Planner.pending(t))total+=t.getInt("durationMinutes");check(total==120,"no duplicate scheduled minutes");
        Files.writeString(Paths.get("Android/build/tests/immediate-parity.json"),PlannerBackupFile.businessState(s).toString());
        JSONObject narrow=state();narrow.getJSONObject("settings").put("availability",StudySettingsTests.windows(480,510));
        String cid=narrow.getJSONArray("courses").getJSONObject(0).getString("id");
        ImmediateStudy.startLesson(narrow,cid,"B",Planner.at(day,480));JSONObject first=ImmediateStudy.valid(narrow,Planner.at(day,480));
        check(first.getInt("durationMinutes")==30&&ImmediateStudy.request(narrow).getBoolean("continuesLesson"),"short first segment");
        Planner.confirm(narrow,first.getString("id"),30,Planner.at(day,510));
        narrow.getJSONObject("settings").put("availability",StudySettingsTests.windows(480,900));Planner.replan(narrow,Planner.at(day,525));
        JSONObject next=ImmediateStudy.first(narrow,day);check(next.getString("lessonID").equals("B")&&next.getInt("durationMinutes")==30,"finish same lesson first");
        check(Planner.remaining(narrow,Planner.course(narrow,cid))==90,"partial confirmation retains remaining amount");
        JSONObject blocked=state();String before=blocked.toString();
        try{ImmediateStudy.startLesson(blocked,blocked.getJSONArray("courses").getJSONObject(0).getString("id"),"A",Planner.at(day,420));throw new AssertionError("outside window allowed");}catch(IllegalArgumentException expected){}
        check(before.equals(blocked.toString()),"failed start atomic");
        JSONObject resume=state();Planner.replan(resume,Planner.at(day,480));JSONObject head=ImmediateStudy.first(resume,day);
        ImmediateStudy.resume(resume,day,head.getString("id"),Planner.at(day,600));
        check(ImmediateStudy.valid(resume,Planner.at(day,600)).getInt("durationMinutes")==60,"continue keeps full duration");
        JSONObject fixed=state(),event=FloatingDateCapacityTests.event(day,480,540,60);event.remove("floatingDurationMinutes");fixed.getJSONArray("fixedEvents").put(event);
        before=fixed.toString();try{ImmediateStudy.startLesson(fixed,fixed.getJSONArray("courses").getJSONObject(0).getString("id"),"A",Planner.at(day,480));throw new AssertionError("fixed event overwritten");}catch(IllegalArgumentException expected){}check(before.equals(fixed.toString()),"fixed event protects failed start");
        JSONObject floating=state();floating.getJSONArray("fixedEvents").put(FloatingDateCapacityTests.event(day,480,540,30));
        ImmediateStudy.startLesson(floating,floating.getJSONArray("courses").getJSONObject(0).getString("id"),"A",Planner.at(day,480));
        check(ImmediateStudy.valid(floating,Planner.at(day,480)).getInt("durationMinutes")==30,"shorten around floating reservation");
        JSONObject rest=state();Planner.replan(rest,Planner.at(day,480));JSONObject done=ImmediateStudy.first(rest,day);Planner.confirm(rest,done.getString("id"),60,Planner.at(day,540));
        before=rest.toString();try{ImmediateStudy.startLesson(rest,rest.getJSONArray("courses").getJSONObject(0).getString("id"),"B",Planner.at(day,545));throw new AssertionError("rest overwritten");}catch(IllegalArgumentException expected){}check(before.equals(rest.toString()),"confirmed rest protected");
    }
    static void backups()throws Exception{
        Path dir=Files.createTempDirectory("planner-parity-backup-");
        try{
            PlannerBackupRepository repo=new PlannerBackupRepository(dir.toFile());JSONObject s=state();String id=s.getJSONArray("courses").getJSONObject(0).getString("id");
            PlannerBackupRepository.Entry deletion=repo.save(s,Planner.now(),"删除课程前",id);
            JSONObject current=CourseTools.copy(s);Planner.removeCourse(current,id);JSONObject other=PlannerTests.course("new course",60,StudySettingsTests.TODAY,StudySettingsTests.TODAY,60);current.getJSONArray("courses").put(other);
            PlannerBackupRepository.restoreCourse(current,repo.load(deletion.id));
            check(Planner.course(current,id)!=null&&Planner.course(current,other.getString("id"))!=null,"restore only deleted course");
            String before=current.toString();try{PlannerBackupRepository.restoreCourse(current,repo.load(deletion.id));throw new AssertionError("duplicate restore");}catch(IllegalArgumentException expected){}check(before.equals(current.toString()),"restore collision atomic");
            CourseTools.merge(current,new HashSet<>(Arrays.asList(id,other.getString("id"))),"Synthetic merged course");before=current.toString();
            try{PlannerBackupRepository.restoreCourse(current,repo.load(deletion.id));throw new AssertionError("merged source restored twice");}catch(IllegalArgumentException expected){}check(before.equals(current.toString()),"merged source blocks duplicate restore");
            Path damaged=dir.resolve(Planner.id()+".json");Files.write(damaged,new byte[]{0});
            for(int n=0;n<23;n++)repo.save(s,100+n,"test",null);
            check(repo.entries().size()==20&&repo.unreadable==1&&Files.exists(damaged),"retain 20 readable and damaged file");
            PlannerBackupRepository.Entry newest=repo.save(s,0,"clock moved backwards",null);
            check(repo.load(newest.id)!=null&&repo.entries().size()==20,"never evict freshly written backup");
        }finally{try(java.util.stream.Stream<Path> paths=Files.walk(dir)){paths.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.delete(p);}catch(Exception e){throw new RuntimeException(e);}});}}
    }
    static void selective()throws Exception{
        JSONObject s=state();double start=Planner.at(StudySettingsTests.TODAY,480),now=Planner.at(StudySettingsTests.TODAY.plusDays(4),1000);Planner.replan(s,start);
        ConfirmationReview review=new ConfirmationReview(s,Planner.review(s,now),now);List<ConfirmationReview.Row> rows=review.page(0);
        check(rows.size()==2,"confirmation fixture");rows.get(0).minutes="60";rows.get(1).minutes="invalid retained draft";rows.get(1).selected=false;
        ConfirmationReview.Submission chosen=review.submission(now);check(chosen.minutes.size()==1,"unselected invalid draft excluded");
        Planner.confirm(s,rows.get(0).id,60,now);ConfirmationReview remaining=review.refresh(s,now).review;
        check(remaining.count()==1&&!remaining.page(0).get(0).selected&&remaining.page(0).get(0).minutes.equals("invalid retained draft"),"remaining raw draft preserved");
    }
    static void websites()throws Exception{
        JSONObject web=ImportParityTests.snapshotFor(ImportParityTests.now,"generic:42:live:Lecture:1").put("packageID","generic:42").put("sourceURL","https://www.ixuecheng.cn/detail?id=42");
        JSONObject lesson=web.getJSONArray("lessons").getJSONObject(0);lesson.put("name","Lecture").put("kind","living");
        JSONObject s=PlannerTests.empty();WebCourseImport.save(s,Collections.singletonList(web),ImportParityTests.deadline,ImportParityTests.now);
        JSONObject course=s.getJSONArray("courses").getJSONObject(0);String id=course.getString("id");
        check(WebsiteUpdatePolicy.sourceURL("https://www.ixuecheng.cn/detail?id=42",course).endsWith("id=42"),"bound source URL");
        for(String url:new String[]{"https://www.ixuecheng.cn.evil.example/detail?id=42","https://www.ixuecheng.cn/detail?id=43","https://www.ixuecheng.cn/detail?id=42&token=SYNTHETIC_TOKEN","http://www.ixuecheng.cn/detail?id=42","https://www.ixuecheng.cn/detail?id=42&id=42"}){
            try{WebsiteUpdatePolicy.sourceURL(url,course);throw new AssertionError("unsafe URL accepted");}catch(IllegalArgumentException|java.net.URISyntaxException expected){checks++;}
        }
        JSONObject fresh=CourseTools.copy(web).put("fetchedAt",ImportParityTests.now+10);fresh.getJSONArray("lessons").getJSONObject(0).put("id","generic:42:live:Lecture:0.1:0");
        check(WebsiteUpdatePolicy.validate(fresh,course).getJSONArray("lessons").getJSONObject(0).getString("id").equals(lesson.getString("id")),"unique live identity retained");
        JSONObject task=Planner.task(id,ImportParityTests.now,60).put("lessonID",lesson.getString("id"));s.getJSONArray("tasks").put(task);Planner.confirm(s,task.getString("id"),20,ImportParityTests.now+1);
        course.put("name","Local name").put("lessonOrderCustomized",true).put("lessonOrder",new JSONArray().put(lesson.getString("id")));
        WebsiteUpdatePolicy.apply(s,id,fresh,ImportParityTests.now+20);
        check(Planner.course(s,id).getString("name").equals("Local name")&&s.getJSONArray("completions").length()==1,"automatic update retains name and progress");
        String before=s.toString();JSONObject missing=CourseTools.copy(fresh).put("lessons",new JSONArray());
        try{WebsiteUpdatePolicy.apply(s,id,missing,ImportParityTests.now+30);throw new AssertionError("missing catalog accepted");}catch(IllegalArgumentException expected){}check(before.equals(s.toString()),"missing lesson rejects atomically");
        JSONObject duplicate=CourseTools.copy(fresh);duplicate.getJSONArray("lessons").put(CourseTools.copy(duplicate.getJSONArray("lessons").getJSONObject(0)).put("id","generic:42:live:Lecture:0.2:0"));
        try{WebsiteUpdatePolicy.validate(duplicate,Planner.course(s,id));throw new AssertionError("ambiguous migration accepted");}catch(IllegalArgumentException expected){checks++;}
    }
    static void fixedDeletionAndZones()throws Exception{
        JSONObject state=state(),event=FloatingDateCapacityTests.event(StudySettingsTests.TODAY.minusDays(2),480,540,60);event.remove("floatingDurationMinutes");state.getJSONArray("fixedEvents").put(event);
        JSONObject baseline=CourseTools.copy(event);event.put("notes","changed remotely");String before=state.toString();
        try{FixedEventEditing.removeAll(state,baseline);throw new AssertionError("stale deletion accepted");}catch(IllegalArgumentException expected){}check(before.equals(state.toString()),"stale complete deletion atomic");
        FixedEventEditing.removeAll(state,CourseTools.copy(event));check(state.getJSONArray("fixedEvents").length()==0,"complete historical rule deletion");
        ZoneId old=Planner.ZONE;
        try{
            Planner.ZONE=ZoneId.of("America/New_York");
            for(LocalDate day:new LocalDate[]{LocalDate.of(2026,3,8),LocalDate.of(2026,11,1)}){
                check(Planner.at(day,240)-Planner.at(day,60)==180*60,"preserve elapsed-time window semantics across DST");
                JSONObject synthetic=state();JSONObject course=synthetic.getJSONArray("courses").getJSONObject(0);course.put("startDate",Planner.at(day,0)).put("deadline",Planner.at(day.plusDays(1),0));synthetic.getJSONObject("settings").put("availability",StudySettingsTests.windows(0,1200));
                double now=Planner.at(day,90);ImmediateStudy.startLesson(synthetic,course.getString("id"),"B",now);JSONObject pin=ImmediateStudy.valid(synthetic,now);
                check(pin!=null&&pin.getDouble("start")==now&&Planner.end(pin)-now==3600,"immediate start preserves absolute time across DST");
                Planner.replan(synthetic,now+30);check(ImmediateStudy.valid(synthetic,now+30)!=null,"DST pin persists");
            }
        }finally{Planner.ZONE=old;}
    }
    static void macRoundTrip(String file)throws Exception{
        JSONObject state=new JSONObject(Files.readString(Paths.get(file))),task=ImmediateStudy.request(state).getJSONObject("task");double now=task.getDouble("start")-8;
        Planner.replan(state,now);JSONObject retained=ImmediateStudy.valid(state,now);check(retained!=null&&retained.getString("id").equals(task.getString("id")),"Mac to Android retains start");
        int total=0;for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(t))total+=t.getInt("durationMinutes");check(total==120,"Mac roundtrip no duplication");
    }
    public static void main(String[] args)throws Exception{if(args.length>0){macRoundTrip(args[0]);}else{immediate();backups();selective();websites();fixedDeletionAndZones();}System.out.println("Android parity additions: "+checks+" checks passed");}
}
