package local.studyplanner;

import android.content.Intent;
import android.net.Uri;
import android.text.*;
import android.view.View;
import android.widget.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

final class CloudSettingsPanel {
    final MainActivity app;
    String method,importedKey="";
    final LinearLayout box,httpsFields,sshFields,httpsCard,sshCard;
    final EditText endpoint,httpsToken,host,port,user,fingerprint,passphrase,sshToken;
    final TextView keyLabel;
    final CheckBox enabled,trusted;
    boolean reading=false;
    static void render(MainActivity app,LinearLayout parent){
        // Network/resume refreshes rebuild the page. Retain unsaved fields and the imported key
        // in this Activity's memory, never in a Bundle or plaintext preferences.
        if(app.cloudPanel!=null){
            LinearLayout box=app.cloudPanel.box;
            android.view.ViewGroup previous=(android.view.ViewGroup)box.getParent();if(previous!=null)previous.removeView(box);
            parent.addView(box);if(app.cloudLabel!=null)app.cloudLabel.setText(CloudSync.summary(app));return;
        }
        app.cloudPanel=new CloudSettingsPanel(app,parent);
    }
    CloudSettingsPanel(MainActivity app,LinearLayout parent){
        this.app=app;method=CloudSettings.method(app);
        box=app.card(parent);box.addView(app.title("云端同步"));
        enabled=new CheckBox(app);enabled.setText("启用云同步");enabled.setChecked(CloudSettings.enabled(app));box.addView(enabled);
        LinearLayout choices=app.row();box.addView(choices);
        httpsCard=choice(choices,"HTTPS 直连","已有 HTTPS 地址","https");sshCard=choice(choices,"SSH 密钥","使用服务器登录密钥","ssh");
        httpsFields=app.col();box.addView(httpsFields);
        endpoint=app.field(httpsFields,"HTTPS 服务器地址（支持公网 IP）",CloudSettings.endpoint(app),false);
        endpoint.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_URI);
        httpsToken=secret(httpsFields,"服务访问码（留空沿用此方式已保存的值）");
        sshFields=app.col();box.addView(sshFields);
        host=app.field(sshFields,"服务器 IP 或主机名",CloudSettings.field(app,"host",""),false);
        port=app.field(sshFields,"SSH 端口",CloudSettings.field(app,"port","22"),true);
        user=app.field(sshFields,"登录用户名",CloudSettings.field(app,"user",""),false);
        keyLabel=app.text(app.getSharedPreferences(CloudSettings.PREFS,0).contains("ssh.key")?"已安全保存私钥":"尚未导入私钥",13,app.muted);
        sshFields.addView(app.button("导入私钥文件",()->{
            Intent picker=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE);
            app.startActivityForResult(picker,MainActivity.IMPORT_SSH_KEY);
        }));sshFields.addView(keyLabel);
        passphrase=secret(sshFields,"私钥口令（未设口令则留空）");
        fingerprint=app.field(sshFields,"服务器指纹（SHA256:…）",CloudSettings.field(app,"fingerprint",""),false);
        fingerprint.setSingleLine(false);
        sshFields.addView(app.button("读取服务器指纹",this::readFingerprint));
        trusted=new CheckBox(app);trusted.setText("已向服务器主人核对上述指纹");trusted.setChecked(!app.value(fingerprint).isEmpty());sshFields.addView(trusted);
        TextWatcher invalidate=new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){trusted.setChecked(false);}public void afterTextChanged(Editable s){}};
        host.addTextChangedListener(invalidate);port.addTextChangedListener(invalidate);fingerprint.addTextChangedListener(invalidate);
        sshToken=secret(sshFields,"服务访问码（留空沿用 SSH 方式已保存的值）");
        sshFields.addView(app.text("密钥用于 SSH 登录；服务访问码用于日程同步，两者不同。连接后访问服务器内部的18090端口，无需安装组网软件。",13,app.muted));
        app.cloudLabel=app.text(CloudSync.summary(app),13,app.muted);box.addView(app.cloudLabel);
        box.addView(app.text("两种方式分别保存配置，点击保存后生效。完整课表按记录修改时间合并，保留最近十版；修改、打开和恢复联网时同步，后台约每小时检查，可能因系统省电延迟。",13,app.muted));
        box.addView(app.button("保存云同步配置",()->app.run(this::save)));
        box.addView(app.button("立即云同步",()->{
            if(!CloudSettings.enabled(app)){app.alert("云端同步","请先保存并启用云同步配置");return;}
            if(!enabled.isChecked()||!method.equals(CloudSettings.method(app))){app.alert("云端同步","请先保存所选的连接方式");return;}
            CloudSync.get(app).request(null);if(app.cloudLabel!=null)app.cloudLabel.setText("正在同步完整课表…");
        }));updateSelection();
    }
    EditText secret(LinearLayout parent,String label){
        EditText field=app.field(parent,label,"",false);field.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);
        field.setSaveEnabled(false);field.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);return field;
    }
    LinearLayout choice(LinearLayout parent,String title,String detail,String value){
        LinearLayout card=app.card(parent);LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(0,-2,1);
        params.setMargins(app.dp(3),app.dp(8),app.dp(3),app.dp(8));card.setLayoutParams(params);
        card.addView(app.text(title,16,app.ink));card.addView(app.text(detail,12,app.muted));card.setMinimumHeight(app.dp(110));
        card.setFocusable(true);card.setOnClickListener(v->{method=value;updateSelection();});return card;
    }
    void updateSelection(){
        boolean ssh="ssh".equals(method);httpsFields.setVisibility(ssh?View.GONE:View.VISIBLE);sshFields.setVisibility(ssh?View.VISIBLE:View.GONE);
        for(LinearLayout card:new LinearLayout[]{httpsCard,sshCard}){
            boolean active=card==(ssh?sshCard:httpsCard);card.setSelected(active);
            card.setBackground(app.rounded(active?0xffe8f6ee:0xfff7f7f7,12));if(active)app.cardBorder(card,app.blue);
        }
        httpsCard.setContentDescription("HTTPS 直连"+(!ssh?"，已选中":"，点击切换"));sshCard.setContentDescription("SSH 密钥"+(ssh?"，已选中":"，点击切换"));
    }
    void importKey(Uri uri)throws Exception{
        String key;
        try(InputStream raw=app.getContentResolver().openInputStream(uri);InputStream in=new CloudSnapshot.LimitedInput(raw,65536);ByteArrayOutputStream out=new ByteArrayOutputStream()){
            byte[] buffer=new byte[4096];for(int n;(n=in.read(buffer))!=-1;)out.write(buffer,0,n);key=new String(out.toByteArray(),StandardCharsets.UTF_8);
        }
        if(!key.contains("PRIVATE KEY-----")||!key.contains("-----END "))throw new Exception("请选择 SSH 私钥文件，而非公钥");
        importedKey=key;passphrase.setText("");keyLabel.setText("已选择新私钥，保存后生效");
    }
    void readFingerprint(){
        if(reading)return;final String target=app.value(host),targetPort=app.value(port);final int number;
        try{CloudSSHConfig.validateHost(target);number=Integer.parseInt(targetPort);CloudSSHConfig.validatePort(number);}catch(Exception e){app.alert("读取服务器指纹","请检查服务器地址和 SSH 端口");return;}
        reading=true;keyLabel.setText("正在读取服务器指纹…");
        app.worker.execute(()->{
            try{String candidate=CloudSSHTunnel.readFingerprint(target,number);app.runOnUiThread(()->{
                if(!app.isDestroyed()&&app.cloudPanel==this&&target.equals(app.value(host))&&targetPort.equals(app.value(port))){fingerprint.setText(candidate);trusted.setChecked(false);app.alert("请核对服务器指纹","请与服务器主人提供的指纹比较，一致后勾选确认并保存。");}
            });}catch(Exception e){app.runOnUiThread(()->{if(!app.isDestroyed())app.alert("读取服务器指纹","读取失败，请检查地址、端口及网络");});}
            finally{app.runOnUiThread(()->{reading=false;if(!app.isDestroyed())keyLabel.setText(importedKey.isEmpty()?(app.getSharedPreferences(CloudSettings.PREFS,0).contains("ssh.key")?"已安全保存私钥":"尚未导入私钥"):"已选择新私钥，保存后生效");});}
        });
    }
    void save()throws Exception{
        if(reading)throw new Exception("正在读取指纹，请稍后保存");
        if(CloudSync.get(app).isRunning())throw new Exception("正在同步，请完成后再修改服务器配置");
        if("ssh".equals(method)){
            if(enabled.isChecked()&&!trusted.isChecked())throw new Exception("请先向服务器主人核对指纹，再勾选确认");
            CloudSettings.saveSSH(app,app.value(host),app.value(port),app.value(user),app.value(fingerprint),importedKey,app.value(passphrase),app.value(sshToken),enabled.isChecked());
            if(enabled.isChecked()){importedKey="";keyLabel.setText("已安全保存私钥");}
        }else CloudSettings.save(app,app.value(endpoint),app.value(httpsToken),enabled.isChecked());
        httpsToken.setText("");sshToken.setText("");passphrase.setText("");
        app.worker.execute(()->{try{
            synchronized(app.database){SyncLedger ledger=app.database.ledger();ledger.value.remove("cloudProgress");app.database.commit(ledger,false);}
            app.runOnUiThread(()->{if(app.cloudLabel!=null)app.cloudLabel.setText(CloudSettings.enabled(app)?"配置已保存，准备同步":"云同步已暂停，待上传文件已保留");});
            CloudSync.get(app).start();
        }catch(Exception e){app.runOnUiThread(()->app.alert("云同步配置","配置已保存，重置同步状态失败，请重试"));}});
    }
}
