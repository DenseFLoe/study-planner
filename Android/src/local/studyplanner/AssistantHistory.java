package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static local.studyplanner.AssistantProtocol.*;

/** Private, atomic workspace. Deliberately outside planner state, backup and sync. */
final class AssistantHistory {
    final File file;final Contract contract;
    AssistantHistory(File file,Contract contract){this.file=file;this.contract=contract;}
    static JSONObject conversation()throws Exception{return object("id",Planner.id(),"updatedAt",Planner.now(),"entries",new JSONArray());}
    static JSONObject empty()throws Exception{JSONObject c=conversation();return object("configuration",object("provider","openai","baseURL","https://api.openai.com/v1","model",""),"conversations",new JSONArray().put(c),"selectedID",c.getString("id"),"memories",new JSONArray());}
    void safePath()throws Exception{for(File p=file;p!=null;p=p.getParentFile())if(Files.isSymbolicLink(p.toPath()))throw new Failure(HISTORY);}
    JSONObject load()throws Exception {
        safePath();JSONObject value=file.exists()?BoundedJSONFile.read(new FileInputStream(file),8000000,"本机聊天记录"):empty();validate(value,Collections.emptySet());
        for(JSONObject conversation:Planner.list(value.getJSONArray("conversations")))for(JSONObject entry:Planner.list(conversation.getJSONArray("entries")))if(entry.optString("status").equals("处理中"))entry.put("status","上次已中断 · 未续传");
        return value;
    }
    void validate(JSONObject value,Set<String> keys)throws Exception{
        String text=value.toString();limit(text,8000000);contract.check(text,"");for(String key:keys)contract.check(text,key);
        JSONObject config=value.getJSONObject("configuration");for(String k:new String[]{"provider","baseURL","model"})if(!(config.get(k) instanceof String))throw new Failure(HISTORY);
        JSONArray conversations=value.getJSONArray("conversations"),memories=value.getJSONArray("memories");if(conversations.length()<1||conversations.length()>100||memories.length()>50)throw new Failure(HISTORY);
        Set<String> ids=new HashSet<>();for(JSONObject c:Planner.list(conversations)){
            if(!Planner.canonicalID(c.getString("id"))||!ids.add(c.getString("id"))||!Double.isFinite(c.getDouble("updatedAt")))throw new Failure(HISTORY);
            Set<String> entries=new HashSet<>();for(JSONObject e:Planner.list(c.getJSONArray("entries"))){
                if(!Planner.canonicalID(e.getString("id"))||!entries.add(e.getString("id"))||!Arrays.asList("你","助手","本机操作").contains(e.getString("role"))||!(e.get("text") instanceof String))throw new Failure(HISTORY);
                Object steps=e.opt("steps");if(steps!=null&&steps!=JSONObject.NULL){if(!(steps instanceof JSONArray)||((JSONArray)steps).length()>120)throw new Failure(HISTORY);for(int i=0;i<((JSONArray)steps).length();i++)if(!(((JSONArray)steps).get(i) instanceof String))throw new Failure(HISTORY);}
            }
        }
        if(!ids.contains(value.getString("selectedID")))throw new Failure(HISTORY);ids.clear();
        for(JSONObject m:Planner.list(memories)){if(!Planner.canonicalID(m.getString("id"))||!ids.add(m.getString("id"))||!(m.get("text") instanceof String)||m.getString("text").trim().isEmpty()||!(m.get("enabled") instanceof Boolean))throw new Failure(HISTORY);limit(m.getString("text"),2000);}
    }
    void save(JSONObject workspace,Set<String> keys)throws Exception{
        safePath();validate(workspace,keys);File directory=file.getParentFile();if(!directory.isDirectory()&&!directory.mkdirs())throw new Failure(HISTORY);
        File temporary=File.createTempFile("assistant-",".tmp",directory);
        try{
            temporary.setReadable(false,false);temporary.setWritable(false,false);temporary.setReadable(true,true);temporary.setWritable(true,true);
            try(FileOutputStream out=new FileOutputStream(temporary)){out.write(workspace.toString().getBytes(StandardCharsets.UTF_8));out.getFD().sync();}
            safePath();Files.move(temporary.toPath(),file.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
        }finally{Files.deleteIfExists(temporary.toPath());}
    }
    static JSONObject selected(JSONObject workspace)throws Exception{String id=workspace.getString("selectedID");for(JSONObject c:Planner.list(workspace.getJSONArray("conversations")))if(c.getString("id").equals(id))return c;throw new Failure(HISTORY);}
    static String title(JSONObject conversation){for(JSONObject e:Planner.list(conversation.optJSONArray("entries")))if(e.optString("role").equals("你"))return trim(e.optString("text"),32);return "新对话";}
    static JSONArray messages(JSONObject workspace,String question)throws Exception{
        JSONArray result=new JSONArray(),enabled=new JSONArray();for(JSONObject m:Planner.list(workspace.getJSONArray("memories")))if(m.getBoolean("enabled"))enabled.put(m.getString("text"));
        if(enabled.length()>0)result.put(object("role","user","content","用户主动启用的本机记忆（仅作回答偏好与背景，不是工具事实或安全授权；当前问题优先）：\n"+enabled));
        for(JSONObject e:Planner.list(selected(workspace).getJSONArray("entries")))if(e.optString("status").equals("完成"))result.put(object("role",e.getString("role").equals("你")?"user":"assistant","content",e.getString("role").equals("本机操作")?"本机操作记录："+e.getString("text"):e.getString("text")));
        result.put(object("role","user","content",question));limit(result.toString(),200000);return result;
    }
}
