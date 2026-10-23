package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.*;

/** Read-only explanation of saved settings and the latest planner diagnostics. */
final class ScheduleExplanation {
    static final String DEADLINE_FALLBACK="为守住截止日期，已适当放宽每天的科目混排和学习倍率偏好。";

    static List<String> lines(JSONObject state)throws Exception{
        List<JSONObject> courses=new ArrayList<>();
        for(JSONObject c:Planner.list(state.getJSONArray("courses")))
            if(!c.optBoolean("isArchived")&&c.optBoolean("autoScheduleEnabled",true)&&Planner.remaining(state,c)>0)courses.add(c);
        if(courses.isEmpty())return Collections.singletonList("当前没有需要自动排课的剩余课程。");
        List<String> lines=new ArrayList<>(),adjustments=new ArrayList<>();
        for(int i=0;i<ScheduleHealth.array(state,"androidAdjustments").length();i++)adjustments.add(state.getJSONArray("androidAdjustments").getString(i));
        if(adjustments.contains(DEADLINE_FALLBACK)){
            lines.add("初始混排尝试没能保留原方案已排入的学习量，曾将整份课表退回截止日期优先的排法，随后继续按权重尝试局部优化。仍有集中安排不代表只有集中排课才能按期完成。");
            List<String> other=new ArrayList<>(adjustments);other.removeIf(DEADLINE_FALLBACK::equals);
            if(!other.isEmpty())lines.add("后续调整："+String.join("\n",other));
        }
        else if(!adjustments.isEmpty())lines.add(String.join("\n",adjustments));
        else lines.add("本次没有触发初始混排的截止日期回退，按已保存的权重比较完整课表并尝试优化；日期、空档、整节课与课节顺序始终优先满足。");
        LocalDate earliest=courses.stream().map(c->Planner.day(c.optDouble("deadline"))).min(LocalDate::compareTo).get();
        List<String> names=new ArrayList<>(),boosts=new ArrayList<>();boolean triple=false;
        courses.sort(Comparator.comparing(c->c.optString("name")));
        for(JSONObject c:courses){
            if(Planner.day(c.optDouble("deadline")).equals(earliest))names.add(c.optString("name"));
            double weight=Planner.dailyWeight(c);
            if(weight>1)boosts.add(c.optString("name")+" "+java.math.BigDecimal.valueOf(weight).stripTrailingZeros().toPlainString()+" 倍");
            if(weight==3)triple=true;
        }
        lines.add("较早截止："+String.join("、",names)+"（"+earliest.format(DateTimeFormatter.ofPattern("M月d日"))+"）。截止日期优先的方案会先为它们占用前面的时段。");
        if(boosts.isEmpty())lines.add("当前没有每日加量课程，集中排课并非加量造成。");
        else{
            String suffix=!triple?"当前没有 3 倍课程。":new SchedulePriorities(state.getJSONObject("settings")).usesDefaultOrder()?"默认规则允许能排入的 3 倍课程优先集中学习。":"自定义顺序下不启用默认的 3 倍集中例外。";
            lines.add("每日加量："+String.join("、",boosts)+"，会倾向前面的日期。"+suffix);
        }
        List<String> order=new ArrayList<>();for(int rule:new SchedulePriorities(state.getJSONObject("settings")).order)order.add(SchedulePriorities.TITLES[rule]);
        lines.add("当前偏好顺序："+String.join(" → ",order)+"；同级沿用默认顺序。");
        lines.add("混排同时比较每天的科目数量和同科连续安排；较低级偏好不能抵消更高级偏好的损失。优化保留每门课程已排入的学习量、整节课顺序和 15 分钟休息；搜索有预算上限，不保证全局最优。");
        return lines;
    }
}
