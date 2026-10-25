package local.studyplanner;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

/** Device-only configuration; never placed in a SyncLedger or business backup. */
final class CloudSSHConfig {
    static final int SERVICE_PORT=18090;
    final String host,username,fingerprint,privateKey,passphrase;
    final int port;
    CloudSSHConfig(String host,int port,String username,String fingerprint,String privateKey,String passphrase)throws Exception{
        this.host=validateHost(host);validatePort(port);this.port=port;
        if(!username.matches("[A-Za-z_][A-Za-z0-9_.-]{0,63}"))throw new Exception("请检查 SSH 登录用户名");
        fingerprint=fingerprint.trim();
        if(!fingerprint.startsWith("SHA256:")||!fingerprint.substring(7).matches("[A-Za-z0-9+/]{43}"))throw new Exception("请读取并向服务器主人核对 SHA256 服务器指纹");
        if(Base64.getDecoder().decode(fingerprint.substring(7)).length!=32)throw new Exception("服务器指纹无效");
        if(privateKey.getBytes(StandardCharsets.UTF_8).length>65536||!privateKey.contains("PRIVATE KEY-----")||!privateKey.contains("-----END "))throw new Exception("请导入有效的 SSH 私钥文件（最大64KB）");
        this.username=username;this.fingerprint=fingerprint;this.privateKey=privateKey;this.passphrase=passphrase;
    }
    static String validateHost(String input)throws Exception{
        String host=input.trim();
        if(host.isEmpty()||host.length()>253||host.startsWith("-")||!host.matches("[A-Za-z0-9.:-]+"))throw new Exception("SSH 地址只填写 IP 或主机名，不带协议、端口和路径");
        java.net.URI uri=new java.net.URI("ssh://"+(host.contains(":")?"["+host+"]":host));
        if(uri.getHost()==null)throw new Exception("SSH 服务器地址无效");return host;
    }
    static void validatePort(int port)throws Exception{if(port<1||port>65535)throw new Exception("SSH 端口须为1至65535");}
    String identity(){return "ssh://"+username+"@"+(host.contains(":")?"["+host+"]":host)+":"+port+"/127.0.0.1:"+SERVICE_PORT;}
}
