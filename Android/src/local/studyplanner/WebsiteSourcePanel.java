package local.studyplanner;

import android.app.*;
import android.content.Intent;
import android.text.InputType;
import android.view.WindowManager;
import android.widget.*;
import org.json.*;

final class WebsiteSourcePanel {
    static boolean supported(JSONObject course){JSONObject web=course.optJSONObject("webCourse");return web!=null&&!WebsiteUpdatePolicy.site(web.optString("sourceURL")).isEmpty()&&course.optJSONArray("mergedSources")==null;}
    static void show(MainActivity app,JSONObject displayed){
        BackupPanel.load(app,()->WebsiteSourceSettings.get(app,displayed.getString("id")),source->app.run(()->{
            LinearLayout form=app.col();form.setPadding(app.dp(16),0,app.dp(16),app.dp(16));
            EditText url=app.field(form,"课程来源网址",source.optString("url",WebsiteUpdatePolicy.suggested(displayed)),false);
            CheckBox enabled=new CheckBox(app);enabled.setText("允许自动更新这门课程");enabled.setChecked(source.optBoolean("enabled"));form.addView(enabled);
            int[] intervals={30,60,180,360};int selected=1;for(int i=0;i<intervals.length;i++)if(intervals[i]==source.optInt("interval",60))selected=i;
            Spinner interval=app.spinner(form,"更新间隔",new String[]{"30分钟","60分钟","180分钟","360分钟"},selected);
            form.addView(app.text(source.optString("status","尚未更新"),14,app.muted));
            form.addView(app.text("自动更新补充课节与网站进度，保留学习记录和手动顺序。省电或强制停止可能延后后台检查。需要验证码或协议确认时暂停，请打开更新窗口处理。账号和设置仅存于本机。",13,app.muted));
            form.addView(app.button("管理网站账号",()->account(app,WebsiteUpdatePolicy.site(displayed.optJSONObject("webCourse").optString("sourceURL")))));
            AlertDialog dialog=app.editor("网站来源与更新",form);
            java.util.function.Consumer<Boolean> save=open->app.run(()->{
                String target=WebsiteUpdatePolicy.sourceURL(app.value(url),displayed);boolean on=enabled.isChecked();int minutes=intervals[interval.getSelectedItemPosition()];
                BackupPanel.load(app,()->{
                    JSONObject current=Planner.course(app.database.load(),displayed.getString("id"));if(current==null)throw new IllegalArgumentException("课程已删除。");WebsiteUpdatePolicy.sourceURL(target,current);
                    JSONObject next=WebsiteSourceSettings.get(app,current.getString("id"));next.put("url",target).put("enabled",on).put("interval",minutes).put("revision",Planner.id());
                    WebsiteSourceSettings.put(app,current.getString("id"),next);return current.getString("id");
                },id->{WebsiteUpdates.schedule(app);dialog.dismiss();if(open)app.startActivity(new Intent(app,WebsiteUpdateActivity.class).putExtra("courseID",id));else WebsiteUpdates.due(app,()->{});});
            });
            form.addView(app.button("立即更新／处理登录",()->save.accept(true)));
            dialog.setOnShowListener(d->dialog.getButton(-1).setOnClickListener(v->save.accept(false)));dialog.show();
        }));
    }
    static void account(MainActivity app,String site){
        LinearLayout form=app.col();form.setPadding(app.dp(16),0,app.dp(16),app.dp(16));
        form.addView(app.text("账号密码通过 Android Keystore 加密保存，不进入课表同步或备份。只在此网站需要登录时填写；验证码与协议确认由你完成。",13,app.muted));
        EditText username=app.field(form,"新账号","",false),password=app.field(form,"新密码","",false);password.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);
        username.setSaveEnabled(false);password.setSaveEnabled(false);
        if(android.os.Build.VERSION.SDK_INT>=26){username.setImportantForAutofill(android.view.View.IMPORTANT_FOR_AUTOFILL_NO);password.setImportantForAutofill(android.view.View.IMPORTANT_FOR_AUTOFILL_NO);}
        AlertDialog dialog=app.editor("网站账号",form);form.addView(app.button("移除已保存账号",()->new AlertDialog.Builder(app).setTitle("移除本机账号？").setNegativeButton("取消",null).setPositiveButton("移除",(d,w)->BackupPanel.load(app,()->{WebsiteSourceSettings.forget(app,site);return true;},ok->dialog.dismiss())).show()));
        dialog.setOnShowListener(d->dialog.getButton(-1).setOnClickListener(v->{String user=app.value(username),secret=password.getText().toString();BackupPanel.load(app,()->{WebsiteSourceSettings.saveCredentials(app,site,user,secret);return true;},ok->{username.setText("");password.setText("");dialog.dismiss();});}));
        dialog.show();dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
}
