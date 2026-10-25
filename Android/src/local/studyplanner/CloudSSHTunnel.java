package local.studyplanner;

import com.jcraft.jsch.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Base64;

/** One private, loopback-only forwarding session per sync. No remote commands or agent forwarding. */
final class CloudSSHTunnel implements AutoCloseable {
    private final JSch client;
    private final Session session;
    final String endpoint;
    static {
        // Android's platform provider lacks these algorithms on supported older releases.
        JSch.setConfig("signature.ed25519","com.jcraft.jsch.bc.SignatureEd25519");
        JSch.setConfig("signature.ed448","com.jcraft.jsch.bc.SignatureEd448");
        JSch.setConfig("keypairgen.eddsa","com.jcraft.jsch.bc.KeyPairGenEdDSA");
        JSch.setConfig("xdh","com.jcraft.jsch.bc.XDH");
    }
    private CloudSSHTunnel(JSch client,Session session,int port){this.client=client;this.session=session;endpoint="http://127.0.0.1:"+port;}
    static String fingerprint(byte[] key){
        try{return "SHA256:"+Base64.getEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(key));}
        catch(Exception e){throw new IllegalStateException("无法校验 SSH 服务器指纹");}
    }
    static final class PinnedHost implements HostKeyRepository {
        final String expected;String observed;
        PinnedHost(String expected){this.expected=expected;}
        public int check(String host,byte[] key){observed=fingerprint(key);return expected!=null&&MessageDigest.isEqual(expected.getBytes(StandardCharsets.US_ASCII),observed.getBytes(StandardCharsets.US_ASCII))?OK:CHANGED;}
        public void add(HostKey key,UserInfo ui){}
        public void remove(String host,String type){}
        public void remove(String host,String type,byte[] key){}
        public String getKnownHostsRepositoryID(){return "StudyPlanner pinned SHA256";}
        public HostKey[] getHostKey(){return new HostKey[0];}
        public HostKey[] getHostKey(String host,String type){return new HostKey[0];}
    }
    private static Session session(JSch client,String host,int port,String username)throws Exception{
        Session session=client.getSession(username,host,port);
        session.setConfig("StrictHostKeyChecking","yes");session.setConfig("PreferredAuthentications","publickey");
        session.setConfig("server_host_key","ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256");
        session.setTimeout(30000);session.setServerAliveInterval(15000);session.setServerAliveCountMax(2);
        return session;
    }
    /** Captures an untrusted candidate and rejects it before any authentication is attempted. */
    static String readFingerprint(String host,int port)throws Exception{
        host=CloudSSHConfig.validateHost(host);CloudSSHConfig.validatePort(port);
        JSch client=new JSch();PinnedHost pin=new PinnedHost(null);client.setHostKeyRepository(pin);
        Session session=session(client,host,port,"fingerprint-probe");
        try{session.connect(10000);}catch(JSchException e){if(pin.observed==null)throw new Exception("无法读取服务器指纹，请检查地址、端口及网络");}
        finally{session.disconnect();}
        if(pin.observed==null)throw new Exception("未收到服务器指纹");return pin.observed;
    }
    static CloudSSHTunnel open(CloudSSHConfig config)throws Exception{
        JSch client=new JSch();PinnedHost pin=new PinnedHost(config.fingerprint);client.setHostKeyRepository(pin);
        Session session=null;byte[] key=config.privateKey.getBytes(StandardCharsets.UTF_8),pass=config.passphrase.getBytes(StandardCharsets.UTF_8);
        try{
            client.addIdentity("study-planner",key,null,pass);
            session=session(client,config.host,config.port,config.username);session.connect(15000);
            int local=session.setPortForwardingL("127.0.0.1",0,"127.0.0.1",CloudSSHConfig.SERVICE_PORT);
            return new CloudSSHTunnel(client,session,local);
        }catch(Exception e){
            if(session!=null)session.disconnect();client.removeAllIdentity();
            if(pin.observed!=null&&!pin.observed.equals(config.fingerprint))throw new IllegalStateException("SSH 服务器指纹不匹配，已停止连接，请向服务器主人核对");
            throw new IllegalStateException("SSH 连接失败，请检查用户名、私钥、口令及服务器端口转发权限");
        }finally{Arrays.fill(key,(byte)0);Arrays.fill(pass,(byte)0);}
    }
    public void close(){session.disconnect();try{client.removeAllIdentity();}catch(JSchException ignored){}}
}
