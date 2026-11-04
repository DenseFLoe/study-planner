package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class ProgressIntegrityTests {
    static int checks;
    static final double NOW=800_000_000;
    interface Action { void run()throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{
        boolean rejected=false;try{action.run();}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,message);
    }
    static JSONObject fixture(int baseline,int... minutes)throws Exception{
        JSONObject state=SyncExchangeTests.fixture(NOW);state.put("tasks",new JSONArray()).put("completions",new JSONArray());
        JSONObject course=state.getJSONArray("courses").getJSONObject(0);course.put("initialCompletedMinutes",baseline);
        for(int amount:minutes){String task=Planner.id();state.getJSONArray("completions").put(new JSONObject().put("id",Planner.stableID("completion|"+task))
            .put("taskID",task).put("courseID",course.getString("id")).put("minutes",amount).put("recordedAt",NOW));}return state;
    }
    static SyncLedger wire(JSONObject state)throws Exception{
        SyncLedger ledger=new SyncLedger();ledger.capture(SyncExchangeTests.initial());
        for(String kind:new String[]{"courses","tasks","completions"})for(JSONObject value:Planner.list(state.getJSONArray(kind))){
            JSONObject row=new JSONObject().put("kind",kind).put("id",value.getString("id")).put("deleted",false).put("version",1).put("sequence",1).put("device","progress-fixture")
                .put("payload",Base64.getEncoder().encodeToString(value.toString().getBytes(StandardCharsets.UTF_8)));
            ledger.records().put(SyncLedger.key(row),row);
        }return ledger;
    }
    static void archive(SyncLedger ledger)throws Exception{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
    }
    static void invalidTotals()throws Exception{
        for(JSONObject state:new JSONObject[]{fixture(0,Integer.MAX_VALUE,1),fixture(Integer.MAX_VALUE,1)}){
            SyncLedger ledger=new SyncLedger();ledger.capture(fixture(0,20));String before=ledger.value.toString(),input=state.toString();
            rejects(()->ledger.capture(state),"capture accepted progress overflow");check(before.equals(ledger.value.toString()),"overflow capture mutated ledger");check(input.equals(state.toString()),"overflow capture mutated state");
            rejects(()->Planner.validate(state),"backup accepted progress overflow");
            SyncLedger imported=wire(state);String wireBefore=imported.value.toString();rejects(()->imported.materialize(),"materialize accepted progress overflow");rejects(()->archive(imported),"archive accepted progress overflow");
            check(wireBefore.equals(imported.value.toString()),"overflow materialization mutated ledger");
        }
    }
    static void validTotals()throws Exception{
        for(JSONObject state:new JSONObject[]{fixture(0,Integer.MAX_VALUE),fixture(0,Integer.MAX_VALUE-1,1),fixture(Integer.MAX_VALUE-1,1),fixture(Integer.MIN_VALUE,Integer.MAX_VALUE),fixture(0,1441)}){
            Planner.validate(state);SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize();
            check(restored.getJSONArray("completions").length()==state.getJSONArray("completions").length(),"representable legacy records changed");
            check(Planner.completed(restored,restored.getJSONArray("courses").getJSONObject(0))==120,"representable legacy progress changed");archive(ledger);
        }
    }
    static JSONObject source(JSONObject course,String id)throws Exception{
        if(course.getString("id").equals(id))return course;JSONArray children=course.optJSONArray("mergedSources");if(children==null)return null;
        for(JSONObject child:Planner.list(children)){JSONObject found=source(child,id);if(found!=null)return found;}return null;
    }
    static JSONObject nested(int baseline,String route)throws Exception{
        JSONObject state=fixture(0),first=state.getJSONArray("courses").getJSONObject(0);String source=first.getString("id");
        JSONObject second=CourseTools.copy(first).put("id",Planner.id()).put("name","B"),third=CourseTools.copy(first).put("id",Planner.id()).put("name","C");state.getJSONArray("courses").put(second).put(third);
        JSONObject task=Planner.task(source,NOW,60);state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),1,NOW);
        JSONObject merged=CourseTools.merge(state,new HashSet<>(Arrays.asList(source,second.getString("id"))),"First merge");
        JSONObject root=CourseTools.merge(state,new HashSet<>(Arrays.asList(merged.getString("id"),third.getString("id"))),"Nested merge");
        source(root,source).put("initialCompletedMinutes",baseline);
        if(route.equals("sibling"))task.put("lessonID",merged.getString("id")+"/"+second.getString("id")+"/whole");
        if(route.equals("outer"))task.put("lessonID",third.getString("id")+"/whole");
        // merge works on copies, so update the retained task rather than the original fixture reference.
        if(!route.equals("target")&&!route.equals("orphan"))state.getJSONArray("tasks").getJSONObject(0).put("lessonID",task.getString("lessonID"));
        if(route.equals("orphan"))state.put("tasks",new JSONArray());return state;
    }
    static void nestedTotals()throws Exception{
        JSONObject bad=nested(Integer.MAX_VALUE,"target");check(bad.getJSONArray("courses").getJSONObject(0).getInt("initialCompletedMinutes")==0,"parent fixture baseline is not normal");
        SyncLedger ledger=new SyncLedger();String before=ledger.value.toString();rejects(()->ledger.capture(bad),"nested baseline overflow passed capture");check(before.equals(ledger.value.toString()),"nested overflow changed ledger");
        rejects(()->Planner.validate(bad),"nested baseline overflow passed backup validation");SyncLedger imported=wire(bad);rejects(()->imported.materialize(),"nested baseline overflow passed materialization");rejects(()->archive(imported),"nested baseline overflow passed archive");
        for(String route:new String[]{"target","sibling","outer","orphan"}){
            JSONObject state=nested(route.equals("target")?Integer.MAX_VALUE-1:Integer.MAX_VALUE,route);Planner.validate(state);SyncLedger valid=new SyncLedger();valid.capture(state);JSONObject restored=valid.materialize();
            check(restored.getJSONArray("completions").length()==1,"nested progress record lost");
            check(Planner.completed(restored,restored.getJSONArray("courses").getJSONObject(0))==((route.equals("sibling")||route.equals("outer"))?121:120),"wrong prefix included in source progress: "+route);archive(valid);
        }
    }
    static void baselineNumbers()throws Exception{
        for(Object value:new Object[]{1.5,"1",true,JSONObject.NULL,4294967297L}){
            JSONObject state=fixture(0,1);state.getJSONArray("courses").getJSONObject(0).put("initialCompletedMinutes",value);
            SyncLedger ledger=new SyncLedger();String before=ledger.value.toString();rejects(()->ledger.capture(state),"invalid baseline primitive accepted");check(before.equals(ledger.value.toString()),"baseline rejection mutated ledger");
            rejects(()->Planner.validate(state),"backup truncated baseline primitive");SyncLedger imported=wire(state);rejects(()->imported.materialize(),"sync truncated baseline primitive");
        }
        for(Object value:new Object[]{1,1.0,new BigDecimal("1e0"),Integer.MIN_VALUE}){
            JSONObject state=fixture(0,1);state.getJSONArray("courses").getJSONObject(0).put("initialCompletedMinutes",value);
            Planner.validate(state);SyncLedger ledger=new SyncLedger();ledger.capture(state);JSONObject restored=ledger.materialize();
            check(Planner.completed(restored,restored.getJSONArray("courses").getJSONObject(0))==(value.equals(Integer.MIN_VALUE)?1:2),"exact baseline semantics changed");
        }
        JSONObject missing=fixture(0,1);missing.getJSONArray("courses").getJSONObject(0).remove("initialCompletedMinutes");Planner.validate(missing);SyncLedger ledger=new SyncLedger();ledger.capture(missing);
        JSONObject restored=ledger.materialize();check(Planner.completed(restored,restored.getJSONArray("courses").getJSONObject(0))==1,"legacy missing baseline is not zero");
    }
    static void discardedHistory()throws Exception{
        JSONObject state=fixture(0,Integer.MAX_VALUE,1);state.getJSONArray("courses").getJSONObject(0).put("isArchived",true);
        SyncLedger ledger=new SyncLedger();ledger.capture(state);check(ledger.materialize().getJSONArray("completions").length()==0,"archived progress was retained");
        SyncLedger deleted=wire(fixture(0,Integer.MAX_VALUE,1));Iterator<String> keys=deleted.records().keys();while(keys.hasNext()){JSONObject row=deleted.records().getJSONObject(keys.next());if(row.getString("kind").equals("completions"))row.put("deleted",true);}
        check(deleted.materialize().getJSONArray("completions").length()==0,"deleted progress was counted");archive(deleted);
    }
    public static void main(String[] args)throws Exception{
        invalidTotals();validTotals();nestedTotals();baselineNumbers();discardedHistory();System.out.println("Progress integrity checks passed: "+checks);
    }
}
