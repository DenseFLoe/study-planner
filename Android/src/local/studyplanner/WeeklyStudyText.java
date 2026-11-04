package local.studyplanner;

import java.util.*;

/** Read-only weekly report from a detached statistics snapshot. */
final class WeeklyStudyText {
    private static String name(WeeklyStudyStats.Course course){
        String text=course.name.replaceAll("[\\p{javaWhitespace}\\p{Z}]+"," ").trim();
        return text.isEmpty()?"未命名课程":text;
    }
    static String make(WeeklyStudyStats stats){
        List<String> lines=new ArrayList<>();
        lines.add("周学习统计 · "+stats.monday+" 至 "+stats.monday.plusDays(6));
        lines.add("时区："+Planner.ZONE.getId());
        lines.add("实际已学："+stats.studiedMinutes+" 分钟");
        lines.add("课表计划："+stats.plannedMinutes+" 分钟");
        lines.add("实际已学按实际学习日期归属；课表计划含已确认任务的原计划，随重排变化。");
        lines.add("");lines.add("每日明细");
        for(int day=0;day<7;day++)lines.add(stats.monday.plusDays(day)+" 周"+"一二三四五六日".charAt(day)+
            " · 已学 "+stats.studied(day)+" 分钟 / 计划 "+stats.planned(day)+" 分钟");
        List<WeeklyStudyStats.Course> courses=new ArrayList<>(stats.courses);
        courses.sort(Comparator.comparing(WeeklyStudyText::name).thenComparing(course->course.id));
        Map<String,Integer> counts=new HashMap<>(),ordinal=new HashMap<>();
        for(WeeklyStudyStats.Course course:courses)counts.merge(name(course),1,Integer::sum);
        if(courses.isEmpty()){lines.add("");lines.add("本周暂无计划或已学记录。");}
        else{
            lines.add("");lines.add("课程汇总");
            for(WeeklyStudyStats.Course course:courses){
                String title=name(course);if(counts.get(title)>1)title+="（同名 "+ordinal.merge(title,1,Integer::sum)+"/"+counts.get(title)+"）";
                long planned=0,studied=0;for(int day=0;day<7;day++){planned+=course.planned(day);studied+=course.studied(day);}
                lines.add("• "+title+" · 已学 "+studied+" 分钟 / 计划 "+planned+" 分钟");
            }
        }
        if(stats.undatedMinutes>0){lines.add("");lines.add("全部历史中另有 "+stats.undatedMinutes+" 分钟无法确定学习日期，未计入本周实际已学；原进度与记录均保留。");}
        return String.join("\n",lines);
    }
}
