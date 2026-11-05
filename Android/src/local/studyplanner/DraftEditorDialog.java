package local.studyplanner;

import android.app.AlertDialog;
import android.content.DialogInterface;
import android.view.View;
import android.view.ViewGroup;
import android.widget.*;
import java.util.*;

/** Protect raw course/event form input; successful saves still dismiss directly. */
final class DraftEditorDialog extends AlertDialog {
    private final MainActivity app;
    private LinearLayout form;
    private final ScrollView scroll;
    private DialogInterface.OnShowListener showListener;
    static volatile int openCount;
    private static final Set<DraftEditorDialog> open=new HashSet<>();
    private boolean counted;
    private List<String> baseline;
    private AlertDialog discard;

    DraftEditorDialog(MainActivity app,String title,LinearLayout form){
        super(app);this.app=app;this.form=form;
        scroll=new ScrollView(app);form.setPadding(app.dp(22),app.dp(8),app.dp(22),app.dp(24));scroll.addView(form);
        setTitle(title);setView(scroll);
        setButton(BUTTON_NEGATIVE,"取消",(DialogInterface.OnClickListener)null);
        setButton(BUTTON_POSITIVE,"保存",(DialogInterface.OnClickListener)null);
        setCanceledOnTouchOutside(false);
    }
    static DraftEditorDialog obtain(MainActivity app,String title,LinearLayout form,DraftEditorDialog existing){
        if(existing==null)return new DraftEditorDialog(app,title,form);
        existing.scroll.removeAllViews();existing.form=form;form.setPadding(app.dp(22),app.dp(8),app.dp(22),app.dp(24));existing.scroll.addView(form);existing.baseline=null;existing.setTitle(title);return existing;
    }
    @Override public void setOnShowListener(DialogInterface.OnShowListener listener){showListener=listener;super.setOnShowListener(listener);}
    @Override public void show(){boolean showing=isShowing();super.show();if(!counted){counted=true;open.add(this);openCount=open.size();}if(showing&&showListener!=null)showListener.onShow(this);baseline=snapshot();}
    static void closeFor(MainActivity app){for(DraftEditorDialog dialog:new ArrayList<>(open))if(dialog.app==app)dialog.dismiss();}
    @Override protected void onStart(){
        super.onStart();
        if(baseline==null)baseline=snapshot();
        getButton(BUTTON_NEGATIVE).setOnClickListener(view->requestClose());
    }
    // Both legacy back and the system's predictive-back cancellation reach cancel().
    @Override public void cancel(){requestClose();}

    private void requestClose(){
        if(app.busy){Toast.makeText(app,"正在保存，请稍后",Toast.LENGTH_SHORT).show();return;}
        if(baseline==null||baseline.equals(snapshot())){dismiss();return;}
        if(discard!=null&&discard.isShowing())return;
        discard=new AlertDialog.Builder(app).setTitle("放弃未保存的修改？")
            .setMessage("当前输入尚未保存，关闭后将丢失。")
            .setNegativeButton("继续编辑",null)
            .setPositiveButton("放弃修改",(dialog,which)->{
                if(app.busy)Toast.makeText(app,"正在保存，请稍后",Toast.LENGTH_SHORT).show();
                else dismiss();
            }).create();
        discard.setOnDismissListener(dialog->discard=null);discard.show();
    }
    @Override public void dismiss(){
        if(discard!=null){AlertDialog prompt=discard;discard=null;prompt.dismiss();}
        if(counted){counted=false;open.remove(this);openCount=open.size();}
        super.dismiss();
    }
    private List<String> snapshot(){
        List<String> values=new ArrayList<>();capture(form,values);return values;
    }
    private static void capture(View view,List<String> values){
        // Compare raw text so incomplete/invalid values are protected too.
        if(view instanceof EditText)values.add("text:"+((EditText)view).getText());
        else if(view instanceof CompoundButton)values.add("checked:"+((CompoundButton)view).isChecked());
        else if(view instanceof Spinner)values.add("selected:"+((Spinner)view).getSelectedItemPosition());
        else if(view instanceof ViewGroup){ViewGroup group=(ViewGroup)view;for(int i=0;i<group.getChildCount();i++)capture(group.getChildAt(i),values);}
    }
}
