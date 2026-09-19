package local.studyplanner;

import org.json.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Pure protocol engine, shared JSON schema with Swift SyncLedger. */
public final class SyncLedger {
    public static final String[] KINDS={"courses","fixedEvents","tasks","completions","settings"};
    public final JSONObject value;
    public SyncLedger(JSONObject value)throws Exception{this.value=value;}
    public SyncLedger()throws Exception{this(new JSONObject().put("device",Planner.id()).put("clock",0).put("sequence",0).put("peerCursor",0).put("sentCursor",0).put("records",new JSONObject()).put("lastAutoDate","").put("lastSuccess",0).put("lastAttempt",0));}
    JSONObject records()throws Exception{return value.getJSONObject("records");}
    public long sequence(){return value.optLong("sequence");}
    public static String key(JSONObject r)throws Exception{return r.getString("kind")+"/"+r.getString("id");}
    public static boolean wins(JSONObject a,JSONObject b)throws Exception{return a.getLong("version")!=b.getLong("version")?a.getLong("version")>b.getLong("version"):a.getString("device").compareTo(b.getString("device"))>0;}
    static String canonical(Object o)throws Exception{
        if(o instanceof JSONObject){JSONObject j=(JSONObject)o;List<String> ks=new ArrayList<>();Iterator<String> it=j.keys();while(it.hasNext())ks.add(it.next());Collections.sort(ks);StringBuilder s=new StringBuilder("{");for(String k:ks)s.append(JSONObject.quote(k)).append(':').append(canonical(j.get(k))).append(',');return s.append('}').toString();}
        if(o instanceof JSONArray){JSONArray j=(JSONArray)o;StringBuilder s=new StringBuilder("[");for(int i=0;i<j.length();i++)s.append(canonical(j.get(i))).append(',');return s.append(']').toString();}
        if(o instanceof Number)return new java.math.BigDecimal(o.toString()).stripTrailingZeros().toPlainString();
        return o instanceof String ? JSONObject.quote((String)o) : String.valueOf(o);
    }
    static JSONObject payload(JSONObject row)throws Exception{return new JSONObject(new String(Base64.getDecoder().decode(row.getString("payload")),StandardCharsets.UTF_8));}
    public void capture(JSONObject state)throws Exception{
        JSONObject desired=new JSONObject(),records=records();List<JSONObject> changes=new ArrayList<>();
        for(String kind:KINDS){List<JSONObject> values=kind.equals("settings")?Collections.singletonList(state.getJSONObject(kind)):Planner.list(state.getJSONArray(kind));
            for(JSONObject source:values){JSONObject data=new JSONObject(source.toString());
                if(kind.equals("completions"))data.put("id",Planner.stableID("completion|"+data.getString("taskID")));
                if(kind.equals("fixedEvents"))for(String field:new String[]{"weekdays","excludedDates"}){JSONArray a=data.optJSONArray(field);if(a!=null){List<Double> items=new ArrayList<>();for(int i=0;i<a.length();i++)items.add(a.getDouble(i));Collections.sort(items);data.put(field,new JSONArray(items));}}
                String id=kind.equals("settings")?"settings":data.getString("id");JSONObject r=new JSONObject().put("kind",kind).put("id",id).put("deleted",false).put("payload",Base64.getEncoder().encodeToString(data.toString().getBytes(StandardCharsets.UTF_8)));String k=key(r);desired.put(k,r);JSONObject old=records.optJSONObject(k);if(old==null||old.getBoolean("deleted")||!canonical(payload(old)).equals(canonical(data)))changes.add(r);}}
        Iterator<String> it=records.keys();while(it.hasNext()){String k=it.next();JSONObject old=records.getJSONObject(k);if(!desired.has(k)&&!old.getBoolean("deleted"))changes.add(new JSONObject(old.toString()).put("deleted",true));}
        if(changes.isEmpty())return;long clock=value.getLong("clock")+1;value.put("clock",clock);changes.sort(Comparator.comparing(r->r.optString("kind")+"/"+r.optString("id")));
        for(JSONObject r:changes){long seq=sequence()+1;value.put("sequence",seq);r.put("version",clock).put("device",value.getString("device")).put("sequence",seq);records.put(key(r),r);}
    }
    public JSONArray changes(long after)throws Exception{if(after<0||after>sequence())throw new IllegalArgumentException("游标无效，请重新配对");List<JSONObject> out=new ArrayList<>();Iterator<String> it=records().keys();while(it.hasNext()){JSONObject r=records().getJSONObject(it.next());if(r.getLong("sequence")>after)out.add(r);}out.sort(Comparator.comparingLong(r->r.optLong("sequence")));return new JSONArray(out);}
    public void merge(JSONArray incoming)throws Exception{
        for(JSONObject item:Planner.list(incoming)){JSONObject r=new JSONObject(item.toString());String kind=r.getString("kind"),id=r.getString("id");long v=r.getLong("version");
            if(!Arrays.asList(KINDS).contains(kind)||v<=0||v>Long.MAX_VALUE-1000000||r.getString("device").isEmpty()||r.getString("device").length()>64||r.getString("payload").length()>1400000)throw new IllegalArgumentException("同步记录无效");
            if(kind.equals("settings")?!id.equals("settings"):!UUID.fromString(id).toString().toUpperCase(Locale.ROOT).equals(id))throw new IllegalArgumentException("同步 ID 无效");
            value.put("clock",Math.max(value.getLong("clock"),v));JSONObject old=records().optJSONObject(key(r));if(old!=null&&!wins(r,old))continue;long seq=sequence()+1;value.put("sequence",seq);r.put("sequence",seq);records().put(key(r),r);
        }
    }
    public JSONObject materialize()throws Exception{
        JSONObject s=new JSONObject().put("schemaVersion",1);for(String kind:KINDS)if(!kind.equals("settings"))s.put(kind,new JSONArray());
        List<String> keys=new ArrayList<>();Iterator<String> it=records().keys();while(it.hasNext())keys.add(it.next());Collections.sort(keys);
        for(String k:keys){JSONObject r=records().getJSONObject(k);if(r.getBoolean("deleted"))continue;String kind=r.getString("kind");JSONObject p=payload(r);if(kind.equals("settings"))s.put(kind,p);else{if(!r.getString("id").equals(p.getString("id")))throw new IllegalArgumentException("记录 ID 不匹配");s.getJSONArray(kind).put(p);}}
        Planner.validate(s);return s;
    }
}
