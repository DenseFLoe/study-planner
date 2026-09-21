package local.studyplanner;

import android.content.*;
import android.database.Cursor;
import android.database.sqlite.*;
import org.json.*;

/** Business rows, tombstones and sync cursors commit together. Legacy JSON stays as backup. */
public final class PlannerDatabase extends SQLiteOpenHelper {
    public PlannerDatabase(Context context){this(context,"planner-sync-v1.db");}
    PlannerDatabase(Context context,String name){super(context,name,null,1);setWriteAheadLoggingEnabled(true);}
    public void onCreate(SQLiteDatabase db){db.execSQL("CREATE TABLE records (id TEXT PRIMARY KEY, body TEXT NOT NULL)");db.execSQL("CREATE TABLE metadata (id TEXT PRIMARY KEY, body TEXT NOT NULL)");}
    public void onUpgrade(SQLiteDatabase db,int old,int next){throw new IllegalStateException("不支持此数据库版本");}
    public synchronized boolean initialized(){try(Cursor c=getReadableDatabase().rawQuery("SELECT id FROM metadata WHERE id='sync'",null)){return c.moveToFirst();}}
    public synchronized SyncLedger ledger()throws Exception{
        SQLiteDatabase db=getReadableDatabase();JSONObject meta;
        try(Cursor c=db.rawQuery("SELECT body FROM metadata WHERE id='sync'",null)){if(!c.moveToFirst())return new SyncLedger();meta=new JSONObject(c.getString(0));}
        JSONObject rows=new JSONObject();try(Cursor c=db.rawQuery("SELECT id,body FROM records",null)){while(c.moveToNext())rows.put(c.getString(0),new JSONObject(c.getString(1)));}meta.put("records",rows);return new SyncLedger(meta);
    }
    public synchronized JSONObject load()throws Exception{
        SyncLedger l=ledger();long before=l.sequence();JSONObject state=l.materialize();l.capture(state);if(l.sequence()!=before)commit(l);return state;
    }
    public synchronized void save(JSONObject state)throws Exception{Planner.validate(state);SyncLedger l=ledger();l.capture(state);commit(l);}
    public synchronized void commit(SyncLedger l)throws Exception{
        l.materialize();SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{
            JSONObject rows=l.value.getJSONObject("records");java.util.Iterator<String> it=rows.keys();while(it.hasNext()){String key=it.next();ContentValues v=new ContentValues();v.put("id",key);v.put("body",rows.getJSONObject(key).toString());if(db.insertWithOnConflict("records",null,v,SQLiteDatabase.CONFLICT_REPLACE)<0)throw new android.database.SQLException("记录保存失败");}
            JSONObject meta=new JSONObject(l.value.toString());meta.remove("records");ContentValues v=new ContentValues();v.put("id","sync");v.put("body",meta.toString());if(db.insertWithOnConflict("metadata",null,v,SQLiteDatabase.CONFLICT_REPLACE)<0)throw new android.database.SQLException("同步状态保存失败");db.setTransactionSuccessful();
        }finally{db.endTransaction();}
    }
    public synchronized JSONObject exchange(JSONObject request)throws Exception{
        SyncLedger l=ledger();if(request.getInt("protocol")!=1)throw new IllegalArgumentException("协议版本不兼容");
        long cursor=request.getLong("cursor");if(cursor<0||cursor>l.sequence())throw new IllegalArgumentException("同步游标无效，请重新配对");
        int added=0,modified=0,removed=0;for(JSONObject r:Planner.list(request.getJSONArray("changes"))){JSONObject old=l.records().optJSONObject(SyncLedger.key(r));if(old!=null&&!SyncLedger.wins(r,old))continue;if(r.getBoolean("deleted"))removed++;else if(old==null||old.getBoolean("deleted"))added++;else modified++;}
        JSONObject previous=l.materialize();l.merge(request.getJSONArray("changes"));JSONObject state=l.materialize();
        // Android reconciles generated future plans once; importing on Mac never triggers replan.
        reconcileTasks(l,state);reconcileConfirmations(state);
        if(needsReplan(previous,state,Planner.now()))Planner.replan(state,Planner.now());
        l.capture(state);commit(l);
        return new JSONObject().put("protocol",1).put("device",l.value.getString("device")).put("cursor",l.sequence()).put("changes",l.changes(cursor)).put("applied","新增 "+added+"，修改 "+modified+"，删除 "+removed);
    }
    // A legacy random ID and a newly generated stable ID can describe the same block.
    // Resolve exact duplicates before they become two active/history entries or two credits.
    static void reconcileTasks(SyncLedger ledger,JSONObject state)throws Exception {
        java.util.Map<String,JSONObject> winners=new java.util.TreeMap<>();
        for(JSONObject task:Planner.list(state.getJSONArray("tasks"))){
            String key=task.getString("courseID")+"|"+task.getDouble("start")+"|"+task.getInt("durationMinutes");
            JSONObject old=winners.get(key);
            if(old==null){winners.put(key,task);continue;}
            JSONObject a=ledger.records().getJSONObject("tasks/"+task.getString("id")),b=ledger.records().getJSONObject("tasks/"+old.getString("id"));
            if(SyncLedger.wins(a,b)||(!SyncLedger.wins(b,a)&&task.getString("id").compareTo(old.getString("id"))>0))winners.put(key,task);
        }
        state.put("tasks",new JSONArray(winners.values()));
    }
    static void reconcileConfirmations(JSONObject state)throws Exception {
        JSONArray records=new JSONArray();for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(t.has("confirmedAt"))
            records.put(new JSONObject().put("id",Planner.stableID("completion|"+t.getString("id"))).put("taskID",t.getString("id")).put("courseID",t.getString("courseID")).put("minutes",t.getInt("completedMinutes")).put("recordedAt",t.getDouble("confirmedAt")));
        state.put("completions",records);
    }
    static boolean needsReplan(JSONObject previous,JSONObject state,double now)throws Exception {
        for(String kind:new String[]{"courses","fixedEvents","settings"})if(!SyncLedger.canonical(previous.get(kind)).equals(SyncLedger.canonical(state.get(kind))))return true;
        java.util.List<JSONObject> pending=new java.util.ArrayList<>();java.util.Map<String,Integer> totals=new java.util.HashMap<>();
        for(JSONObject t:Planner.list(state.getJSONArray("tasks")))if(Planner.pending(t)&&Planner.end(t)>now){pending.add(t);String id=t.getString("courseID");totals.put(id,totals.getOrDefault(id,0)+t.getInt("durationMinutes"));}
        pending.sort(java.util.Comparator.comparingDouble(t->t.optDouble("start")));for(int i=1;i<pending.size();i++)if(Planner.end(pending.get(i-1))>pending.get(i).getDouble("start"))return true;
        for(JSONObject c:Planner.list(state.getJSONArray("courses")))if(totals.getOrDefault(c.getString("id"),0)>Planner.remaining(state,c))return true;
        return false;
    }
    public synchronized void finish(boolean auto,String date)throws Exception{SyncLedger l=ledger();l.value.put("lastSuccess",System.currentTimeMillis()/1000.0);if(auto)l.value.put("lastAutoDate",date);commit(l);}
}
