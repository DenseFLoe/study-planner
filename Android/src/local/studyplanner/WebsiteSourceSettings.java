package local.studyplanner;

import android.content.*;
import android.security.keystore.*;
import android.util.Base64;
import org.json.*;
import java.security.KeyStore;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import java.util.*;

/** Local opt-in sources and separately encrypted account records; never part of business state. */
final class WebsiteSourceSettings {
    static final String PREFS="website-update-sources",ACCOUNTS="website-update-accounts",ALIAS="local.studyplanner.website";
    static JSONObject get(Context c,String id)throws Exception{return new JSONObject(c.getSharedPreferences(PREFS,0).getString(id,"{}"));}
    static void put(Context c,String id,JSONObject value)throws Exception{if(!c.getSharedPreferences(PREFS,0).edit().putString(id,value.toString()).commit())throw new Exception("网站更新设置未保存。");}
    static List<String> due(Context c)throws Exception{
        List<String> ids=new ArrayList<>();long now=System.currentTimeMillis();
        for(String id:c.getSharedPreferences(PREFS,0).getAll().keySet()){
            JSONObject source=get(c,id);if(source.optBoolean("enabled")&&!source.optBoolean("needsAttention")&&now-source.optLong("lastAttempt")>=source.optInt("interval",60)*60000L)ids.add(id);
        }Collections.sort(ids);return ids;
    }
    static void status(Context c,String id,String status,boolean attention)throws Exception{JSONObject source=get(c,id);source.put("status",status).put("needsAttention",attention);put(c,id,source);}
    static void pauseSite(Context c,String site)throws Exception{
        for(String id:c.getSharedPreferences(PREFS,0).getAll().keySet()){JSONObject source=get(c,id);if(site.equals(WebsiteUpdatePolicy.site(source.optString("url")))){source.put("needsAttention",true).put("status","需要登录或人工验证，请打开更新窗口处理。");put(c,id,source);}}
    }
    static void recovered(Context c,String site)throws Exception{
        for(String id:c.getSharedPreferences(PREFS,0).getAll().keySet()){JSONObject source=get(c,id);if(site.equals(WebsiteUpdatePolicy.site(source.optString("url")))&&source.optString("status").equals("需要登录或人工验证，请打开更新窗口处理。")){source.put("needsAttention",false).put("status","登录已恢复，等待更新");put(c,id,source);}}
    }
    static SecretKey key()throws Exception{
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");store.load(null);
        if(!store.containsAlias(ALIAS)){KeyGenerator generator=KeyGenerator.getInstance("AES","AndroidKeyStore");generator.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());generator.generateKey();}
        return (SecretKey)store.getKey(ALIAS,null);
    }
    static JSONObject credentials(Context c,String site)throws Exception{
        SharedPreferences p=c.getSharedPreferences(ACCOUNTS,0);String value=p.getString(site,"");if(value.isEmpty())return null;
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(p.getString(site+".iv",""),Base64.NO_WRAP)));
        return new JSONObject(new String(cipher.doFinal(Base64.decode(value,Base64.NO_WRAP)),java.nio.charset.StandardCharsets.UTF_8));
    }
    static void saveCredentials(Context c,String site,String username,String password)throws Exception{
        if(!Arrays.asList("yantu","xuecheng").contains(site)||username.trim().isEmpty()||password.isEmpty())throw new IllegalArgumentException("请填写账号和密码。");
        JSONObject value=new JSONObject().put("username",username.trim()).put("password",password);Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());
        String encrypted=Base64.encodeToString(cipher.doFinal(value.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)),Base64.NO_WRAP);
        if(!c.getSharedPreferences(ACCOUNTS,0).edit().putString(site,encrypted).putString(site+".iv",Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP)).commit())throw new Exception("账号未保存。");
    }
    static void forget(Context c,String site)throws Exception{if(!c.getSharedPreferences(ACCOUNTS,0).edit().remove(site).remove(site+".iv").commit())throw new Exception("账号未移除。");}
}
