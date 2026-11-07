package local.studyplanner;

import android.content.*;
import android.security.keystore.*;
import android.util.Base64;
import java.security.KeyStore;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import java.nio.charset.StandardCharsets;

/** Keys are encrypted locally and scoped to the exact provider and endpoint. */
final class AssistantVault {
    static final String PREFS="assistant-vault-v1",ALIAS="local.studyplanner.assistant.v1";
    static SecretKey key(boolean create)throws Exception{
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");store.load(null);
        if(!store.containsAlias(ALIAS)){
            if(!create)throw new AssistantProtocol.Failure("当前地址没有已保存的助手密钥。");
            KeyGenerator generator=KeyGenerator.getInstance("AES","AndroidKeyStore");generator.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());generator.generateKey();
        }return (SecretKey)store.getKey(ALIAS,null);
    }
    static void save(Context context,AssistantProtocol.Configuration config,String value)throws Exception{
        if(value.isEmpty()||value.length()>8192||value.chars().anyMatch(Character::isWhitespace)||value.chars().anyMatch(Character::isISOControl))throw new AssistantProtocol.Failure("请填写不含空白的 API 密钥。");
        String account=config.account();Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key(true));cipher.updateAAD(account.getBytes(StandardCharsets.UTF_8));
        if(!context.getSharedPreferences(PREFS,0).edit().putString(account,Base64.encodeToString(cipher.doFinal(value.getBytes(StandardCharsets.UTF_8)),Base64.NO_WRAP)).putString(account+".iv",Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP)).commit())throw new AssistantProtocol.Failure("助手密钥未保存，原凭证保留。");
    }
    static String load(Context context,AssistantProtocol.Configuration config)throws Exception{
        String account=config.account();SharedPreferences prefs=context.getSharedPreferences(PREFS,0);String encrypted=prefs.getString(account,"");if(encrypted.isEmpty())throw new AssistantProtocol.Failure("当前地址没有已保存的助手密钥。");
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(false),new GCMParameterSpec(128,Base64.decode(prefs.getString(account+".iv",""),Base64.NO_WRAP)));cipher.updateAAD(account.getBytes(StandardCharsets.UTF_8));return new String(cipher.doFinal(Base64.decode(encrypted,Base64.NO_WRAP)),StandardCharsets.UTF_8);
    }
}
