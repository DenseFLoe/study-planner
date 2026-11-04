package local.studyplanner;

import org.json.*;
import java.io.*;
import java.util.*;

public final class ManualLessonIdentityTests {
    static int checks;
    static final double NOW=800_000_000;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject course(int baseline,String... ids)throws Exception{
        JSONObject value=SyncExchangeTests.fixture(NOW).getJSONArray("courses").getJSONObject(0);
        value.put("type","不定时录播课程").put("totalMinutes",ids.length*60).put("initialCompletedMinutes",baseline);
        JSONArray lessons=new JSONArray();for(int i=0;i<ids.length;i++)lessons.put(new JSONObject().put("id",ids[i]).put("name","Lesson "+i).put("durationMinutes",60));
        return value.put("manualLessons",lessons);
    }
    static JSONObject state(JSONObject course)throws Exception{return SyncExchangeTests.initial().put("courses",new JSONArray().put(course));}
    static JSONObject roundTrip(JSONObject state)throws Exception{
        String before=state.toString();SyncLedger ledger=new SyncLedger();ledger.capture(state);String captured=ledger.value.toString();JSONObject restored=ledger.materialize();
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
        check(before.equals(state.toString()),"sync mutated input");check(captured.equals(ledger.value.toString()),"reading mutated ledger");return restored;
    }
    static JSONObject confirmedState(JSONObject course,String lesson)throws Exception{
        JSONObject state=state(course),task=Planner.task(course.getString("id"),NOW-3600,60).put("lessonID",lesson);
        state.getJSONArray("tasks").put(task);Planner.confirm(state,task.getString("id"),20,NOW);return state;
    }
    static void sameConfirmation(JSONObject state,JSONObject input)throws Exception{
        check(state.getJSONArray("completions").length()==1,"confirmation count changed");
        JSONObject saved=state.getJSONArray("completions").getJSONObject(0),original=input.getJSONArray("completions").getJSONObject(0);
        for(String field:new String[]{"id","courseID","taskID"})check(saved.getString(field).equals(original.getString(field)),"confirmation identity changed");
        for(String field:new String[]{"minutes","recordedAt","studyDate"})check(saved.getDouble(field)==original.getDouble(field),"confirmation value changed");
    }
    static void duplicateFallback()throws Exception{
        for(boolean confirmed:new boolean[]{false,true}){
            JSONObject manual=course(confirmed?10:0,"same","same"),input=confirmed?confirmedState(manual,"same"):state(manual);
            JSONObject restored=roundTrip(input),saved=restored.getJSONArray("courses").getJSONObject(0);String before=restored.toString();
            check(Planner.lessonWorkAll(restored,saved).isEmpty(),"duplicate identity still used as separate lessons");
            check(Planner.completed(restored,saved)==(confirmed?30:0),"duplicate table invented or erased progress");
            check(Planner.remaining(restored,saved)==(confirmed?90:120),"duplicate fallback changed remaining work");
            if(confirmed)sameConfirmation(restored,input);else check(restored.getJSONArray("completions").length()==0,"duplicate reader created a confirmation");
            check(saved.getJSONArray("manualLessons").toString().equals(manual.getJSONArray("manualLessons").toString()),"duplicate reader rewrote lessons");
            check(before.equals(restored.toString()),"duplicate reader mutated state");
        }
    }
    static void nestedFallback()throws Exception{
        JSONObject leaf=course(20,"same","same"),branch=course(20,"first","second"),sibling=course(0,"only"),root=course(20,"a","b","c");
        branch.remove("manualLessons");branch.put("mergedSources",new JSONArray().put(leaf));root.remove("manualLessons");root.put("mergedSources",new JSONArray().put(branch).put(sibling));
        JSONObject restored=roundTrip(state(root)),saved=restored.getJSONArray("courses").getJSONObject(0);String before=restored.toString();
        List<Planner.Work> items=Planner.lessonWorkAll(restored,saved);Map<String,Integer> work=new HashMap<>();for(Planner.Work item:items)work.put(item.lessonID,item.minutes);
        String fallback=branch.getString("id")+"/"+leaf.getString("id")+"/whole",siblingID=sibling.getString("id")+"/only";
        check(items.size()==2&&work.keySet().equals(new HashSet<>(Arrays.asList(fallback,siblingID))),"nested fallback lost full identities");
        check(work.get(fallback)==100&&work.get(siblingID)==60,"nested fallback lost source baseline or sibling work");
        check(Planner.completed(restored,saved)==20&&Planner.remaining(restored,saved)==160,"nested duplicate created progress");
        check(before.equals(restored.toString()),"nested reader mutated state");
    }
    static void unusedManualTables()throws Exception{
        JSONObject web=course(30,"same","same"),snapshot=new JSONObject().put("packageID","synthetic").put("name","Web lessons").put("sourceURL","https://example.com/course")
            .put("fetchedAt",NOW).put("expectedOutlines",1).put("fetchedOutlines",1).put("issues",new JSONArray());
        JSONArray lessons=new JSONArray();for(int i=0;i<2;i++)lessons.put(new JSONObject().put("id","web-"+i).put("name","Web "+i).put("subject","").put("stage","").put("chapter","").put("kind","video")
            .put("published",true).put("durationSeconds",3600).put("watchedPercent",i==0?50:0).put("markedFinished",false).put("requiresDuration",true));
        web.put("webCourse",snapshot.put("lessons",lessons));
        JSONObject child=course(10,"first","second"),merged=course(10,"same","same").put("mergedSources",new JSONArray().put(child)),recorded=course(10,"same","same").put("type","录播课程");
        for(JSONObject original:new JSONObject[]{web,merged,recorded}){
            JSONObject restored=roundTrip(state(original)),saved=restored.getJSONArray("courses").getJSONObject(0);String before=restored.toString();List<Planner.Work> items=Planner.lessonWorkAll(restored,saved);
            if(original==web){check(items.size()==2&&items.get(0).lessonID.equals("web-0")&&items.get(1).lessonID.equals("web-1"),"unused manual IDs overrode web identities");check(items.get(0).minutes==30&&items.get(1).minutes==60&&Planner.completed(restored,saved)==30,"web progress changed");}
            else if(original==merged){Set<String> ids=new HashSet<>();for(Planner.Work item:items)ids.add(item.lessonID);check(items.size()==2&&ids.equals(new HashSet<>(Arrays.asList(child.getString("id")+"/first",child.getString("id")+"/second"))),"unused parent manual table hid merged sources");check(Planner.completed(restored,saved)==10,"merged source baseline changed");}
            else check(items.isEmpty()&&Planner.completed(restored,saved)==10,"non-lesson course started using manual metadata");
            check(saved.getJSONArray("manualLessons").toString().equals(original.getJSONArray("manualLessons").toString()),"unused manual metadata changed");check(before.equals(restored.toString()),"unused metadata reader mutated state");
        }
    }
    static void uniqueCustomOrder()throws Exception{
        JSONObject manual=course(10,"first","second").put("lessonOrder",new JSONArray().put("second").put("first")),input=confirmedState(manual,"second"),restored=roundTrip(input),saved=restored.getJSONArray("courses").getJSONObject(0);
        String before=restored.toString();List<Planner.Work> items=Planner.lessonWorkAll(restored,saved);
        check(items.size()==2&&items.get(0).lessonID.equals("second")&&items.get(1).lessonID.equals("first"),"unique custom order changed");
        check(items.get(0).minutes==40&&items.get(1).minutes==50&&Planner.completed(restored,saved)==30,"unique lesson-specific credit changed");
        sameConfirmation(restored,input);check(before.equals(restored.toString()),"unique reader mutated state");
    }
    public static void main(String[] args)throws Exception{duplicateFallback();nestedFallback();unusedManualTables();uniqueCustomOrder();System.out.println("Manual lesson identity checks passed: "+checks);}
}
