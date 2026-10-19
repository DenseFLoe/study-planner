package local.studyplanner;

import org.json.*;
import java.io.*;
import java.util.*;

/** Streaming wire I/O. Only one bounded record is parsed; no whole envelope string exists. */
final class SyncJSON {
    interface RecordConsumer { void accept(JSONObject row)throws Exception; }
    static JSONObject readExchange(Reader input,RecordConsumer records)throws Exception {
        Tokens in=new Tokens(input);JSONObject header=new JSONObject();Set<String> seen=new HashSet<>();
        in.expect('{');
        if(in.peek()!='}')while(true){
            String key=new JSONArray("["+in.value(256)+"]").getString(0);
            if(!seen.add(key))throw new IOException("重复同步字段");
            in.expect(':');
            if(key.equals("changes")){
                in.expect('[');
                if(in.peek()!=']')while(true){
                    records.accept(new JSONObject(in.value(3*1024*1024)));
                    if(in.peek()!=',')break;in.expect(',');
                }
                in.expect(']');
            }else{
                if(!Arrays.asList("protocol","cursor","automatic","date").contains(key))throw new IOException("同步字段无效");
                JSONArray scalar=new JSONArray("["+in.value(4096)+"]");
                if(scalar.length()!=1)throw new IOException("同步字段无效");
                header.put(key,scalar.get(0));
            }
            if(in.peek()!=',')break;in.expect(',');
        }
        in.expect('}');
        if(in.peek()!=-1||!seen.contains("changes"))throw new IOException("同步信封不完整");
        return header;
    }
    static void write(Writer out,Object value)throws Exception {
        if(value instanceof JSONObject){
            JSONObject object=(JSONObject)value;out.write('{');boolean first=true;
            List<String> names=new ArrayList<>();Iterator<String> keys=object.keys();while(keys.hasNext())names.add(keys.next());Collections.sort(names);
            for(String key:names){if(!first)out.write(',');first=false;
                string(out,key);out.write(':');write(out,object.get(key));
            }out.write('}');
        }else if(value instanceof JSONArray){
            JSONArray array=(JSONArray)value;out.write('[');
            for(int i=0;i<array.length();i++){if(i>0)out.write(',');write(out,array.get(i));}out.write(']');
        }else if(value instanceof String)string(out,(String)value);
        else if(value==null||value==JSONObject.NULL)out.write("null");
        else if(value instanceof Number)out.write(JSONObject.numberToString((Number)value));
        else if(value instanceof Boolean)out.write(value.toString());
        else throw new IOException("无法编码同步字段");
    }
    private static void string(Writer out,String text)throws IOException {
        out.write('"');int start=0;
        for(int i=0;i<text.length();i++){
            char c=text.charAt(i);String escape=null;
            switch(c){case '"':escape="\\\"";break;case '\\':escape="\\\\";break;case '\b':escape="\\b";break;case '\f':escape="\\f";break;case '\n':escape="\\n";break;case '\r':escape="\\r";break;case '\t':escape="\\t";break;default:if(c<32)escape=String.format(Locale.ROOT,"\\u%04x",(int)c);}
            if(escape!=null){out.write(text,start,i-start);out.write(escape);start=i+1;}
        }
        out.write(text,start,text.length()-start);out.write('"');
    }
    private static final class Tokens {
        final Reader input;int pending=-2;
        Tokens(Reader input){this.input=input;}
        int take()throws IOException{if(pending!=-2){int c=pending;pending=-2;return c;}return input.read();}
        int peek()throws IOException{int c;do{c=take();}while(c==' '||c=='\t'||c=='\r'||c=='\n');pending=c;return c;}
        void expect(int expected)throws IOException{if(peek()!=expected)throw new IOException("同步 JSON 结构无效");take();}
        String value(int maximum)throws IOException{
            int first=peek();if(first==-1||first==','||first=='}'||first==']')throw new IOException("同步 JSON 缺少值");
            StringBuilder text=new StringBuilder();int depth=0;boolean quoted=false,escaped=false;
            while(true){
                int next=take();if(next==-1)throw new EOFException("同步 JSON 未收齐");char c=(char)next;
                if(!quoted&&depth==0&&text.length()>0&&(c==','||c=='}'||c==']'||Character.isWhitespace(c))){pending=next;break;}
                text.append(c);if(text.length()>maximum)throw new IOException("同步记录过大");
                if(quoted){if(escaped)escaped=false;else if(c=='\\')escaped=true;else if(c=='"')quoted=false;}
                else if(c=='"')quoted=true;
                else if(c=='{'||c=='['){if(++depth>64)throw new IOException("同步 JSON 嵌套过深");}
                else if(c=='}'||c==']')depth--;
                if(!quoted&&depth==0&&(first=='"'||first=='{'||first=='['))break;
            }
            return text.toString();
        }
    }
}
