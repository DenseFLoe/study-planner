package local.studyplanner;

import org.json.*;
import java.util.*;
import static local.studyplanner.AssistantProtocol.*;

/** Historical previews contain display values only, never states or an apply action. */
final class AssistantChangeSummary {
    static JSONObject build(AssistantActions.Proposal p)throws Exception{
        int added=0,modified=0,removed=0;JSONArray notes=new JSONArray();
        for(String key:new String[]{"courses","fixedEvents","tasks","completions"}){
            Map<String,JSONObject> old=AssistantActions.index(p.before,key),next=AssistantActions.index(p.after,key);int a=0,m=0,r=0;
            for(String id:old.keySet())if(!next.containsKey(id))r++;else if(!SyncLedger.canonical(old.get(id)).equals(SyncLedger.canonical(next.get(id))))m++;
            for(String id:next.keySet())if(!old.containsKey(id))a++;added+=a;modified+=m;removed+=r;
            notes.put(AssistantActions.label(key)+"：新增 "+a+"，修改 "+m+"，删除 "+r);
        }
        int risks=0;for(JSONObject row:Planner.list(ScheduleHealth.array(p.after,"androidRisks")))if(row.optLong("unscheduledMinutes")>0)risks++;
        notes.put("排程约束冲突："+ScheduleHealth.array(p.after,"androidConflicts").length()+" 项；有未排入量的截止日期："+risks+" 个。未排入量不代表无解。");
        String stamp=p.snapshot.stamp(p.snapshot.now)+" "+p.snapshot.zone.getId();JSONObject c=AssistantInsights.card("change",p.title,"生成时的修改预览 · 查看全部差异后确认",new JSONArray().put(AssistantInsights.metric("新增",added,"项")).put(AssistantInsights.metric("调整",modified,"项")).put(AssistantInsights.metric("删除",removed,"项")),notes,stamp);
        String[] labels=new String[7];double[][] values=new double[2][7];for(int i=0;i<7;i++)labels[i]=p.snapshot.today.plusDays(i).toString();
        JSONObject[] states={p.before,p.after};for(int s=0;s<2;s++)for(JSONObject task:Planner.list(states[s].getJSONArray("tasks"))){String date=p.snapshot.day(task.getDouble("start")).toString();for(int i=0;i<7;i++)if(labels[i].equals(date))values[s][i]+=task.getInt("durationMinutes");}
        if(!Arrays.equals(values[0],values[1])){c.put("chart",AssistantChart.create("未来7天计划学习量","bar",labels,new String[]{"修改前","方案预览"},values,stamp).json);notes.put("按任务开始日统计计划分钟，含已确认任务的原计划，不是实际已学或剩余量。仅展示今天起7天，完整修改见全部差异。");}
        AssistantInsights.validate(c);return c;
    }
}
