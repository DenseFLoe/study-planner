package local.studyplanner;
import android.text.InputType;
import android.widget.*;

final class CloudSettingsPanel {
    static void render(MainActivity app){
        LinearLayout box=app.card(app.body);box.addView(app.title("云端同步"));
        CheckBox enabled=new CheckBox(app);enabled.setText("启用云同步");enabled.setChecked(CloudSettings.enabled(app));box.addView(enabled);
        EditText endpoint=app.field(box,"HTTPS 服务器地址（支持公网 IP）",CloudSettings.endpoint(app),false);
        endpoint.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_URI);
        EditText token=app.field(box,"服务访问码（留空沿用已保存的访问码）","",false);
        token.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);token.setSaveEnabled(false);
        app.cloudLabel=app.text(CloudSync.summary(app),13,app.muted);box.addView(app.cloudLabel);
        box.addView(app.text("上传完整压缩课表，由服务器按记录操作时间合并，保留最近十版。打开、修改及恢复联网时同步，后台约每小时检查，可能因系统省电而延迟。尚未部署服务器时保持关闭。访问码不是 SSH 密钥。",13,app.muted));
        box.addView(app.button("保存云同步配置",()->app.run(()->{
            if(CloudSync.get(app).isRunning())throw new Exception("正在同步，请完成后再修改服务器配置");
            CloudSettings.save(app,app.value(endpoint),app.value(token),enabled.isChecked());token.setText("");
            app.worker.execute(()->{try{
                synchronized(app.database){SyncLedger ledger=app.database.ledger();ledger.value.remove("cloudProgress");app.database.commit(ledger,false);}
                CloudSync.get(app).start();app.runOnUiThread(()->{if(app.cloudLabel!=null)app.cloudLabel.setText(CloudSettings.enabled(app)?"配置已保存，准备同步":"云同步已暂停，待上传文件已保留");});
            }catch(Exception e){app.runOnUiThread(()->app.alert("云同步配置", "配置已保存，重置同步状态失败，请重试"));}});
        })));
        box.addView(app.button("立即云同步",()->{
            if(!CloudSettings.enabled(app)){app.alert("云端同步","请先保存并启用云同步配置");return;}
            CloudSync.get(app).request(null);if(app.cloudLabel!=null)app.cloudLabel.setText("正在同步完整课表…");
        }));
    }
}
