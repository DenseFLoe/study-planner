package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.Arrays;

public final class BoundedJSONFileTests {
    static int checks;
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static class Stream extends ByteArrayInputStream {
        boolean closed;
        Stream(byte[] value){super(value);}
        public void close(){closed=true;}
        int consumed(){return pos;}
    }
    static void rejected(byte[] value,long maximum) throws Exception {
        Stream stream=new Stream(value);
        try{BoundedJSONFile.read(stream,maximum,"测试文件");throw new AssertionError("Invalid file accepted");}
        catch(IOException|JSONException expected){checks++;}
        check(stream.closed,"Failed read left stream open");
        check(stream.consumed()<=maximum+1,"Read exceeded limit plus detection byte");
    }
    static void preserved(byte[] value) throws Exception {
        Path directory=Files.createTempDirectory("journal-read-");Path file=directory.resolve("journal.json");
        try{
            Files.write(file,value);DailyConsequenceRepository repository=new DailyConsequenceRepository(file.toFile());
            try{repository.load();throw new AssertionError("Invalid history accepted");}catch(IOException|JSONException expected){checks++;}
            check(repository.writeDisabled,"Unreadable history remained writable");
            try{repository.save(DailyConsequenceRepository.empty());throw new AssertionError("Unreadable history overwritten");}catch(IOException expected){checks++;}
            check(Arrays.equals(value,Files.readAllBytes(file)),"Original history bytes changed");
        }finally{Files.deleteIfExists(file);Files.deleteIfExists(directory);}
    }
    public static void main(String[] args) throws Exception {
        String good="{\"version\":1,\"days\":[],\"note\":\"中文 😀 { [ \\\" \\\\ \"}";
        byte[] bytes=good.getBytes(StandardCharsets.UTF_8);Stream stream=new Stream(bytes);
        check(BoundedJSONFile.read(stream,bytes.length,"测试文件").getJSONArray("days").length()==0,"Exact-limit UTF-8 rejected");
        check(stream.closed&&stream.consumed()==bytes.length,"Successful read not closed or incomplete");
        rejected(bytes,bytes.length-1);rejected(bytes,0);
        byte[] invalid=good.replace("中文","X").getBytes(StandardCharsets.UTF_8);
        for(int i=0;i<invalid.length;i++)if(invalid[i]=='X'){invalid[i]=(byte)0xff;break;}
        rejected(invalid,invalid.length);preserved(invalid);
        for(String tail:new String[]{" trailing"," {}","\u0000ignored"}){
            byte[] data=(good+tail).getBytes(StandardCharsets.UTF_8);rejected(data,data.length);preserved(data);
        }
        StringBuilder nested=new StringBuilder("{\"version\":1,\"days\":[],\"nested\":");
        for(int i=0;i<65;i++)nested.append('[');nested.append('0');for(int i=0;i<65;i++)nested.append(']');nested.append('}');
        byte[] deep=nested.toString().getBytes(StandardCharsets.UTF_8);rejected(deep,deep.length);preserved(deep);
        byte[] growing=new byte[100000];Arrays.fill(growing,(byte)' ');rejected(growing,8192);
        byte[] oversized=new byte[DailyConsequenceRepository.MAX_BYTES+1];Arrays.fill(oversized,(byte)' ');preserved(oversized);
        System.out.println("PASS "+checks+" bounded JSON and journal preservation checks");
    }
}
