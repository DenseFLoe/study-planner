package local.studyplanner;

import android.app.*;
import android.widget.*;
import org.json.*;
import java.util.*;

/** Refresh the reviewed rows without discarding the user's chosen sources or title. */
final class CourseMergeDialog {
    private final MainActivity app;
    private final PlannerFeatures features;
    private final Set<String> selected=new HashSet<>();
    private JSONObject reviewed;
    private final LinearLayout rows;
    private final EditText name;
    private final TextView status;
    private final AlertDialog dialog;

    CourseMergeDialog(MainActivity app) throws Exception {
        this.app=app;features=new PlannerFeatures(app);reviewed=app.state;
        if(CourseMergeDraft.availableIDs(reviewed).size()<2)throw new IllegalArgumentException("请先添加至少两门课程。");
        LinearLayout form=app.col();name=app.field(form,"合并后的课程名称","合并课程",false);
        status=app.text("",13,app.muted);form.addView(status);
        form.addView(app.button("重新核对课程",this::refresh));rows=app.col();form.addView(rows);
        form.addView(app.text("采用最早开始日和截止日；来源、课节和完成记录迁入合并课程。重新核对保留名称和仍存在的选择，已删除或归档的课程会取消选择。",12,app.muted));
        form.addView(app.button("预览合并后的编排",()->{
            final JSONObject baseline=reviewed;final Set<String> ids=new HashSet<>(selected);final String title=app.value(name);
            features.preview(next->new CourseMergeDraft(baseline,ids,title).apply(next).getString("id"));
        }));
        dialog=app.editor("合并课程",form);
        dialog.setOnShowListener(view->dialog.getButton(-1).setOnClickListener(button->{
            final JSONObject baseline=reviewed;final Set<String> ids=new HashSet<>(selected);final String title=app.value(name);
            app.mutate(next->new CourseMergeDraft(baseline,ids,title).apply(next),true,dialog::dismiss);
        }));
        render("请核对所选课程；同步后可重新核对。");dialog.show();
    }
    private void render(String message) throws Exception {
        rows.removeAllViews();List<JSONObject> courses=Planner.list(reviewed.getJSONArray("courses"));
        courses.removeIf(course->course.optBoolean("isArchived"));
        courses.sort((a,b)->{int order=CourseTools.natural(a.optString("name"),b.optString("name"));return order!=0?order:a.optString("id").compareTo(b.optString("id"));});
        status.setText(message+"\n共 "+courses.size()+" 门课程；当前选择 "+selected.size()+" 门。");
        for(JSONObject course:courses){
            String id=course.getString("id");CheckBox choice=new CheckBox(app);
            choice.setText(course.getString("name")+" · 剩余 "+app.hours(Planner.remaining(reviewed,course))+" · 截止 "+Planner.date(course.getDouble("deadline")));
            choice.setChecked(selected.contains(id));choice.setOnCheckedChangeListener((button,checked)->{
                if(checked)selected.add(id);else selected.remove(id);
                status.setText("已核对 "+courses.size()+" 门课程；当前选择 "+selected.size()+" 门。");
            });rows.addView(choice);
        }
    }
    private void refresh(){
        if(app.busy)return;app.busy=true;
        ProgressDialog progress=ProgressDialog.show(app,"","正在读取最新课程和学习记录…",true,false);
        app.worker.execute(()->{try{
            JSONObject latest=app.database.load();
            app.runOnUiThread(()->{
                app.busy=false;progress.dismiss();if(app.isDestroyed())return;
                if(dialog.isShowing())app.run(()->{
                    int removed=CourseMergeDraft.retainSelection(selected,latest);reviewed=latest;
                    render(removed==0?"已更新，请核对最新名称、进度和截止日期。":"已更新；"+removed+" 门课程已删除或归档，已取消选择。");
                });
                app.refreshSyncData();
            });
        }catch(Exception error){app.runOnUiThread(()->{
            app.busy=false;progress.dismiss();if(app.isDestroyed())return;
            app.alert("课程未刷新",error.getMessage()+"\n原选择和名称仍保留。");app.resumeSyncRefresh();
        });}});
    }
}
