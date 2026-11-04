package local.studyplanner;

import java.nio.charset.StandardCharsets;
import java.nio.charset.CodingErrorAction;
import java.nio.ByteBuffer;
import java.io.*;
import java.util.Base64;

/** Device-only configuration; never placed in a SyncLedger or business backup. */
final class CloudSSHConfig {
    static final int SERVICE_PORT=18090;
    static final int MAX_KEY_BYTES=65536;
    final String host,username,fingerprint,privateKey,passphrase;
    final int port;
    CloudSSHConfig(String host,int port,String username,String fingerprint,String privateKey,String passphrase)throws Exception{
        this.host=validateHost(host);validatePort(port);this.port=port;
        if(!username.matches("[A-Za-z_][A-Za-z0-9_.-]{0,63}"))throw new Exception("请检查 SSH 登录用户名");
        fingerprint=fingerprint.trim();
        if(!fingerprint.startsWith("SHA256:")||!fingerprint.substring(7).matches("[A-Za-z0-9+/]{43}"))throw new Exception("请读取并向服务器主人核对 SHA256 服务器指纹");
        if(Base64.getDecoder().decode(fingerprint.substring(7)).length!=32)throw new Exception("服务器指纹无效");
        if(privateKey.getBytes(StandardCharsets.UTF_8).length>MAX_KEY_BYTES||!privateKey.contains("PRIVATE KEY-----")||!privateKey.contains("-----END "))throw new Exception("请导入有效的 SSH 私钥文件（最大64KB）");
        this.username=username;this.fingerprint=fingerprint;this.privateKey=privateKey;this.passphrase=passphrase;
    }
    /** Owns the provider stream; no partial or lossy-decoded key is accepted. */
    static String readPrivateKey(InputStream source)throws IOException{
        if(source==null)throw new IOException("无法打开私钥文件，请重新选择。");
        try(InputStream input=source;ByteArrayOutputStream bytes=new ByteArrayOutputStream()){
            byte[] buffer=new byte[4096];int count;
            while((count=input.read(buffer,0,Math.min(buffer.length,MAX_KEY_BYTES+1-bytes.size())))!=-1){
                bytes.write(buffer,0,count);if(bytes.size()>MAX_KEY_BYTES)throw new IOException("私钥文件超过64 KiB上限。");
            }
            String key=StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
            if(!key.contains("PRIVATE KEY-----")||!key.contains("-----END "))throw new IOException("请选择 SSH 私钥文件，而非公钥。");
            return key;
        }
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
