package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.nio.file.*;

public final class WeeklyStudyTextTests {
    static int checks;static final LocalDate MONDAY=WeeklyStudyStatsTests.MONDAY;
    static final JSONArray fixtures=new JSONArray();
    static void fixture(JSONObject state,LocalDate selected)throws Exception{
        fixtures.put(new JSONObject().put("state",CourseTools.copy(state)).put("selectedDay",Planner.at(selected,0))
            .put("expected",WeeklyStudyText.make(WeeklyStudyStats.calculate(state,selected))));
    }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void datesAndSnapshot()throws Exception{
        JSONObject state=PlannerTests.empty(),first=PlannerTests.course("化工\n原理",300,MONDAY,MONDAY.plusDays(14),60).put("type","录播课程").put("color","blue").put("notes",""),second=CourseTools.copy(first).put("id",Planner.id()).put("name","化工 原理");
        first.put("notes","private-notes").put("sourceURL","private-source");state.getJSONArray("courses").put(first).put(second);
        JSONObject planned=WeeklyStudyStatsTests.task(state,first.getString("id"),MONDAY,60);
        JSONObject older=WeeklyStudyStatsTests.task(state,first.getString("id"),MONDAY.minusDays(1),90);
        WeeklyStudyStatsTests.record(state,first.getString("id"),older,40,MONDAY.plusDays(2),MONDAY.plusDays(5));
        JSONObject same=WeeklyStudyStatsTests.task(state,second.getString("id"),MONDAY,30);
        WeeklyStudyStatsTests.record(state,second.getString("id"),same,20,null,MONDAY);
        JSONObject ambiguous=WeeklyStudyStatsTests.task(state,second.getString("id"),MONDAY,30);
        WeeklyStudyStatsTests.record(state,second.getString("id"),ambiguous,10,null,MONDAY.plusDays(1));
        String before=SyncLedger.canonical(state);WeeklyStudyStats stats=WeeklyStudyStats.calculate(state,MONDAY.plusDays(6));String text=WeeklyStudyText.make(stats);
        check(text.startsWith("周学习统计 · 2026-11-02 至 2026-11-08"),"Sunday used the wrong report week");
        check(text.contains("时区：Asia/Shanghai"),"Report omitted date timezone");
        check(text.contains("实际已学：60 分钟")&&text.contains("课表计划：120 分钟"),"Report mixed plan and studied minutes");
        check(text.contains("2026-11-04 周三 · 已学 40 分钟 / 计划 0 分钟"),"Backfill used confirmation or original task date");
        check(text.contains("2026-11-08 周日 · 已学 0 分钟 / 计划 0 分钟"),"Sunday missing from seven-day report");
        check(text.contains("含已确认任务的原计划"),"Report mislabeled historical planned time");
        check(text.contains("化工 原理（同名 1/2）")&&text.contains("化工 原理（同名 2/2）"),"Same-name course rows were merged or indistinguishable");
        check(text.contains("全部历史中另有 10 分钟无法确定学习日期"),"Uncertain history omitted or assigned to this week");
        check(!text.contains("private-")&&!text.contains(first.getString("id")),"Copy leaked notes, links or internal identities");
        check(before.equals(SyncLedger.canonical(state)),"Report changed source records");
        fixture(state,MONDAY.plusDays(6));
        state.put("courses",new JSONArray().put(second).put(first));
        check(text.equals(WeeklyStudyText.make(WeeklyStudyStats.calculate(state,MONDAY))),"Course insertion order changed copied report");
        first.put("name","Changed after preview");planned.put("durationMinutes",999);
        check(text.equals(WeeklyStudyText.make(stats)),"Report snapshot changed while copy was in progress");
    }
    static void emptyDeletedAndLarge()throws Exception{
        String empty=WeeklyStudyText.make(WeeklyStudyStats.calculate(PlannerTests.empty(),MONDAY));
        check(empty.contains("本周暂无计划或已学记录。")&&empty.contains("实际已学：0 分钟"),"Empty report invented progress");
        JSONObject state=PlannerTests.empty();String id=Planner.id();
        for(int i=0;i<3;i++){
            JSONObject task=WeeklyStudyStatsTests.task(state,id,MONDAY,1_000_000_000);
            WeeklyStudyStatsTests.record(state,id,task,1_000_000_000,MONDAY,MONDAY);
        }
        String text=WeeklyStudyText.make(WeeklyStudyStats.calculate(state,MONDAY));
        check(text.contains("实际已学：3000000000 分钟")&&text.contains("课表计划：3000000000 分钟"),"Large totals wrapped or rounded");
        check(text.contains("• 已删除课程 · 已学 3000000000 分钟"),"Deleted course history disappeared");
        fixture(state,MONDAY);fixture(PlannerTests.empty(),MONDAY);
        LocalDate january=LocalDate.of(2027,1,1);String boundary=WeeklyStudyText.make(WeeklyStudyStats.calculate(PlannerTests.empty(),january));
        check(boundary.contains("2026-12-28 至 2027-01-03"),"Year boundary changed report range");
        fixture(PlannerTests.empty(),january);
    }
    public static void main(String[]args)throws Exception{
        datesAndSnapshot();emptyDeletedAndLarge();
        Path file=Paths.get("Android/build/tests/weekly-study-report-parity.json");Files.createDirectories(file.getParent());Files.writeString(file,fixtures.toString());
        System.out.println("Weekly study text: "+checks+" checks passed; shared report fixtures="+fixtures.length());
    }
}
