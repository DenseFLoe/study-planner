package local.studyplanner;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.Normalizer;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.regex.Pattern;

/** Native wire boundary. The model has only the shared, explicitly named planner tools. */
final class AssistantProtocol {
    static final String INVALID="助手返回了无效内容，未保存日程或自动重试。";
    static final String SECRET="检测到疑似密钥或凭证，已阻止保存和发送。请移除后重试。";
    static final String CHANGED="课表已变化，正在读取最新内容重新查询…";
    static final String STOPPED="已停止；已经发出的请求无法撤回，服务商仍可能计费。";
    static final String HISTORY="本机聊天记录无法安全读写，原文件已保留；本次未覆盖保存。";
    static class Failure extends Exception { Failure(String message){super(message);} }
    static final class Changed extends Failure { Changed(){super(CHANGED);} }
    static Failure invalid(){return new Failure(INVALID);}
    static JSONObject object(Object... pairs)throws Exception {
        JSONObject value=new JSONObject();for(int i=0;i<pairs.length;i+=2)value.put((String)pairs[i],pairs[i+1]==null?JSONObject.NULL:pairs[i+1]);return value;
    }
    static Set<String> keys(JSONObject value){Set<String> result=new HashSet<>();Iterator<String> it=value.keys();while(it.hasNext())result.add(it.next());return result;}
    static String hash(String text)throws Exception {
        byte[] bytes=MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8));StringBuilder out=new StringBuilder();
        for(byte b:bytes)out.append(String.format(Locale.ROOT,"%02x",b&255));return out.toString();
    }
    static String signature(JSONObject state)throws Exception{
        JSONObject business=PlannerBackupFile.businessState(state);
        for(String key:new String[]{"courses","fixedEvents","tasks","completions"}){
            List<JSONObject> rows=Planner.list(business.getJSONArray(key));rows.sort(Comparator.comparing(row->row.optString("id")));business.put(key,new JSONArray(rows));
        }return hash(SyncLedger.canonical(business));
    }
    static String read(InputStream input,int maximum)throws Exception {
        try(InputStream in=input;ByteArrayOutputStream out=new ByteArrayOutputStream()){
            byte[] bytes=new byte[8192];int n;while((n=in.read(bytes))!=-1){if(out.size()+n>maximum)throw new Failure("本轮已到内容上限，请缩小范围后重试。");out.write(bytes,0,n);}
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString();
        }
    }
    static void limit(String value,int maximum)throws Exception{if(value.getBytes(StandardCharsets.UTF_8).length>maximum)throw new Failure("本轮已到查询或内容上限，请缩小范围后重试。");}
    static JSONObject parse(String text,int maximum)throws Exception{return BoundedJSONFile.read(new ByteArrayInputStream(text.getBytes(StandardCharsets.UTF_8)),maximum,"助手内容");}
    static String trim(String value,int maximum){return value.substring(0,Math.min(value.length(),maximum));}
    static LocalDate date(String text,LocalDate fallback)throws Exception {
        if(text.isEmpty()&&fallback!=null)return fallback;
        try{LocalDate day=LocalDate.parse(text);if(!day.toString().equals(text))throw invalid();return day;}catch(RuntimeException error){throw invalid();}
    }
    static int integer(String text,int minimum,int maximum)throws Exception {
        try{int n=Integer.parseInt(text);if(n<minimum||n>maximum||!String.valueOf(n).equals(text))throw invalid();return n;}catch(NumberFormatException error){throw invalid();}
    }
    static final class Configuration {
        final String provider,baseURL,model;
        Configuration(JSONObject value){provider=value.optString("provider","openai");baseURL=value.optString("baseURL","https://api.openai.com/v1");model=value.optString("model");}
        JSONObject json()throws Exception{return object("provider",provider,"baseURL",baseURL,"model",model);}
        String endpoint()throws Exception {
            try{
                URI u=new URI(baseURL);
                if(!Arrays.asList("openai","deepseek","anthropic").contains(provider)||!"https".equals(u.getScheme())||u.getHost()==null||u.getUserInfo()!=null||u.getQuery()!=null||u.getFragment()!=null||baseURL.length()>2048||model.isEmpty()||model.length()>128||model.matches(".*\\s.*")||model.chars().anyMatch(Character::isISOControl))throw invalid();
                return baseURL.replaceAll("/+$","")+(anthropic()?"/messages":"/chat/completions");
            }catch(Exception error){throw new Failure("请填写 HTTPS 服务地址和模型名称；地址不能含账号、查询参数或片段。");}
        }
        boolean anthropic(){return provider.equals("anthropic");}
        String account()throws Exception{return hash(provider+endpoint());}
    }
    static final class Contract {
        final JSONArray tools,privacyRules;final String instructions;final List<Pattern> secrets=new ArrayList<>();
        Contract(JSONObject data)throws Exception {
            if(data.getInt("version")!=1)throw invalid();tools=data.getJSONArray("tools");instructions=data.getString("instructions");privacyRules=data.getJSONArray("privacyRules");
            JSONArray rules=data.getJSONArray("secretPatterns");for(int i=0;i<rules.length();i++)secrets.add(Pattern.compile(rules.getString(i)));
            if(tools.length()!=17||secrets.size()<7)throw invalid();
        }
        JSONObject definition(String name)throws Exception{for(JSONObject value:Planner.list(tools))if(name.equals(value.getString("name")))return value;throw invalid();}
        void arguments(String name,JSONObject input)throws Exception {
            JSONObject fields=definition(name).getJSONObject("fields");if(!keys(fields).equals(keys(input)))throw invalid();
            for(String key:keys(input)){if(!(input.get(key) instanceof String)||input.getString(key).length()>128)throw invalid();}check(input.toString(),"");
        }
        void check(String text,String key)throws Exception{check(text,key,0);}
        private void check(String text,String key,int depth)throws Exception {
            String normalized=Normalizer.normalize(text,Normalizer.Form.NFKC),decoded=normalized;
            try{decoded=URLDecoder.decode(normalized.replace("+","%2B"),"UTF-8");}catch(IllegalArgumentException ignored){}
            for(String value:new String[]{normalized,decoded}){
                if(!key.isEmpty()&&value.contains(key))throw new Failure(SECRET);
                for(Pattern p:secrets)if(p.matcher(value).find())throw new Failure(SECRET);
            }
            if(depth>=8)return;
            String candidate=text.trim();if(candidate.isEmpty()||"{[\"".indexOf(candidate.charAt(0))<0)return;
            int nesting=0;boolean quoted=false,escaped=false;
            for(int i=0;i<text.length();i++){char c=text.charAt(i);if(quoted){if(escaped)escaped=false;else if(c=='\\')escaped=true;else if(c=='\"')quoted=false;}else if(c=='\"')quoted=true;else if(c=='{'||c=='['){if(++nesting>64)throw invalid();}else if(c=='}'||c==']')nesting--;}
            Object json;try{json=new JSONTokener(text).nextValue();}catch(Exception ignored){return;}
            if(json instanceof String){if(!json.equals(text))check((String)json,key,depth+1);}
            else inspectJSON(json,key,depth+1);
        }
        private void inspectJSON(Object value,String key,int depth)throws Exception{
            if(depth>16)throw invalid();
            if(value instanceof JSONObject){JSONObject object=(JSONObject)value;for(String name:keys(object)){
                check(name,key,depth);Object item=object.get(name);if(item instanceof String)check(name+":"+item,key,depth);inspectJSON(item,key,depth+1);
            }}else if(value instanceof JSONArray){JSONArray array=(JSONArray)value;for(int i=0;i<array.length();i++)inspectJSON(array.get(i),key,depth+1);}
            else if(value instanceof String)check((String)value,key,depth);
        }
        JSONArray findings(String text)throws Exception {
            JSONArray result=new JSONArray();for(JSONObject rule:Planner.list(privacyRules))if(Pattern.compile(rule.getString("pattern")).matcher(text).find())result.put(rule.getString("reason"));return result;
        }
        JSONArray schemas(boolean anthropic)throws Exception{
            JSONArray result=new JSONArray();for(JSONObject def:Planner.list(tools)){
                JSONObject properties=new JSONObject(),fields=def.getJSONObject("fields");JSONArray required=new JSONArray();
                List<String> names=new ArrayList<>(keys(fields));Collections.sort(names);
                for(String key:names){properties.put(key,object("type","string","description",fields.getString(key),"maxLength",128));required.put(key);}
                JSONObject schema=object("type","object","properties",properties,"required",required,"additionalProperties",false);
                JSONObject tool=object("name",def.getString("name"),"description",def.getString("description"));
                if(anthropic)result.put(tool.put("input_schema",schema));else result.put(object("type","function","function",tool.put("parameters",schema)));
            }return result;
        }
    }
    static final class Snapshot {
        final JSONObject state;final double now;final ZoneId zone;final String id;final LocalDate today;
        Snapshot(JSONObject input,double time)throws Exception{state=CourseTools.copy(input);now=time;zone=Planner.ZONE;today=day(time);id=signature(state);}
        LocalDate day(double seconds){return Instant.ofEpochMilli((long)((seconds+Planner.EPOCH)*1000)).atZone(zone).toLocalDate();}
        double at(LocalDate day,int minutes){return day.atStartOfDay(zone).plusMinutes(minutes).toEpochSecond()-Planner.EPOCH;}
        String stamp(double seconds){return Instant.ofEpochMilli((long)((seconds+Planner.EPOCH)*1000)).atZone(zone).format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"));}
        void current(JSONObject latest)throws Exception{if(!zone.equals(Planner.ZONE)||!today.equals(day(Planner.now()))||!id.equals(signature(latest)))throw new Changed();}
    }
}
