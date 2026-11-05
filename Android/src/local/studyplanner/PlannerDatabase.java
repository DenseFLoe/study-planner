package local.studyplanner;

import android.content.*;
import android.database.Cursor;
import android.database.sqlite.*;
import org.json.*;

/** Business rows, tombstones and sync cursors commit together. Legacy JSON stays as backup. */
public final class PlannerDatabase extends SQLiteOpenHelper implements StateMutation.Store<JSONObject> {
    private final Context context;
    final PlannerBackupRepository backups;
    volatile String lastDeletedBackup;
    public PlannerDatabase(Context context){this(context,"planner-sync-v1.db");}
    PlannerDatabase(Context context,String name){super(context,name,null,1);this.context=context.getApplicationContext();backups=new PlannerBackupRepository(new java.io.File(context.getFilesDir(),name+"-backups"));setWriteAheadLoggingEnabled(true);}
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
    public synchronized void save(JSONObject state)throws Exception{
        Planner.validate(state);SyncLedger l=ledger();JSONObject before=initialized()?l.materialize():null;
        if(before!=null&&!SyncLedger.canonical(PlannerBackupFile.businessState(before)).equals(SyncLedger.canonical(PlannerBackupFile.businessState(state)))){
            java.util.List<String> deleted=new java.util.ArrayList<>();
            for(JSONObject course:Planner.list(before.getJSONArray("courses")))if(Planner.course(state,course.getString("id"))==null)deleted.add(course.getString("id"));
            PlannerBackupRepository.Entry entry=backups.save(before,Planner.now(),deleted.size()==1?"删除课程前":"修改前的日程",deleted.size()==1?deleted.get(0):null);
            l.capture(state);commit(l);
            if(!entry.deletedCourseID.isEmpty())lastDeletedBackup=entry.id;
        }else{l.capture(state);commit(l);}
    }
    public JSONObject update(StateMutation.Change<JSONObject> change)throws Exception{return StateMutation.apply(this,change);}
    public synchronized void commit(SyncLedger l)throws Exception{
        commit(l,true);
    }
    public synchronized void commit(SyncLedger l,boolean enqueueCloud)throws Exception{
        commit(l,enqueueCloud,false);
    }
    synchronized boolean commitCloud(SyncLedger candidate,JSONObject checkpoint,boolean replace)throws Exception{
        if(!SyncLedger.equivalent(checkpoint,metadata()))return false;
        candidate.materialize();
        if(replace){
            try{backups.save(ledger().materialize(),Planner.now(),"云端较新课表覆盖前的手机日程",null);}
            catch(Exception error){throw new IllegalStateException("覆盖前的本机备份未完成，已保留手机课表。请检查可用存储空间后重试。",error);}
        }
        commit(candidate,false,replace);
        return true;
    }
    private void commit(SyncLedger l,boolean enqueueCloud,boolean replace)throws Exception{
        long previous=metadata().optLong("sequence");
        l.materialize();SQLiteDatabase db=getWritableDatabase();db.beginTransaction();try{
            if(replace)db.delete("records",null,null);
            JSONObject rows=l.value.getJSONObject("records");java.util.Iterator<String> it=rows.keys();while(it.hasNext()){String key=it.next();ContentValues v=new ContentValues();v.put("id",key);v.put("body",CourseSourcePrivacy.record(rows.getJSONObject(key)).toString());if(db.insertWithOnConflict("records",null,v,SQLiteDatabase.CONFLICT_REPLACE)<0)throw new android.database.SQLException("记录保存失败");}
            JSONObject meta=l.metadata();ContentValues v=new ContentValues();v.put("id","sync");v.put("body",meta.toString());if(db.insertWithOnConflict("metadata",null,v,SQLiteDatabase.CONFLICT_REPLACE)<0)throw new android.database.SQLException("同步状态保存失败");db.setTransactionSuccessful();
        }finally{db.endTransaction();}
        if(enqueueCloud&&l.sequence()!=previous&&CloudSettings.enabled(context)){
            try{CloudSync.enqueue(context,l);}catch(Exception ignored){} // Committed ledger can rebuild the pending snapshot.
            CloudSync.get(context).request(null);
        }
    }
    public synchronized JSONObject exchange(JSONObject request)throws Exception{
        SyncLedger ledger=ledger();SyncExchange.Result result=SyncExchange.apply(ledger,consumer->{
            JSONArray changes=request.getJSONArray("changes");for(int i=0;i<changes.length();i++)consumer.accept(changes.getJSONObject(i));
            return request;
        },Planner.now());
        commit(ledger);return result.reply.put("changes",ledger.changes(result.after));
    }
    synchronized JSONObject exchange(java.io.File input,java.io.File output,String session)throws Exception{
        SyncLedger ledger=ledger();
        SyncExchange.Result result=SyncExchange.apply(ledger,consumer->{
            try(java.io.Reader reader=new java.io.BufferedReader(new java.io.InputStreamReader(new java.io.FileInputStream(input),java.nio.charset.StandardCharsets.UTF_8))){return SyncJSON.readExchange(reader,consumer);}
        },Planner.now());
        JSONArray changes=ledger.changes(result.after);result.reply.put("session",session).put("changes",changes);
        // Stage a complete response before committing; the disk stream enforces the same total limit.
        try(java.io.Writer out=SyncTransfer.writer(output)){SyncJSON.write(out,result.reply);}
        commit(ledger);
        return result.header.put("applied",result.reply.getString("applied")).put("received",result.received).put("sent",changes.length());
    }
    static void reconcileTasks(SyncLedger ledger,JSONObject state)throws Exception{SyncExchange.reconcileTasks(ledger,state);}
    static void reconcileConfirmations(SyncLedger ledger,JSONObject state)throws Exception{ledger.reconcileConfirmations(state);}
    static boolean needsReplan(JSONObject previous,JSONObject state,double now)throws Exception{return SyncExchange.needsReplan(previous,state,now);}
    public synchronized JSONObject metadata()throws Exception{
        try(Cursor c=getReadableDatabase().rawQuery("SELECT body FROM metadata WHERE id='sync'",null)){
            return c.moveToFirst()?new JSONObject(c.getString(0)):new SyncLedger().metadata();
        }
    }
    public synchronized void finish(boolean auto,String date)throws Exception{
        JSONObject meta=metadata();meta.put("lastSuccess",System.currentTimeMillis()/1000.0);if(auto)meta.put("lastAutoDate",date);
        ContentValues values=new ContentValues();values.put("id","sync");values.put("body",meta.toString());
        if(getWritableDatabase().insertWithOnConflict("metadata",null,values,SQLiteDatabase.CONFLICT_REPLACE)<0)throw new android.database.SQLException("同步状态保存失败");
    }
}
