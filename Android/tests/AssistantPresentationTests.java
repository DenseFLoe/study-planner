package local.studyplanner;

import org.json.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import static local.studyplanner.AssistantProtocol.*;
import static local.studyplanner.AssistantTests.*;

/** Synthetic local queries, mock transport and isolated history; no API credentials. */
public final class AssistantPresentationTests {
    static List<AssistantInsights.Query> queries=new ArrayList<>();
    static JSONObject add(String name,JSONObject in,Snapshot shot)throws Exception{JSONObject e=AssistantTools.execute(name,in,shot,new ArrayList<>());queries.add(new AssistantInsights.Query(name,in,e));return e;}
    static void cards()throws Exception{
        JSONObject state=fixture();String cid=state.getJSONArray("courses").getJSONObject(0).getString("id");Snapshot shot=shot(state);String before=state.toString();
        JSONObject course=add("inspect_course",input("course",cid,"offset","0"),shot);add("inspect_course",input("course",cid,"offset","0"),shot);
        JSONObject progress=add("inspect_progress",input("course",cid,"start_date",DAY.toString(),"end_date",DAY.plusDays(6).toString()),shot);
        add("inspect_schedule",input("date",DAY.toString(),"offset","0"),shot);add("inspect_time_conflicts",input("date",DAY.toString(),"offset","0"),shot);add("inspect_rules",input(),shot);
        JSONArray cards=AssistantInsights.build(queries);check(cards.length()==4,"Duplicate course/day cards");check(cards.getJSONObject(0).getDouble("progress")==0,"False initial progress");check(cards.getJSONObject(1).getString("subtitle").contains("合成数学"),"Statistics lost course scope");
        AssistantChart chart=new AssistantChart(cards.getJSONObject(1).getJSONObject("chart"));check(chart.labels.length==7&&chart.values[1][0]==progress.getJSONObject("data").getJSONArray("days").getJSONObject(0).getInt("planned_by_start_day_minutes"),"Statistics changed plan values");
        check(!AssistantInsights.build(queries,"```study-chart\n"+chart.json+"\n```").getJSONObject(1).has("chart"),"Repeated answer chart not suppressed");
        check(cards.getJSONObject(1).getJSONArray("notes").toString().contains("日期不明"),"Unknown date scope lost");check(state.toString().equals(before),"Cards changed schedule");
        JSONObject d=course.getJSONObject("data");d.put("total_minutes",0);check(!AssistantInsights.build(Collections.singletonList(queries.get(0))).getJSONObject(0).has("progress"),"Zero total invented progress");d.put("completed_minutes",true);check(AssistantInsights.build(Collections.singletonList(queries.get(0))).length()==0,"Boolean presented as number");
        List<AssistantInsights.Query> pages=new ArrayList<>();JSONArray rows=new JSONArray();for(int i=0;i<20;i++)rows.put(input("kind","constraint","deadline",DAY.toString(),"required_minutes",60+i,"available_minutes",50));
        JSONObject e=AssistantTools.evidence("E1","合成",input("rows",rows,"total",22,"next_offset","20"),shot);pages.add(new AssistantInsights.Query("inspect_conflicts",input("offset","0"),e));pages.add(pages.get(0));JSONObject card=AssistantInsights.build(pages).getJSONObject(0);check(card.getJSONArray("metrics").getJSONObject(1).getInt("value")==20&&card.getJSONArray("notes").toString().contains("20/22"),"Partial/repeated page totals misleading");check(new AssistantChart(card.getJSONObject("chart")).labels.length==12,"Conflict chart unbounded");
        pages.add(new AssistantInsights.Query("inspect_conflicts",input("offset","19"),AssistantTools.evidence("E2","合成",input("total",22,"rows",new JSONArray().put(rows.get(19)).put(input("kind","unbooked")).put(input("kind","unbooked"))),shot)));
        card=AssistantInsights.build(pages).getJSONObject(0);check(card.getJSONArray("metrics").getJSONObject(1).getInt("value")==20&&card.getJSONArray("metrics").getJSONObject(2).getInt("value")==2&&card.getJSONArray("notes").getString(0).equals("已读取全部提醒。"),"Overlapping pages double counted");
    }
    static String request(Object value)throws Exception{return input("title","合成图表","kind","bar","unit","分钟","labels",new JSONArray().put("完成"),"series",new JSONArray().put(input("name","有效进度","values",new JSONArray().put(value)))).toString();}
    static void charts()throws Exception{
        List<JSONObject> evidence=Collections.singletonList(AssistantTools.evidence("E1","合成",input("done",30,"boolean",true,"string","30","values",new JSONArray().put(12)),shot(fixture())));String stamp="2026-11-07 07:00 Asia/Singapore";
        check(AssistantChart.resolve(request("E1.data.done"),evidence,stamp).values[0][0]==30,"Evidence resolution failed");
        for(Object value:new Object[]{30,"30","E1.data.boolean","E1.data.string","E2.data.done","E1.data.done+1","E1.data.values.00","E1.category"})rejects(()->AssistantChart.resolve(request(value),evidence,stamp),"Untrusted chart value accepted");
        String good="```study-chart\n"+request("E1.data.done")+"\n```";String text=AssistantChart.materialize("前文\n"+good+"\n后文",evidence,stamp);check(text.contains("前文")&&text.contains("后文")&&AssistantChart.plainText(text).contains("30")&&!AssistantChart.plainText(text).contains("E1.data"),"Readable chart copy failed");
        check(AssistantChart.materialize(good+"\n"+good+"\n"+good+"\n"+good,evidence,stamp).contains(AssistantChart.UNAVAILABLE),"Chart limit missing");check(AssistantChart.materialize("```study-chart\n"+request(30),evidence,stamp).equals(AssistantChart.UNAVAILABLE),"Unclosed chart rendered");
        String opaque="```text\n"+good+"\n```";check(AssistantChart.materialize(opaque,evidence,stamp).equals(opaque),"Nested ordinary code resolved");
        AssistantChart zero=AssistantChart.create("空","bar",new String[]{"零"},new String[]{"实际"},new double[][]{{0}},stamp);check(!zero.supportsDonut(),"Zero donut allowed");JSONObject invalid=CourseTools.copy(zero.json).put("kind","donut");rejects(()->new AssistantChart(invalid),"Invalid saved donut accepted");
        rejects(()->AssistantChart.create("重复","bar",new String[]{"A","A"},new String[]{"值"},new double[][]{{1,2}},stamp),"Duplicate labels accepted");check(AssistantChart.axis("2026-11-07").equals("11/7"),"Compact axis changed");
    }
    static void previews()throws Exception{
        JSONObject state=fixture();String cid=state.getJSONArray("courses").getJSONObject(0).getString("id");String before=state.toString();Snapshot shot=shot(state);
        AssistantActions.Proposal rename=AssistantActions.prepare("preview_edit_course",input("course",cid,"field","name","value","新名称"),shot);JSONObject summary=AssistantChangeSummary.build(rename);check(!summary.has("chart"),"Rename made redundant workload graph");check(summary.getJSONArray("metrics").getJSONObject(1).getInt("value")==1,"Rename count wrong");
        JSONObject after=CourseTools.copy(state);after.put("tasks",new JSONArray());JSONObject moved=CourseTools.copy(state.getJSONArray("tasks").getJSONObject(0));moved.put("start",Planner.at(DAY.plusDays(1),600));moved.put("end",Planner.at(DAY.plusDays(1),660));after.getJSONArray("tasks").put(moved);
        JSONObject display=AssistantChangeSummary.build(new AssistantActions.Proposal("合成移动",after,shot));AssistantChart chart=new AssistantChart(display.getJSONObject("chart"));check(chart.labels.length==7&&chart.values[1][1]==moved.getInt("durationMinutes")&&chart.values[1][0]==0,"Workload date/count wrong");check(!display.toString().contains(cid)&&!display.has("before")&&!display.has("after"),"Preview persisted state/identifier");check(before.equals(state.toString()),"Preview display changed state");
    }
    static void historyAndRunner()throws Exception{
        Contract contract=new Contract(new JSONObject(new String(Files.readAllBytes(Paths.get("Android/build/assets/assistant-contract.json")),java.nio.charset.StandardCharsets.UTF_8)));Path dir=temporary("assistant-presentation-");
        AssistantHistory history=new AssistantHistory(dir.toFile(),contract);JSONObject state=fixture();String cid=state.getJSONArray("courses").getJSONObject(0).getString("id");AtomicInteger calls=new AtomicInteger();Store store=new Store(state);
        AssistantSession session=new AssistantSession(history,store,(r,k,t)->{if(calls.getAndIncrement()==0)return response(new JSONArray().put(input("id","read","type","function","function",input("name","inspect_course","arguments",input("course",cid,"offset","0").toString()))),"");return response(new JSONArray(),"已整理课程进度。\n```study-chart\n"+request("E1.data.completed_minutes")+"\n```");},()->{});
        try{
            session.queue.submit(()->{}).get();session.configure(configuration("openai").json(),"fixture-auth-value",false,null);session.queue.submit(()->{}).get();CountDownLatch done=new CountDownLatch(1);session.attach(s->{if(s.approval!=null)session.decide(true);if(!s.busy)try{for(JSONObject e:Planner.list(AssistantHistory.selected(s.workspace).getJSONArray("entries")))if(e.optString("role").equals("助手"))done.countDown();}catch(Exception ignored){}});session.send("合成进度查询");check(done.await(10,TimeUnit.SECONDS),"Runner did not persist response");session.queue.submit(()->{}).get();
            JSONObject workspace=history.load(),entry=AssistantHistory.selected(workspace).getJSONArray("entries").getJSONObject(1);check(entry.getJSONArray("insights").length()==1,"Runner lost generated cards");check(AssistantInsights.entryText(entry).contains("有效完成"),"Copy lost metric");String context=AssistantHistory.messages(workspace,"继续").toString();check(context.contains("快照")&&!context.contains("study-chart")&&!context.contains("E1.data"),"Historical charts replayed evidence paths");check(store.saves==0,"Read-only charts saved planner");
            JSONObject broken=CourseTools.copy(workspace);AssistantHistory.selected(broken).getJSONArray("entries").getJSONObject(1).getJSONArray("insights").getJSONObject(0).put("progress",2);rejects(()->history.save(broken,Collections.emptySet()),"Invalid history card accepted");check(history.load().toString().equals(workspace.toString()),"Rejected card damaged saved history");
            JSONObject old=AssistantHistory.empty();history.validate(old,Collections.emptySet());check(old.has("conversations"),"Legacy empty history failed");
        }finally{session.queue.shutdownNow();session.network.shutdownNow();try(java.util.stream.Stream<Path> files=Files.walk(dir)){files.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.deleteIfExists(p);}catch(Exception ignored){}});}}
    }
    public static void main(String[] args)throws Exception{cards();charts();previews();historyAndRunner();System.out.println("PASS "+checks+" assistant presentation checks: evidence, query scope, paging, previews, history and mock session; no real API");}
}
