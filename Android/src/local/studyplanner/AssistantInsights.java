package local.studyplanner;

import org.json.*;
import java.util.*;
import static local.studyplanner.AssistantProtocol.*;

/** Local facts only; no executable state or identifiers are retained in a display card. */
final class AssistantInsights {
    static final class Query {
        final String name;final JSONObject input,evidence;
        Query(String name,JSONObject input,JSONObject evidence){this.name=name;this.input=input;this.evidence=evidence;}
    }
    static double n(JSONObject data,String key)throws Exception{return AssistantChart.number(data.get(key),true);}
    static JSONObject metric(String title,double value,String unit)throws Exception{return object("title",title,"value",value,"unit",unit);}
    static JSONObject metric(String title,double value)throws Exception{return metric(title,value,"分钟");}
    static JSONObject card(String kind,String title,String subtitle,JSONArray metrics,JSONArray notes,String stamp)throws Exception{return object("kind",kind,"title",title,"subtitle",subtitle,"metrics",metrics,"notes",notes,"capturedAt",stamp);}
    static JSONArray notes(String...text){return new JSONArray(Arrays.asList(text));}
    static JSONArray build(List<Query> queries,String answer){
        JSONArray cards=build(queries);List<AssistantChart> existing=AssistantChart.inAnswer(answer);
        for(JSONObject card:Planner.list(cards))if(card.has("chart"))try{AssistantChart chart=new AssistantChart(card.getJSONObject("chart"));for(AssistantChart other:existing)if(chart.sameData(other)){card.remove("chart");break;}}catch(Exception ignored){}
        return cards;
    }
    static JSONArray build(List<Query> queries){
        Map<String,JSONObject> cards=new LinkedHashMap<>();
        for(Query q:queries.subList(0,Math.min(24,queries.size())))try{
            JSONObject d=q.evidence.getJSONObject("data"),c;String stamp=q.evidence.getString("captured_at")+" "+q.evidence.getString("time_zone"),key;
            switch(q.name){
            case "inspect_course":{
                double total=n(d,"total_minutes"),done=n(d,"completed_minutes"),remaining=n(d,"remaining_minutes");String name=d.getString("untrusted_name");key="course:"+d.getString("course_id");
                c=card("course",name.isEmpty()?"课程进度":name,"课程进度 · 截止 "+d.getString("deadline"),new JSONArray().put(metric("有效完成",done)).put(metric("剩余学习量",remaining)).put(metric("课程总量",total)),notes("按有效课程进度统计，与实际学习用时不同。"),stamp);
                if(total>0)c.put("progress",Math.min(1,done/total));break;
            }
            case "inspect_progress":{
                JSONArray days=d.getJSONArray("days");if(days.length()<1||days.length()>31)continue;String[] labels=new String[days.length()];double[][] values=new double[2][days.length()];double actual=0,planned=0;
                for(int i=0;i<days.length();i++){JSONObject day=days.getJSONObject(i);labels[i]=day.getString("date");actual+=values[0][i]=n(day,"actual_minutes");planned+=values[1][i]=n(day,"planned_by_start_day_minutes");}
                String scope=q.input.getString("course"),name=scope.isEmpty()?"全部课程":"指定课程";for(Query other:queries)if(!scope.isEmpty()&&other.name.equals("inspect_course")&&scope.equals(other.input.optString("course"))&&other.evidence.optJSONObject("data")!=null)name=other.evidence.getJSONObject("data").optString("untrusted_name",name);
                String range=labels[0]+" 至 "+labels[labels.length-1];key="statistics:"+scope+":"+range;
                c=card("statistics","学习统计",name+" · "+range,new JSONArray().put(metric("实际学习",actual)).put(metric("计划学习",planned)).put(metric("日期不明",n(d,"unknown_date_minutes"))),notes("实际学习用时不等于有效课程进度；计划量按任务开始日统计，跨日任务未拆分。","日期不明为所选课程全部无日期记录，不计入所选日期范围的合计与图表。"),stamp);
                c.put("chart",AssistantChart.create("每日实际与计划",days.length()>1?"line":"bar",labels,new String[]{"实际学习","计划学习"},values,stamp).json);break;
            }
            case "inspect_schedule":case "inspect_time_conflicts":{
                JSONObject check=q.name.equals("inspect_schedule")?d.getJSONObject("time_check"):d;String date=check.getString("date");key="schedule:"+date;double invalid=n(check,"invalid_entry_count"),excluded=n(check,"excluded_confirmed_task_count");
                JSONArray notes=notes("固定时段按重叠对数统计；浮动窗口不等于实际占用，容量不足与时间重叠分开核对。","已排除 "+AssistantChart.format(excluded)+" 条已确认或历史任务，其原计划不代表实际学习时段。");
                if(invalid>0)notes.put("有 "+AssistantChart.format(invalid)+" 条无效数据未能核实，不能据此判断没有冲突。");if(check.optString("joint_floating_status").equals("not_verified"))notes.put("多个浮动窗口能否同时排入：尚未核实。");if(check.opt("next_offset") instanceof String)notes.put("数量覆盖当天全部结果；冲突明细尚有未读取的分页。");
                c=card("schedule","日程核对",date+" · 已保存的安排",new JSONArray().put(metric("固定时段重叠",n(check,"fixed_overlap_count"),"对")).put(metric("浮动窗口",n(check,"floating_window_count"),"项")).put(metric("已证实容量不足",n(check,"proven_floating_deficit_count"),"项")),notes,stamp);break;
            }
            case "inspect_conflicts":{
                key="conflicts";double total=n(d,"total");Map<Integer,JSONArray> pages=new TreeMap<>();for(Query other:queries)if(other.name.equals(q.name)&&other.evidence.optJSONObject("data")!=null){JSONObject payload=other.evidence.getJSONObject("data");JSONArray rows=payload.optJSONArray("rows");if(rows!=null)pages.put(Integer.parseInt(other.input.optString("offset","0")),rows);}
                // Key by absolute row index as well as page offset: overlapping reads cannot double count.
                Map<Integer,JSONObject> rows=new TreeMap<>();for(Map.Entry<Integer,JSONArray> page:pages.entrySet())for(int i=0;i<page.getValue().length();i++)rows.put(page.getKey()+i,page.getValue().getJSONObject(i));
                List<JSONObject> constraints=new ArrayList<>();int risks=0;for(JSONObject row:rows.values())if(row.optString("kind").equals("constraint"))constraints.add(row);else if(row.optString("kind").equals("unbooked"))risks++;
                boolean complete=rows.size()==total&&(rows.isEmpty()||rows.keySet().iterator().next()==0&&Collections.max(rows.keySet())==rows.size()-1);
                c=card("conflicts","排程分析","当前已保存课表 · 容量与规则",new JSONArray().put(metric("提醒总数",total,"项")).put(metric("已读约束冲突",constraints.size(),"项")).put(metric("已读未排入截止日期",risks,"个")),notes(complete?"已读取全部提醒。":"仅读取 "+rows.size()+"/"+AssistantChart.format(total)+" 项提醒，分类数量仅覆盖已读部分。","未排入量不代表客观缺口或无解；此评估不判断实际时段是否重叠。","图表最多展示12个已读约束窗口；窗口可能相互重叠，不可相加。休息与连续时段约束须结合文字分析。"),stamp);
                if(!constraints.isEmpty()){int count=Math.min(12,constraints.size());String[] labels=new String[count];double[][] values=new double[2][count];for(int i=0;i<count;i++){JSONObject row=constraints.get(i);labels[i]=(i+1)+" · "+row.getString("deadline");values[0][i]=n(row,"required_minutes");values[1][i]=n(row,"available_minutes");}c.put("chart",AssistantChart.create("已读约束窗口的需求与可用量","bar",labels,new String[]{"所需时间","可用时间"},values,stamp).json);}break;
            }
            case "inspect_rules":{
                key="rules";JSONArray order=d.getJSONArray("priority_order");List<String> names=new ArrayList<>();for(int i=0;i<order.length();i++)names.add(order.getString(i));
                c=card("rules","排程规则","当前保存的设置",new JSONArray().put(metric("最小学习块",n(d,"minimum_block_minutes"))).put(metric("休息间隔",n(d,"break_minutes"))),notes("优先顺序："+String.join(" → ",names),"均摊和每日倍率是偏好，不是每日硬上限；最终余量可短于最小学习块。"),stamp);break;
            }
            default:continue;
            }validate(c);cards.put(key,c);
        }catch(Exception ignored){/* A failed/partial query must not fabricate zeros or discard the answer. */}
        return new JSONArray(cards.values());
    }
    static void validate(JSONObject c)throws Exception{
        if(!Arrays.asList("course","statistics","schedule","conflicts","rules","change").contains(c.getString("kind")))throw invalid();
        AssistantChart.shortText(c,"title",300);AssistantChart.shortText(c,"subtitle",300);AssistantChart.shortText(c,"capturedAt",100);
        JSONArray metrics=c.getJSONArray("metrics"),notes=c.getJSONArray("notes");if(metrics.length()<1||metrics.length()>4||notes.length()>10)throw invalid();
        for(JSONObject m:Planner.list(metrics)){AssistantChart.shortText(m,"title",80);n(m,"value");AssistantChart.shortText(m,"unit",20);}
        for(int i=0;i<notes.length();i++)if(!(notes.get(i) instanceof String)||notes.getString(i).length()>1000)throw invalid();
        if(c.has("progress")&&n(c,"progress")>1)throw invalid();if(c.has("chart"))new AssistantChart(c.getJSONObject("chart"));
        limit(c.toString(),40000);
    }
    static String plainText(JSONObject c)throws Exception{validate(c);StringBuilder s=new StringBuilder(c.getString("title")+"\n"+c.getString("subtitle"));for(JSONObject m:Planner.list(c.getJSONArray("metrics")))s.append('\n').append(m.getString("title")).append("：").append(AssistantChart.format(n(m,"value"))).append(' ').append(m.getString("unit"));for(int i=0;i<c.getJSONArray("notes").length();i++)s.append('\n').append(c.getJSONArray("notes").getString(i));if(c.has("chart")){AssistantChart chart=new AssistantChart(c.getJSONObject("chart"));s.append('\n').append(chart.title).append('\n').append(chart.table());}return s+"\n生成时的数据快照 · "+c.getString("capturedAt");}
    static String entryText(JSONObject entry)throws Exception{if(entry.optString("role").equals("你"))return entry.getString("text");StringBuilder text=new StringBuilder(AssistantChart.plainText(entry.getString("text")));JSONArray cards=entry.optJSONArray("insights");if(cards!=null)for(JSONObject c:Planner.list(cards))text.append("\n\n").append(plainText(c));JSONObject change=entry.optJSONObject("changeSummary");if(change!=null)text.append("\n\n").append(plainText(change));return text.toString();}
}
