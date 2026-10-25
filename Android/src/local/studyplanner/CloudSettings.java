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
    static String method(Context c){return "ssh".equals(c.getSharedPreferences(PREFS,0).getString("method","https"))?"ssh":"https";}
    static String field(Context c,String name,String fallback){return c.getSharedPreferences(PREFS,0).getString("ssh."+name,fallback);}
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
    static String token(Context c)throws Exception{return secret(c,"ssh".equals(method(c))?"ssh.token":"token");}
    static String secret(Context c,String name)throws Exception{
        SharedPreferences p=c.getSharedPreferences(PREFS,0);String encoded=p.getString(name,"");if(encoded.isEmpty())return "";
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(p.getString(name.equals("token")?"iv":name+".iv",""),Base64.NO_WRAP)));
        return new String(cipher.doFinal(Base64.decode(encoded,Base64.NO_WRAP)),java.nio.charset.StandardCharsets.UTF_8);
    }
    static void putSecret(SharedPreferences.Editor edit,String name,String value)throws Exception{
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());
        edit.putString(name,Base64.encodeToString(cipher.doFinal(value.getBytes(java.nio.charset.StandardCharsets.UTF_8)),Base64.NO_WRAP))
            .putString(name.equals("token")?"iv":name+".iv",Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP));
    }
    static void validateToken(String token)throws Exception{
        if(token.length()<32||token.length()>512||token.chars().anyMatch(Character::isWhitespace))throw new Exception("服务访问码须为32至512位且不含空白，与 SSH 私钥不同");
    }
    static CloudSSHConfig ssh(Context c)throws Exception{
        return new CloudSSHConfig(field(c,"host",""),Integer.parseInt(field(c,"port","22")),field(c,"user",""),field(c,"fingerprint",""),secret(c,"ssh.key"),secret(c,"ssh.passphrase"));
    }
    static void save(Context c,String endpoint,String token,boolean enabled)throws Exception{
        SharedPreferences.Editor edit=c.getSharedPreferences(PREFS,0).edit();
        if(enabled){
            endpoint=validateEndpoint(endpoint);if(token.isEmpty())token=secret(c,"token");validateToken(token);
            edit.putString("endpoint",endpoint);putSecret(edit,"token",token);
        }
        if(!edit.putString("method","https").putBoolean("enabled",enabled).commit())throw new Exception("云同步配置未保存");
    }
    static void saveSSH(Context c,String host,String port,String user,String fingerprint,String importedKey,String passphrase,String token,boolean enabled)throws Exception{
        SharedPreferences.Editor edit=c.getSharedPreferences(PREFS,0).edit();
        if(enabled){
            boolean reuse=importedKey.isEmpty();String privateKey=reuse?secret(c,"ssh.key"):importedKey;
            if(reuse&&passphrase.isEmpty())passphrase=secret(c,"ssh.passphrase");
            CloudSSHConfig ssh=new CloudSSHConfig(host,Integer.parseInt(port),user,fingerprint,privateKey,passphrase);
            if(token.isEmpty())token=secret(c,"ssh.token");validateToken(token);
            edit.putString("ssh.host",ssh.host).putString("ssh.port",String.valueOf(ssh.port)).putString("ssh.user",ssh.username).putString("ssh.fingerprint",ssh.fingerprint);
            putSecret(edit,"ssh.key",privateKey);putSecret(edit,"ssh.passphrase",passphrase);putSecret(edit,"ssh.token",token);
        }
        if(!edit.putString("method","ssh").putBoolean("enabled",enabled).commit())throw new Exception("云同步配置未保存");
    }
}
