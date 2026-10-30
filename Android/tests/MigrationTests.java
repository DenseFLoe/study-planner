package local.studyplanner;

import org.json.*;
import java.time.*;
import java.util.*;
import java.nio.file.*;
import java.io.*;

public final class MigrationTests {
    static int checks;static final LocalDate DAY=LocalDate.of(2026,10,20);static final double NOW=Planner.at(DAY,600);
    static void check(boolean v,String message){checks++;if(!v)throw new AssertionError(message);}
    static FixedEventTextParser.Draft draft(String text)throws Exception {FixedEventTextParser.Result r=FixedEventTextParser.parse(text,NOW);check(r.drafts.size()==1,text+" "+r.messages);return r.drafts.get(0);}
    static void recognition()throws Exception {
        for(String s:new String[]{"明天下午三点到五点开会","明天下午 3 点到 5 点开会","明天下午3:00-5:00开会"}){JSONObject e=draft(s).event;check(e.getInt("startMinute")==900&&e.getInt("endMinute")==1020&&e.getString("title").equals("开会"),s);}
        JSONObject e=draft("按照学院安排，明天晚上18:00召开示例学院2027届就业及考研动员大会，会议地点另行通知 @所有人").event;
        check(Planner.day(e.getDouble("startDate")).equals(DAY.plusDays(1)),"Graduation year changed the event date");check(e.getString("title").equals("示例学院2027届就业及考研动员大会"),"Notice title lost");check(e.getInt("endMinute")==1140,"Missing end default");
        e=draft("下周三下午两点半至四点开会").event;check(Planner.day(e.getDouble("startDate")).equals(LocalDate.of(2026,10,28))&&e.getInt("startMinute")==870&&e.getInt("endMinute")==960,"Next week boundary");
        for(String s:new String[]{"2026年11月2日 14:00-16:00 讲座","2026-11-02 14:00-16:00 讲座"})check(Planner.day(draft(s).event.getDouble("startDate")).equals(LocalDate.of(2026,11,2)),s);
        check(Planner.day(draft("1月2日14:00-16:00讲座").event.getDouble("startDate")).equals(LocalDate.of(2027,1,2)),"Inferred year");
        check(Planner.day(FixedEventTextParser.parse("明天18:00开会",Planner.at(LocalDate.of(2026,12,31),1380)).drafts.get(0).event.getDouble("startDate")).equals(LocalDate.of(2027,1,1)),"Relative cross-year");
        check(Planner.day(FixedEventTextParser.parse("下周一9:00-10:00开会",Planner.at(LocalDate.of(2026,10,25),600)).drafts.get(0).event.getDouble("startDate")).equals(LocalDate.of(2026,10,26)),"Sunday Monday boundary");
        e=draft("从2026年10月20日到2026年12月31日，每周一、三下午3点到5点上课").event;check(e.getJSONArray("weekdays").toString().equals("[2,4]")&&Planner.day(e.getDouble("endDate")).equals(LocalDate.of(2026,12,31)),"Repeat interval");
        for(String s:new String[]{"每周一至五9:00-10:00早读","工作日9:00-10:00早读"})check(draft(s).event.getJSONArray("weekdays").toString().equals("[2,3,4,5,6]"),s);
        check(draft("每周五到周一9:00-10:00早读").event.getJSONArray("weekdays").toString().equals("[1,2,6,7]"),"Cyclic weekdays");check(draft("每周一、周三9:00-10:00早读").event.getJSONArray("weekdays").toString().equals("[2,4]"),"Repeated weekday prefix");
        check(draft("周末9:00-10:00早读").event.getJSONArray("weekdays").toString().equals("[1,7]"),"Weekend");check(draft("每天19:00-20:00锻炼").warnings.stream().anyMatch(w->w.contains("16 周")),"Default recurrence warning");
        e=draft("每周三19:00-20:00上课，截止2026年12月31日").event;check(Planner.day(e.getDouble("startDate")).equals(DAY.plusDays(1)),"End-only repeat start");check(Planner.day(draft("每周三9:00-10:00上课，持续4周").event.getDouble("endDate")).equals(LocalDate.of(2026,11,17)),"Repeat duration");
        for(String s:new String[]{"明天18:00开会，持续90分钟","明天18:00开会，时长1小时30分钟","明天18:00开会，持续一个半小时","明天18:00开会，持续一小时半"})check(draft(s).event.getInt("endMinute")==1170,s);
        check(draft("明天下午三点一刻到五点三刻开会").event.getInt("startMinute")==915,"Quarter hour");
        for(String s:new String[]{"18:00开会","2026年2月30日18:00开会","明天25:00开会","明天上午18:00开会","明天18:60开会","明天23:00到次日1:00值班","明天18:00集合19:00开会","明天18:00开会后天19:00上课","明天安排待定","2026年10月21日周四18:00开会","明天18:00会议取消","明天14:00到18:00之间任选1小时锻炼"}){FixedEventTextParser.Result r=FixedEventTextParser.parse(s,NOW);check(r.drafts.isEmpty()&&!r.messages.isEmpty(),"Ambiguous text accepted: "+s);}
        check(draft("2026年10月21日周三18:00开会").event.getInt("startMinute")==1080,"Consistent weekday rejected");
        check(FixedEventTextParser.parse("明天9:00-10:00开会\n后天14:00-16:00上课",NOW).drafts.size()==2,"Multiple notices");check(FixedEventTextParser.parse("明天\n9:00-10:00开会\n14:00-16:00上课",NOW).drafts.size()==2,"Shared date header");
        e=draft("明天１８：００至１９：００开会").event;check(e.getInt("startMinute")==1080&&e.getString("notes").equals("明天１８：００至１９：００开会"),"Full width/raw notes");check(draft("明天18:00召开例会，地点待定").event.getInt("startMinute")==1080,"Uncertain location discarded known date");
        check(FixedEventTextParser.parse(String.join("",Collections.nCopies(15001,"通知")),NOW).messages.get(0).contains("30000"),"Input limit");StringBuilder many=new StringBuilder();for(int i=0;i<21;i++)many.append("明天9:00-10:00事项").append(i).append('\n');check(FixedEventTextParser.parse(many.toString(),NOW).drafts.size()==20,"Candidate limit");
    }
    static void savedPlan()throws Exception {
        JSONObject s=PlannerTests.empty(),c=PlannerTests.course("实际课表",120,DAY,DAY,60);s.getJSONArray("courses").put(c);s.getJSONObject("settings").getJSONArray("availability").put(new JSONObject().put("id",Planner.id()).put("weekday",3).put("startMinute",480).put("endMinute",900));
        JSONObject task=Planner.task(c.getString("id"),Planner.at(DAY,720),60);s.getJSONArray("tasks").put(task);String tasks=s.getJSONArray("tasks").toString();Planner.refreshDiagnostics(s,NOW);
        check(tasks.equals(s.getJSONArray("tasks").toString()),"Refresh replaced saved tasks");check(s.getJSONObject("androidMissing").getInt(c.getString("id"))==60,"Alternative draft erased real missing work");check(s.getJSONArray("androidRisks").getJSONObject(0).getInt("unscheduledMinutes")==60,"Missing saved risk");
        int planned=0;for(JSONObject d:Planner.list(s.getJSONArray("androidDayPlans")))planned+=d.getInt("plannedMinutes");check(planned==60,"Daily count came from alternative draft");
        Planner.confirm(s,task.getString("id"),60,NOW);Planner.refreshDiagnostics(s,NOW);check(s.getJSONObject("androidMissing").getInt(c.getString("id"))==60,"Early full confirmation erased missing work");
        s.getJSONArray("tasks").put(Planner.task(c.getString("id"),Planner.at(DAY,780),60));Planner.refreshDiagnostics(s,NOW);check(s.getJSONArray("androidRisks").length()==0&&s.getJSONArray("androidConflicts").length()==0,"Complete saved plan inherited a draft risk");
    }
    static void editor()throws Exception {
        JSONObject s=LessonDeletionTests.fixture(),original=s.getJSONArray("courses").getJSONObject(0),edited=CourseTools.copy(original);JSONArray rows=new JSONArray();for(JSONObject l:Planner.list(edited.getJSONArray("manualLessons")))if(!l.getString("id").equals("a"))rows.put(l);Planner.updateManualLessons(edited,rows);CourseTools.updateCourse(s,edited,LessonDeletionTests.NOW);
        JSONObject saved=Planner.course(s,edited.getString("id"));check(saved.getInt("initialCompletedMinutes")==10,"Editor moved removed baseline into retained lessons");check(saved.getJSONArray("deletedLessonIDs").toString().contains("a"),"Editor deletion tombstone missing");check(s.getJSONArray("tasks").length()==2&&s.getJSONArray("completions").length()==2,"Retained editor progress lost");
        JSONObject next=CourseTools.copy(saved);rows=new JSONArray().put(next.getJSONArray("manualLessons").getJSONObject(0));Planner.updateManualLessons(next,rows);String before=s.toString();s.getJSONArray("tasks").getJSONObject(0).remove("lessonID");before=s.toString();try{CourseTools.updateCourse(s,next,LessonDeletionTests.NOW);throw new AssertionError("Ambiguous deletion allowed");}catch(IllegalArgumentException expected){check(before.equals(s.toString()),"Rejected edit changed data");}
    }
    static void wire()throws Exception {
        Path fixture=Paths.get("Android/build/tests/mac-compressed-preview.json");if(!Files.exists(fixture))fixture=Paths.get("Android/tests/fixtures/mac-compressed-preview.json");
        JSONObject root=new JSONObject(new String(Files.readAllBytes(fixture),java.nio.charset.StandardCharsets.UTF_8)),s=root.getJSONObject("state"),p=root.getJSONObject("preview");double now=p.getDouble("capturedAt");
        check(CompressedPreview.current(p,s,now),"Swift/Java input signatures disagree");JSONObject copy=CourseTools.copy(s);copy.getJSONArray("tasks").put(Planner.task(copy.getJSONArray("courses").getJSONObject(0).getString("id"),now+60,1));check(CompressedPreview.current(p,copy,now),"Draft change invalidated independent result");
        for(String kind:new String[]{"courses","fixedEvents","completions","settings"}){copy=CourseTools.copy(s);if(kind.equals("settings"))copy.getJSONObject(kind).put("minimumScheduleUnit",1);else if(kind.equals("courses"))copy.getJSONArray(kind).getJSONObject(0).put("totalMinutes",1200);else if(kind.equals("fixedEvents"))copy.getJSONArray(kind).getJSONObject(0).put("title","变更");else copy.getJSONArray(kind).getJSONObject(0).put("minutes",2);check(!CompressedPreview.current(p,copy,now),kind+" change did not mark stale");}
        check(!CompressedPreview.current(p,s,now+86400),"Next-day result not stale");s.getJSONObject("settings").put(CompressedPreview.FIELD,p);SyncLedger ledger=new SyncLedger();ledger.capture(s);check(CompressedPreview.current(ledger.materialize().getJSONObject("settings").getJSONObject(CompressedPreview.FIELD),s,now),"Ledger lost preview");
        try(InputStream in=new ByteArrayInputStream(Base64.getDecoder().decode(root.getString("archiveGzip")))){CloudSnapshot cloud=CloudSnapshot.read(in);JSONObject restored=cloud.ledger.materialize();check(CompressedPreview.current(restored.getJSONObject("settings").getJSONObject(CompressedPreview.FIELD),restored,now),"Swift gzip/Java merge lost preview");}
        JSONObject malicious=CourseTools.copy(p);malicious.getJSONArray("rows").getJSONObject(0).put("end",0);try{CompressedPreview.validate(malicious);throw new AssertionError("Invalid preview accepted");}catch(IllegalArgumentException expected){checks++;}
    }
    public static void main(String[] args)throws Exception {recognition();savedPlan();editor();wire();System.out.println("PASS "+checks+" migration checks: recognition, saved diagnostics, editor progress, cloud preview compatibility and staleness");}
}
