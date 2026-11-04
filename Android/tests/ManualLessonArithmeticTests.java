package local.studyplanner;

import org.json.*;
import java.io.*;
import java.util.*;

public final class ManualLessonArithmeticTests {
    static int checks;
    static final double NOW=800_000_000;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static JSONObject course(int total,int baseline,int... lengths)throws Exception{
        JSONObject value=SyncExchangeTests.fixture(NOW).getJSONArray("courses").getJSONObject(0);
        value.put("type","不定时录播课程").put("totalMinutes",total).put("initialCompletedMinutes",baseline);
        JSONArray lessons=new JSONArray();
        for(int i=0;i<lengths.length;i++)lessons.put(new JSONObject().put("id","lesson-"+i).put("name","Lesson "+i).put("durationMinutes",lengths[i]));
        return value.put("manualLessons",lessons);
    }
    static JSONObject state(JSONObject course)throws Exception{
        return SyncExchangeTests.initial().put("courses",new JSONArray().put(course));
    }
    static JSONObject roundTrip(JSONObject state)throws Exception{
        String before=state.toString();SyncLedger ledger=new SyncLedger();ledger.capture(state);String captured=ledger.value.toString();
        JSONObject restored=ledger.materialize();
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));
        CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
        check(before.equals(state.toString()),"sync changed input");check(captured.equals(ledger.value.toString()),"reading changed ledger");return restored;
    }
    static void overflowFallback()throws Exception{
        for(int[] lengths:new int[][]{{Integer.MAX_VALUE,1},{Integer.MAX_VALUE,Integer.MAX_VALUE,122}}){
            JSONObject input=state(course(120,0,lengths)),restored=roundTrip(input),saved=restored.getJSONArray("courses").getJSONObject(0);String before=restored.toString();
            check(Planner.lessonWorkAll(restored,saved).isEmpty(),"overflow accepted manual lesson sum");
            check(Planner.completed(restored,saved)==0&&Planner.remaining(restored,saved)==120,"overflow fallback changed progress");
            check(saved.getJSONArray("manualLessons").toString().equals(input.getJSONArray("courses").getJSONObject(0).getJSONArray("manualLessons").toString()),"fallback changed manual lessons");
            check(before.equals(restored.toString()),"overflow reader changed state");
        }
    }
    static void representableMaximum()throws Exception{
        JSONObject restored=roundTrip(state(course(Integer.MAX_VALUE,20,Integer.MAX_VALUE-1,1))),saved=restored.getJSONArray("courses").getJSONObject(0);String before=restored.toString();
        List<Planner.Work> items=Planner.lessonWorkAll(restored,saved);
        check(items.size()==2&&items.get(0).minutes==Integer.MAX_VALUE-21&&items.get(1).minutes==1,"representable maximum lost manual lessons");
        check(Planner.completed(restored,saved)==20&&Planner.remaining(restored,saved)==Integer.MAX_VALUE-20,"representable maximum changed progress");
        check(before.equals(restored.toString()),"maximum reader changed state");
    }
    static void existingFallbacks()throws Exception{
        for(int[] lengths:new int[][]{{60,59},{0,120},{-1,121},{Integer.MAX_VALUE,0},{}}){
            JSONObject input=state(course(120,20,lengths)),restored=roundTrip(input),saved=restored.getJSONArray("courses").getJSONObject(0);String before=restored.toString();
            check(Planner.lessonWorkAll(restored,saved).isEmpty(),"invalid manual table did not retain fallback");
            check(Planner.completed(restored,saved)==20&&Planner.remaining(restored,saved)==100,"existing fallback lost baseline");
            check(before.equals(restored.toString()),"fallback reader changed state");
        }
    }
    static void nestedFallback()throws Exception{
        JSONObject leaf=course(120,20,Integer.MAX_VALUE,Integer.MAX_VALUE,122),branch=course(120,20),sibling=course(60,0,60),root=course(180,20);
        branch.remove("manualLessons");branch.put("mergedSources",new JSONArray().put(leaf));
        root.remove("manualLessons");root.put("mergedSources",new JSONArray().put(branch).put(sibling));
        JSONObject restored=roundTrip(state(root)),saved=restored.getJSONArray("courses").getJSONObject(0);String before=restored.toString();
        List<Planner.Work> items=Planner.lessonWorkAll(restored,saved);Map<String,Integer> remaining=new HashMap<>();for(Planner.Work item:items)remaining.put(item.lessonID,item.minutes);
        String fallback=branch.getString("id")+"/"+leaf.getString("id")+"/whole",siblingID=sibling.getString("id")+"/lesson-0";
        check(items.size()==2&&remaining.keySet().equals(new HashSet<>(Arrays.asList(fallback,siblingID))),"nested fallback lost full prefixes");
        check(remaining.get(fallback)==100&&remaining.get(siblingID)==60,"nested fallback lost source baseline or sibling work");
        check(Planner.completed(restored,saved)==20&&Planner.remaining(restored,saved)==160,"nested progress changed");
        check(before.equals(restored.toString()),"nested reader changed state");
    }
    static void normalConfirmation()throws Exception{
        JSONObject manual=course(120,10,60,60),input=state(manual),task=Planner.task(manual.getString("id"),NOW-3600,60).put("lessonID","lesson-1");
        input.getJSONArray("tasks").put(task);Planner.confirm(input,task.getString("id"),20,NOW);
        JSONObject restored=roundTrip(input),saved=restored.getJSONArray("courses").getJSONObject(0);String before=restored.toString();List<Planner.Work> items=Planner.lessonWorkAll(restored,saved);
        check(items.size()==2&&items.get(0).lessonID.equals("lesson-0")&&items.get(1).lessonID.equals("lesson-1"),"normal lesson identities changed");
        check(items.get(0).minutes==50&&items.get(1).minutes==40,"confirmation moved to a different lesson");
        check(Planner.completed(restored,saved)==30&&Planner.remaining(restored,saved)==90,"normal progress changed");
        check(restored.getJSONArray("completions").length()==1,"completion record count changed");
        JSONObject originalRecord=input.getJSONArray("completions").getJSONObject(0),restoredRecord=restored.getJSONArray("completions").getJSONObject(0);
        for(String field:new String[]{"id","courseID","taskID"})check(restoredRecord.getString(field).equals(originalRecord.getString(field)),"completion identity changed: "+field);
        for(String field:new String[]{"minutes","recordedAt","studyDate"})check(restoredRecord.getDouble(field)==originalRecord.getDouble(field),"completion value changed: "+field);
        check(before.equals(restored.toString()),"normal reader changed state");
    }
    public static void main(String[] args)throws Exception{
        overflowFallback();representableMaximum();existingFallbacks();nestedFallback();normalConfirmation();
        System.out.println("Manual lesson arithmetic checks passed: "+checks);
    }
}
