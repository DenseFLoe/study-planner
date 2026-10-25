package local.studyplanner;

import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;

public final class CloudSSHTests {
    interface Checked{void run()throws Exception;}
    static int assertions;
    static void check(boolean value,String message){assertions++;if(!value)throw new AssertionError(message);}
    static void rejects(Checked operation)throws Exception{boolean rejected=false;try{operation.run();}catch(Exception expected){rejected=true;}check(rejected,"unsafe SSH setting must be rejected");}
    public static void main(String[] args)throws Exception{
        byte[] publicFixture="public host key fixture".getBytes(StandardCharsets.UTF_8);
        String pin=CloudSSHTunnel.fingerprint(publicFixture);
        String placeholder="-----BEGIN "+"OPENSSH PRIVATE KEY-----\nEXAMPLE_PLACEHOLDER\n-----END OPENSSH "+"PRIVATE KEY-----";
        CloudSSHTunnel.PinnedHost repository=new CloudSSHTunnel.PinnedHost(pin);
        check(repository.check("fixture.example",publicFixture)==com.jcraft.jsch.HostKeyRepository.OK,"matching pin must be accepted");
        check(repository.check("fixture.example",new byte[]{1,2,3})==com.jcraft.jsch.HostKeyRepository.CHANGED,"changed key must be rejected");
        check(new CloudSSHTunnel.PinnedHost(null).check("fixture.example",publicFixture)==com.jcraft.jsch.HostKeyRepository.CHANGED,"candidate lookup must stop before authentication");
        for(String host:new String[]{"-oProxyCommand=example","https://fixture.example","user@fixture.example","fixture.example/path","fixture.example\nother"})rejects(()->new CloudSSHConfig(host,22,"example_user",pin,placeholder,""));
        rejects(()->new CloudSSHConfig("fixture.example",0,"example_user",pin,placeholder,""));
        rejects(()->new CloudSSHConfig("fixture.example",22,"example_user","",placeholder,""));
        rejects(()->new CloudSSHConfig("fixture.example",22,"-invalid",pin,placeholder,""));
        check(new CloudSSHConfig("2001:db8::1",2222,"example_user",pin,placeholder,"").identity().equals("ssh://example_user@[2001:db8::1]:2222/127.0.0.1:18090"),"stable identity must not include ephemeral local port");
        String host=System.getenv("STUDY_SSH_TEST_HOST");
        if(host!=null){
            String key=new String(Files.readAllBytes(Paths.get(System.getenv("STUDY_SSH_TEST_KEY_PATH"))),StandardCharsets.UTF_8);
            CloudSSHConfig config=new CloudSSHConfig(host,Integer.parseInt(System.getenv().getOrDefault("STUDY_SSH_TEST_PORT","22")),System.getenv("STUDY_SSH_TEST_USER"),System.getenv("STUDY_SSH_TEST_FINGERPRINT"),key,"");
            String candidate=CloudSSHTunnel.readFingerprint(host,config.port);check(candidate.equals(config.fingerprint),"candidate must match the separately verified host pin");
            int local;
            try(CloudSSHTunnel tunnel=CloudSSHTunnel.open(config)){
                URL target=new URL(tunnel.endpoint+"/cloud/status");local=target.getPort();HttpURLConnection c=(HttpURLConnection)target.openConnection(Proxy.NO_PROXY);
                c.setConnectTimeout(5000);c.setReadTimeout(5000);c.setRequestProperty("Connection","close");
                try{check(c.getResponseCode()==401,"unauthenticated SSH probe must reach service without reading schedule data");}finally{c.disconnect();}
            }
            final int closed=local;rejects(()->{try(Socket socket=new Socket()){socket.connect(new InetSocketAddress("127.0.0.1",closed),1000);}});
            rejects(()->{try(CloudSSHTunnel ignored=CloudSSHTunnel.open(new CloudSSHConfig(host,config.port,config.username,pin,key,""))) {}});
            System.out.println("Live SSH: host pin, Ed25519 authentication, internal HTTP and cleanup passed");
        }else System.out.println("Live SSH skipped: explicit fixture environment was not supplied");
        System.out.println("Android SSH assertions passed: "+assertions);
    }
}
