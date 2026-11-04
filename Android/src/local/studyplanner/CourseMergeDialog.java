package local.studyplanner;

import android.app.*;
import android.text.*;
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
    private final EditText name, query;
    private final CheckBox selectedOnly;
    private final TextView status;
    private final AlertDialog dialog;
    private final Button previous, next;
    private final LatestWork<Result> work;
    private Source source;
    private Result result;
    private Runnable pending;
    private int page;
    private String notice="请核对所选课程；同步后可重新核对。";

    // The index is initialized only on the serial worker; displayed rows are read-only.
    private static final class Source {
        final JSONObject state;
        CourseCatalog catalog;
        final Map<String,JSONObject> courses=new HashMap<>();
        Source(JSONObject state){this.state=state;}
        Result find(String query,int page,Set<String> selected){
            if(catalog==null){
                catalog=new CourseCatalog(state);
                for(JSONObject course:Planner.list(state.optJSONArray("courses")))courses.put(course.optString("id"),course);
            }
            return new Result(this,selected==null?catalog.find(query,page):catalog.findSelected(query,selected,page));
        }
    }
    private static final class Result {
        final Source source;final CourseCatalog.Page page;
        Result(Source source,CourseCatalog.Page page){this.source=source;this.page=page;}
    }

    CourseMergeDialog(MainActivity app) throws Exception {
        this.app=app;features=new PlannerFeatures(app);reviewed=app.state;source=new Source(reviewed);
        if(CourseMergeDraft.availableIDs(reviewed).size()<2)throw new IllegalArgumentException("请先添加至少两门课程。");
        LinearLayout form=app.col();name=app.field(form,"合并后的课程名称","合并课程",false);
        status=app.text("",13,app.muted);form.addView(status);
        form.addView(app.button("重新核对课程",this::refresh));
        query=app.field(form,"搜索课程名称、备注或截止日期","",false);
        selectedOnly=new CheckBox(app);selectedOnly.setText("只看已选课程");form.addView(selectedOnly);
        PlannerUi.Flow navigation=new PlannerUi.Flow(app);form.addView(navigation);
        previous=app.button("上一页",()->{page--;load();});next=app.button("下一页",()->{page++;load();});
        navigation.addView(previous);navigation.addView(next);
        navigation.addView(app.button("清除筛选",()->{selectedOnly.setChecked(false);query.setText("");page=0;load();}));
        navigation.addView(app.button("取消全部选择",()->{selected.clear();page=0;load();}));
        rows=app.col();form.addView(rows);
        form.addView(app.text("每页最多 20 门，按截止日期排列。搜索和翻页保留已选课程；保存合并全部已选课程，可用「只看已选课程」逐页核对。",12,app.muted));
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
        work=new LatestWork<>(app.worker,app::runOnUiThread,value->{
            if(app.isDestroyed()||!dialog.isShowing()||value.source!=source)return;
            result=value;page=value.page.index;render();
        },error->{if(!app.isDestroyed()&&dialog.isShowing())status.setText("读取课程失败："+error.getMessage()+"\n名称和选择仍保留，可重新核对课程。");});
        query.addTextChangedListener(new TextWatcher(){
            public void beforeTextChanged(CharSequence s,int start,int count,int after){}
            public void onTextChanged(CharSequence s,int start,int before,int count){page=0;load();}
            public void afterTextChanged(Editable value){}
        });
        selectedOnly.setOnCheckedChangeListener((button,checked)->{page=0;load();});
        dialog.setOnDismissListener(view->{work.close();if(pending!=null)app.handler.removeCallbacks(pending);});
        dialog.show();load();
    }
    private void updateStatus(){
        String position=result==null?"正在读取课程…":result.page.count==0?"当前筛选没有课程":
            "匹配 "+result.page.count+" 门 · 第 "+(result.page.index+1)+" / "+result.page.pageCount+" 页";
        status.setText(notice+"\n"+position+"；合计已选 "+selected.size()+" 门。");
    }
    private void load(){
        if(pending!=null)app.handler.removeCallbacks(pending);work.clear();result=null;rows.removeAllViews();
        previous.setEnabled(false);next.setEnabled(false);updateStatus();
        final Source captured=source;final String term=query.getText().toString();final int requested=page;
        final Set<String> ids=selectedOnly.isChecked()?new HashSet<>(selected):null;
        pending=()->work.submit(()->captured.find(term,requested,ids));app.handler.postDelayed(pending,200);
    }
    private void render(){
        rows.removeAllViews();updateStatus();
        previous.setEnabled(result.page.index>0);next.setEnabled(result.page.index+1<result.page.pageCount);
        for(CourseCatalog.Row row:result.page.rows){
            JSONObject course=result.source.courses.get(row.id);String id=row.id;CheckBox choice=new CheckBox(app);
            choice.setText(course.optString("name")+" · 剩余 "+app.hours(Math.max(0,course.optInt("totalMinutes")-row.completedMinutes))+" · 截止 "+Planner.date(course.optDouble("deadline")));
            choice.setChecked(selected.contains(id));choice.setOnCheckedChangeListener((button,checked)->{
                if(checked)selected.add(id);else selected.remove(id);
                if(selectedOnly.isChecked())load();else updateStatus();
            });rows.addView(choice);
        }
        query.requestRectangleOnScreen(new android.graphics.Rect(0,0,query.getWidth(),query.getHeight()),true);
    }
    private void refresh(){
        if(app.busy)return;app.busy=true;
        ProgressDialog progress=ProgressDialog.show(app,"","正在读取最新课程和学习记录…",true,false);
        app.worker.execute(()->{try{
            JSONObject latest=app.database.load();
            app.runOnUiThread(()->{
                app.busy=false;progress.dismiss();if(app.isDestroyed())return;
                if(dialog.isShowing())app.run(()->{
                    int removed=CourseMergeDraft.retainSelection(selected,latest);reviewed=latest;source=new Source(latest);
                    notice=removed==0?"已更新，请核对最新名称、进度和截止日期。":"已更新；"+removed+" 门课程已删除或归档，已取消选择。";
                    load();
                });
                app.refreshSyncData();
            });
        }catch(Exception error){app.runOnUiThread(()->{
            app.busy=false;progress.dismiss();if(app.isDestroyed())return;
            app.alert("课程未刷新",error.getMessage()+"\n原选择和名称仍保留。");app.resumeSyncRefresh();
        });}});
    }
}
