package local.studyplanner;

import android.widget.Toast;
import org.json.*;
import java.io.File;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.*;

/** Serial journal writes and cancellable projections run away from UI and database workers. */
final class DailyConsequenceController {
    final MainActivity app;final DailyConsequenceRepository repository;
    final ExecutorService worker=Executors.newSingleThreadExecutor();Future<?> task;
    volatile int generation;JSONObject journal,lastState,today,yesterday;LocalDate lastDay;int lastWarning,confirmed;
    boolean loaded,calculating;String message;Set<Integer> celebrations=new HashSet<>();
    DailyConsequenceController(MainActivity app){this.app=app;repository=new DailyConsequenceRepository(new File(app.getFilesDir(),"daily-consequences-v1.json"));}
    int warning(){return app.getPreferences(0).getInt("dailyStudyLoadWarningMinutes",480);}
    void refresh(JSONObject state){
        double now=Planner.now();LocalDate day=Planner.day(now);int warning=warning();
        if(lastState==state&&day.equals(lastDay)&&lastWarning==warning)return;
        lastState=state;lastDay=day;lastWarning=warning;int token=++generation;if(task!=null)task.cancel(true);calculating=true;
        String displayed=today==null?null:today.optString("id");
        task=worker.submit(()->calculate(state,now,warning,token,displayed));
    }
    void calculate(JSONObject state,double now,int warning,int token,String displayed){
        try{
            if(!loaded){try{journal=repository.load();}catch(Exception e){journal=DailyConsequenceRepository.empty();message="预报历史读取失败，暂用临时预报，原记录未覆盖。";}loaded=true;}
            if(cancelled(token))return;
            LocalDate date=Planner.day(now);DailyConsequences.Update update=DailyConsequences.refresh(journal,state,now,warning,displayed);
            JSONObject entry=update.entry;int actual=update.confirmed;Set<Integer> newly=update.celebrations;
            persist();JSONObject previous=find(date.minusDays(1));
            JSONObject reality=previous==null?null:DailyConsequences.reality(previous,state);publish(entry,reality,actual,newly,token,true);
            if(entry.optInt("goalMinutes")>0)for(int fraction:DailyConsequences.fractions(entry)){
                if(cancelled(token))return;boolean exists=false;for(JSONObject f:Planner.list(entry.getJSONArray("forecasts")))if(f.optInt("fraction")==fraction)exists=true;if(exists)continue;
                JSONObject forecast=DailyConsequences.forecast(entry,fraction,90);if(cancelled(token))return;
                entry.getJSONArray("forecasts").put(forecast);persist();publish(entry,reality,actual,Collections.emptySet(),token,true);
            }
            publish(entry,reality,actual,Collections.emptySet(),token,false);
        }catch(InterruptedException ignored){Thread.currentThread().interrupt();}
        catch(Exception e){app.runOnUiThread(()->{if(cancelled(token)||app.isDestroyed())return;calculating=false;message="预报暂未完成，可点击重新核算重试。";if(app.page==4)new DailyConsequencesView(app).render(app.consequencePanel);});}
    }
    boolean cancelled(int token){return token!=generation||Thread.currentThread().isInterrupted();}
    JSONObject find(LocalDate day){return DailyConsequences.find(journal,day);}
    void persist(){if(repository.writeDisabled)return;try{repository.save(journal);message=null;}catch(Exception e){message="预报历史未能保存；本次结果仍可查看，重开后的达标状态需要重新核对。";}}
    void publish(JSONObject entry,JSONObject reality,int actual,Set<Integer> newly,int token,boolean running)throws Exception{
        JSONObject snapshot=CourseTools.copy(entry),past=reality==null?null:CourseTools.copy(reality);String storageMessage=message;
        app.runOnUiThread(()->{if(token!=generation||app.isDestroyed())return;if(today==null||!today.optString("id").equals(snapshot.optString("id")))celebrations.clear();today=snapshot;yesterday=past;confirmed=actual;calculating=running;message=storageMessage;
            celebrations.addAll(newly);if(!newly.isEmpty())Toast.makeText(app,newly.contains(1000)?"今日学习目标已完成！":"已超过 "+newly.size()+" 档少学情形，继续保持",Toast.LENGTH_SHORT).show();
            if(app.page==4)new DailyConsequencesView(app).render(app.consequencePanel);});
    }
    void markYesterdayReviewed(){
        JSONObject state=app.state;int token=++generation;if(task!=null)task.cancel(true);lastState=null;
        task=worker.submit(()->{try{JSONObject entry=find(Planner.day(Planner.now()).minusDays(1));if(entry==null)return;JSONObject value=DailyConsequences.reality(entry,state);
            if(value.optBoolean("pending")||value.optInt("ambiguousRecords")>0)return;entry.put("reviewedAt",Planner.now());persist();
            app.runOnUiThread(()->{if(token==generation&&!app.isDestroyed())app.render();});}catch(Exception e){app.runOnUiThread(()->app.alert("核对未保存","请稍后重试。"));}});
    }
    void close(){generation++;if(task!=null)task.cancel(true);worker.shutdownNow();}
}
