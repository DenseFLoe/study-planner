package local.studyplanner;

import org.json.*;
import java.io.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class EventWindowIntegrityTests {
    static int checks;
    static final double NOW=800_000_000;
    static final Object MISSING=new Object();
    interface Action { void run()throws Exception; }
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static void rejects(Action action,String message)throws Exception{
        boolean rejected=false;try{action.run();}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,message);
    }
    static JSONObject event(int start,int end,Integer floating)throws Exception{
        JSONObject event=new JSONObject().put("id",Planner.id()).put("title","Window integrity").put("startMinute",start).put("endMinute",end)
            .put("startDate",NOW).put("endDate",NOW).put("weekdays",new JSONArray()).put("excludedDates",new JSONArray()).put("color","blue").put("notes","");
        if(floating!=null)event.put("floatingDurationMinutes",floating);return event;
    }
    static JSONObject state(JSONObject event)throws Exception{return SyncExchangeTests.initial().put("fixedEvents",new JSONArray().put(event));}
    static void payload(JSONObject row,String json)throws Exception{row.put("payload",Base64.getEncoder().encodeToString(json.getBytes(StandardCharsets.UTF_8)));}
    static SyncLedger wire(JSONObject event)throws Exception{
        SyncLedger ledger=new SyncLedger();ledger.capture(SyncExchangeTests.initial());
        JSONObject row=new JSONObject().put("kind","fixedEvents").put("id",event.getString("id")).put("deleted",false)
            .put("version",1).put("sequence",1).put("device","event-window-fixture");
        payload(row,event.toString());ledger.records().put(SyncLedger.key(row),row);return ledger;
    }
    static void archive(SyncLedger ledger)throws Exception{
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();CloudSnapshot.write(bytes,ledger,CloudSnapshot.header(ledger));CloudSnapshot.read(new ByteArrayInputStream(bytes.toByteArray()));
    }
    static void rejectedAtBoundaries(JSONObject event)throws Exception{
        JSONObject input=state(event);String original=input.toString();SyncLedger ledger=new SyncLedger();ledger.capture(state(event(480,540,null)));
        String before=ledger.value.toString();rejects(()->ledger.capture(input),"capture accepted invalid event window/number");
        check(before.equals(ledger.value.toString()),"event rejection changed ledger");rejects(()->Planner.validate(input),"backup accepted invalid event window/number");
        SyncLedger imported=wire(event);String wireBefore=imported.value.toString();rejects(()->imported.materialize(),"materialize accepted invalid event window/number");
        rejects(()->archive(imported),"archive accepted invalid event window/number");check(wireBefore.equals(imported.value.toString()),"rejected event read changed ledger");
        check(original.equals(input.toString()),"event validation mutated input");
    }
    static void invalidWindows()throws Exception{
        for(int[] range:new int[][]{{-1,60},{0,1441},{60,60},{61,60},{Integer.MIN_VALUE,Integer.MAX_VALUE},{Integer.MAX_VALUE,Integer.MIN_VALUE}})
            for(Integer floating:new Integer[]{null,60})rejectedAtBoundaries(event(range[0],range[1],floating));
        for(int floating:new int[]{0,-1,61,Integer.MIN_VALUE,Integer.MAX_VALUE})rejectedAtBoundaries(event(0,60,floating));
    }
    static void invalidNumbers()throws Exception{
        for(String field:new String[]{"startMinute","endMinute","floatingDurationMinutes"}){
            int ordinary=field.equals("startMinute")?480:field.equals("endMinute")?540:60;
            List<Object> values=new ArrayList<>(Arrays.asList(4294967296L+ordinary,ordinary+0.5,String.valueOf(ordinary),true));
            if(!field.equals("floatingDurationMinutes")){values.add(JSONObject.NULL);values.add(MISSING);}
            for(Object value:values){JSONObject bad=event(480,540,60);if(value==MISSING)bad.remove(field);else bad.put(field,value);rejectedAtBoundaries(bad);}
        }
    }
    static void validBoundaries()throws Exception{
        for(JSONObject event:new JSONObject[]{event(0,1,null),event(1439,1440,null),event(0,1440,null),event(0,1440,1),event(0,1440,1440),event(480,540,60)}){
            JSONObject input=state(event);String original=input.toString();Planner.validate(input);SyncLedger ledger=new SyncLedger();ledger.capture(input);String before=ledger.value.toString();
            JSONObject restored=ledger.materialize();check(SyncLedger.equivalent(restored.getJSONArray("fixedEvents").getJSONObject(0),event),"valid event boundary changed");
            archive(ledger);ledger.capture(restored);check(before.equals(ledger.value.toString()),"valid event roundtrip changed ledger");check(original.equals(input.toString()),"valid event checks mutated input");
        }
    }
    static void optionalFloatingAndNumericForms()throws Exception{
        for(Object floating:new Object[]{MISSING,JSONObject.NULL,60L,60.0,new BigDecimal("6e1")}){
            JSONObject event=event(480,540,null).put("startMinute",480.0).put("endMinute",new BigDecimal("5.4e2"));
            if(floating!=MISSING)event.put("floatingDurationMinutes",floating);JSONObject input=state(event);Planner.validate(input);
            SyncLedger ledger=new SyncLedger();ledger.capture(input);JSONObject restored=ledger.materialize().getJSONArray("fixedEvents").getJSONObject(0);
            check(restored.getInt("startMinute")==480&&restored.getInt("endMinute")==540,"integer-valued required event numbers changed");
            check(Planner.floating(restored)==(floating!=MISSING&&floating!=JSONObject.NULL),"optional floating event changed mode");archive(ledger);
        }
        for(String floating:new String[]{"missing","null","6e1"}){
            JSONObject event=event(480,540,null);SyncLedger ledger=wire(event);
            String original=event.toString(),json=original.replace("\"startMinute\":480","\"startMinute\":4.8e2").replace("\"endMinute\":540","\"endMinute\":540.0");
            check(!json.equals(original),"event numeric token fixture did not change");
            if(!floating.equals("missing"))json=json.substring(0,json.length()-1)+",\"floatingDurationMinutes\":"+floating+"}";
            payload(ledger.records().getJSONObject("fixedEvents/"+event.getString("id")),json);
            JSONObject restored=ledger.materialize().getJSONArray("fixedEvents").getJSONObject(0);
            check(restored.getInt("startMinute")==480&&restored.getInt("endMinute")==540,"event wire integer form rejected");
            check(Planner.floating(restored)==floating.equals("6e1"),"wire optional floating form changed");archive(ledger);
        }
    }
    static void ignoredTombstonesAndUnchangedScope()throws Exception{
        JSONObject bad=event(Integer.MIN_VALUE,Integer.MAX_VALUE,60);
        for(String json:new String[]{bad.toString(),"not JSON"}){
            SyncLedger ledger=wire(bad);JSONObject row=ledger.records().getJSONObject("fixedEvents/"+bad.getString("id"));payload(row,json);row.put("deleted",true);String before=ledger.value.toString();
            check(ledger.materialize().getJSONArray("fixedEvents").length()==0,"deleted event payload was decoded");archive(ledger);check(before.equals(ledger.value.toString()),"ignored event tombstone changed");
        }
        JSONObject unusual=event(480,540,null).put("endDate",NOW-86400).put("weekdays",new JSONArray().put(0).put(8));
        JSONObject input=state(unusual);Planner.validate(input);SyncLedger ledger=new SyncLedger();ledger.capture(input);
        check(SyncLedger.equivalent(ledger.materialize().getJSONArray("fixedEvents").getJSONObject(0),unusual),"window validation added date/weekday policy");archive(ledger);
    }
    public static void main(String[] args)throws Exception{
        invalidWindows();invalidNumbers();validBoundaries();optionalFloatingAndNumericForms();ignoredTombstonesAndUnchangedScope();
        System.out.println("Event window integrity checks passed: "+checks);
    }
}
