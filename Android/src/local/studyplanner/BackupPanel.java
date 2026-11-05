package local.studyplanner;

import android.app.*;
import android.widget.*;
import org.json.*;
import java.util.*;

final class BackupPanel {
    static void controls(MainActivity app,LinearLayout parent){
        parent.addView(app.text("每次本机修改前自动备份，保留最近20份可读记录。可恢复全部日程或单独恢复已删除课程。备份不含账号、密码和同步凭据。",13,app.muted));
        parent.addView(app.button("立即备份",()->load(app,()->{app.database.backups.save(app.database.load(),Planner.now(),"手动备份",null);return null;},value->show(app))));
        parent.addView(app.button("最近的自动与手动备份",()->show(app)));
    }
    interface Read<T>{T run()throws Exception;}
    static <T> void load(MainActivity app,Read<T> read,java.util.function.Consumer<T> done){
        if(app.busy||!app.ready||app.isDestroyed())return;
        app.busy=true;ProgressDialog progress=ProgressDialog.show(app,"","正在处理本机数据…",true,false);
        app.worker.execute(()->{try{T result=read.run();app.runOnUiThread(()->{
            app.busy=false;progress.dismiss();if(app.isDestroyed())return;done.accept(result);app.resumeSyncRefresh();
        });}catch(Exception error){app.runOnUiThread(()->{app.busy=false;progress.dismiss();if(!app.isDestroyed()){app.alert("操作未完成",error.getMessage());app.resumeSyncRefresh();}});}});
    }
    static void show(MainActivity app){load(app,()->app.database.backups.entries(),entries->{
        LinearLayout form=app.col();form.setPadding(app.dp(16),0,app.dp(16),app.dp(12));
        if(entries.isEmpty())form.addView(app.text("暂时没有备份。",14,app.muted));
        if(app.database.backups.unreadable>0)form.addView(app.text(app.database.backups.unreadable+" 份备份无法读取，原文件已保留。",14,app.muted));
        ScrollView scroll=new ScrollView(app);scroll.addView(form);
        AlertDialog dialog=new AlertDialog.Builder(app).setTitle("本机备份").setView(scroll).setNegativeButton("关闭",null).create();
        for(PlannerBackupRepository.Entry entry:entries){
            LinearLayout box=app.card(form);box.addView(app.text(entry.summary,14,app.ink));
            box.addView(app.button("恢复全部…",()->load(app,()->new PlannerBackupFile.Restore(app.database.backups.load(entry.id),app.database.load()),review->{dialog.dismiss();app.showBackupRestore(review);})));
            if(!entry.deletedCourseID.isEmpty()&&Planner.course(app.state,entry.deletedCourseID)==null)
                box.addView(app.button("恢复课程："+entry.deletedCourseName,()->restoreCourse(app,entry.id,dialog::dismiss)));
        }
        dialog.show();
    });}
    static void restoreCourse(MainActivity app,String id,Runnable done){
        load(app,()->app.database.backups.load(id),backup->new AlertDialog.Builder(app).setTitle("恢复已删除课程？")
            .setMessage("恢复该课程和学习记录，按当前条件重新排课；保留其他课程的新修改。开启云同步时也会同步此次恢复。")
            .setNegativeButton("取消",null).setPositiveButton("恢复",(d,w)->app.mutate(s->PlannerBackupRepository.restoreCourse(s,backup),true,()->{app.database.lastDeletedBackup=null;if(done!=null)done.run();})).show());
    }
}
