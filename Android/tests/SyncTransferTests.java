package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;

public final class SyncTransferTests {
    static int checks;
    static void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
    interface Action {void run()throws Exception;}
    static void rejects(Action action)throws Exception{boolean failed=false;try{action.run();}catch(Exception e){failed=true;}check(failed,"invalid transfer accepted");}
    static JSONObject op(String operation)throws Exception{return new JSONObject().put("operation",operation);}
    public static void main(String[] args)throws Exception{
        File root=Files.createTempDirectory("planner-transfer-test-").toFile();
        try(SyncTransfer transfer=new SyncTransfer(root)){
            if(args.length>0&&args[0].equals("bridge")){
                BufferedReader input=new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8));
                for(String line;(line=input.readLine())!=null;){
                    JSONObject result=transfer.handle(new JSONObject(line),(request,response)->Files.copy(request.toPath(),response.toPath(),java.nio.file.StandardCopyOption.REPLACE_EXISTING));
                    System.out.println(result.toString());
                }
                return;
            }
            int[] commits={0};SyncTransfer.Exchange exchange=(request,response)->{commits[0]++;Files.copy(request.toPath(),response.toPath(),java.nio.file.StandardCopyOption.REPLACE_EXISTING);};
            rejects(()->transfer.handle(op("begin").put("length",SyncTransfer.MAXIMUM_SIZE+1),exchange));
            transfer.handle(op("begin").put("length",100),exchange);
            rejects(()->transfer.handle(op("exchange"),exchange));check(commits[0]==0,"incomplete upload committed");
            rejects(()->transfer.handle(op("upload").put("offset",1).put("data","eA=="),exchange));
            rejects(()->transfer.handle(op("upload").put("offset",0).put("data","!invalid!"),exchange));
            transfer.close();check(root.list().length==0,"interrupted staging leaked");
            byte[] payload=new byte[18*1024*1024+13];Arrays.fill(payload,(byte)'x');
            byte[] json=("{\"blob\":\""+new String(payload,StandardCharsets.UTF_8)+"\"}").getBytes(StandardCharsets.UTF_8);
            transfer.handle(op("begin").put("length",json.length),exchange);
            for(int offset=0;offset<json.length;offset+=SyncTransfer.CHUNK_SIZE){
                int end=Math.min(offset+SyncTransfer.CHUNK_SIZE,json.length);
                JSONObject envelope=op("upload").put("offset",offset).put("data",Base64.getEncoder().encodeToString(Arrays.copyOfRange(json,offset,end)));
                check(envelope.toString().getBytes(StandardCharsets.UTF_8).length<16*1024*1024,"request exceeds wire limit");
                check(transfer.handle(envelope,exchange).getInt("offset")==end,"wrong upload acknowledgement");
            }
            int size=transfer.handle(op("exchange"),exchange).getInt("length");check(commits[0]==1,"exchange must commit exactly once");
            rejects(()->transfer.handle(op("exchange"),exchange));
            ByteArrayOutputStream result=new ByteArrayOutputStream();
            while(result.size()<size){
                JSONObject envelope=transfer.handle(op("download").put("offset",result.size()),exchange);
                check(envelope.toString().getBytes(StandardCharsets.UTF_8).length<16*1024*1024,"response exceeds wire limit");
                result.write(Base64.getDecoder().decode(envelope.getString("data")));
            }
            check(Arrays.equals(json,result.toByteArray()),"large transfer changed bytes");
            rejects(()->transfer.handle(op("download").put("offset",-1),exchange));
            transfer.close();check(root.list().length==0,"completed staging leaked");
            transfer.handle(op("begin").put("length",10),exchange);transfer.handle(op("begin").put("length",20),exchange);
            check(root.list().length==1,"new transfer retained old upload");
        }finally{for(File file:root.listFiles())file.delete();root.delete();}
        System.out.println("PASS "+checks+" transfer checks: >16 MB round trip, incomplete uploads, offsets, bounds, duplicate commit, staging cleanup");
    }
}
