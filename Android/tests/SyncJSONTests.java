package local.studyplanner;
import org.json.*;
import java.io.*;
import java.util.*;

public final class SyncJSONTests {
    static int checks;
    interface Action{void run()throws Exception;}
    static void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    static void rejects(Action action)throws Exception{boolean bad=false;try{action.run();}catch(Exception expected){bad=true;}check(bad,"malformed exchange accepted");}
    public static void main(String[] args)throws Exception{
        JSONObject row=new JSONObject().put("name","中文\n\t\b\f\r\"\\/😀").put("nested",new JSONArray().put(new JSONObject().put("x",true))).put("null",JSONObject.NULL).put("number",1.0);
        JSONObject wire=new JSONObject().put("changes",new JSONArray().put(row)).put("protocol",1).put("cursor",0).put("automatic",false).put("date","2026-10-19");
        StringWriter output=new StringWriter();SyncJSON.write(output,wire);int[] count={0};
        JSONObject headers=SyncJSON.readExchange(new StringReader(output.toString()),received->{check(SyncLedger.equivalent(row,received),"escaped/nested data changed");count[0]++;});
        check(count[0]==1&&headers.getInt("protocol")==1,"record/header parsing failed");
        for(String invalid:new String[]{"{}","{\"changes\":[]", "{\"changes\":[],\"changes\":[]}", "{\"changes\":[]}trailing", "{\"changes\":[{},]}", "{\"changes\":null}","{\"changes\":[],\"bad\":true}"})rejects(()->SyncJSON.readExchange(new StringReader(invalid),received->{}));
        JSONObject copy=CourseTools.copy(row);copy.getJSONArray("nested").getJSONObject(0).put("x",false);
        check(row.getJSONArray("nested").getJSONObject(0).getBoolean("x"),"copy shared mutable objects");
        check(copy.getString("name")==row.getString("name"),"copy duplicated immutable strings");
        JSONObject numeric=new JSONObject().put("a",1).put("b",new JSONArray().put(2.0));
        check(SyncLedger.equivalent(numeric,new JSONObject("{\"b\":[2],\"a\":1.0}")),"number/key-order semantics changed");
        System.out.println("PASS "+checks+" streaming JSON, malformed envelopes, copy isolation and numeric equivalence checks");
    }
}
