package local.studyplanner;

import android.content.*;
import android.security.keystore.*;
import android.util.Base64;
import java.net.URI;
import java.security.KeyStore;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

/** Cloud credentials are local configuration, never part of planner snapshots or exports. */
final class CloudSettings {
    static final String PREFS="cloud-sync",ALIAS="local.studyplanner.cloud";
    static boolean enabled(Context c){return c.getSharedPreferences(PREFS,0).getBoolean("enabled",false);}
    static String endpoint(Context c){return c.getSharedPreferences(PREFS,0).getString("endpoint","");}
    static String validateEndpoint(String text)throws Exception{
        URI uri=new URI(text.trim());
        if(!"https".equals(uri.getScheme())||uri.getHost()==null||uri.getUserInfo()!=null||uri.getQuery()!=null||uri.getFragment()!=null||!(uri.getPath().isEmpty()||uri.getPath().equals("/")))
            throw new Exception("请输入 HTTPS 服务器根地址，支持公网 IP");
        String result=text.trim();return result.endsWith("/")?result.substring(0,result.length()-1):result;
    }
    static javax.crypto.SecretKey key()throws Exception{
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");store.load(null);
        if(!store.containsAlias(ALIAS)){
            KeyGenerator generator=KeyGenerator.getInstance("AES","AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());generator.generateKey();
        }
        return (javax.crypto.SecretKey)store.getKey(ALIAS,null);
    }
    static String token(Context c)throws Exception{
        SharedPreferences p=c.getSharedPreferences(PREFS,0);String encoded=p.getString("token","");if(encoded.isEmpty())return "";
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(p.getString("iv",""),Base64.NO_WRAP)));
        return new String(cipher.doFinal(Base64.decode(encoded,Base64.NO_WRAP)),java.nio.charset.StandardCharsets.UTF_8);
    }
    static void save(Context c,String endpoint,String token,boolean enabled)throws Exception{
        SharedPreferences.Editor edit=c.getSharedPreferences(PREFS,0).edit();
        if(enabled){
            endpoint=validateEndpoint(endpoint);if(token.isEmpty())token=token(c);
            if(token.length()<32||token.length()>512||token.matches(".*\\s.*"))throw new Exception("服务访问码须为32至512位，不能包含空白；它不是 SSH 密钥");
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());
            edit.putString("endpoint",endpoint).putString("token",Base64.encodeToString(cipher.doFinal(token.getBytes(java.nio.charset.StandardCharsets.UTF_8)),Base64.NO_WRAP))
                .putString("iv",Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP));
        }
        if(!edit.putBoolean("enabled",enabled).commit())throw new Exception("云同步配置未保存");
    }
}
