package local.studyplanner;

import org.json.*;
import java.io.*;
import java.net.*;
import javax.net.ssl.HttpsURLConnection;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static local.studyplanner.AssistantProtocol.*;

/** Finite native tool loop, using the same contract as Mac. No model-supplied URL is followed. */
final class AssistantRunner {
    interface Source {Snapshot snapshot()throws Exception;void current(Snapshot snapshot)throws Exception;}
    interface Listener {boolean approve(Request request,JSONArray findings)throws Exception;void activity(String text);void proposal(AssistantActions.Proposal change);}
    interface Transport {String send(Request request,String key,Token token)throws Exception;}
    static final class Token {
        volatile boolean cancelled;volatile HttpsURLConnection connection;
        void cancel(){if(cancelled)return;cancelled=true;HttpsURLConnection active=connection;if(active!=null)new Thread(()->{try{active.disconnect();}catch(RuntimeException ignored){}},"assistant-cancel").start();}
        void check()throws Exception{if(cancelled||Thread.currentThread().isInterrupted())throw new Failure(STOPPED);}
    }
    static final class Request {
        final Configuration configuration;final String url,body;final long expires=System.currentTimeMillis()+120000;
        Request(Configuration config,JSONObject payload,Contract contract,String key)throws Exception{
            configuration=config;url=config.endpoint();body=payload.toString();limit(body,524288);contract.check(body,key);contract.check(url,key);contract.check(config.model,key);
            if(!payload.getString("model").equals(config.model)||payload.optBoolean("stream")||payload.optJSONArray("messages")==null)throw invalid();
        }
        String details(){return "POST "+url+"\nContent-Type: application/json\nAccept: application/json\n"+(configuration.anthropic()?"anthropic-version: 2023-06-01\nx-api-key":"Authorization")+": [密钥仅用于认证，不展示、不保存到聊天]\n\n"+body;}
        String scope(){return "接收方："+url+"\n模型："+configuration.model+"\n\n本次问题、已完成的对话历史和启用记忆；按需查询课程/课节名称、编号、日期时间、学习量与进度、规则、冲突及余量，以及修改预览摘要。上述文字中若含联系方式、身份、健康、财务信息、私密标记或链接，也包含在本轮授权范围内。\n\n本轮从发送到回答结束只确认一次；同一接收方的必要查询自动继续，课表变化后读取最新内容重新查询。下一轮重新确认。疑似密钥一律阻止，不能授权放行。日程修改仍需另行确认应用。";}
    }
    static final class HTTP implements Transport {
        public String send(Request request,String key,Token token)throws Exception{
            token.check();HttpsURLConnection connection=(HttpsURLConnection)new URL(request.url).openConnection();token.connection=connection;
            try{
                token.check();connection.setInstanceFollowRedirects(false);connection.setConnectTimeout(30000);connection.setReadTimeout(120000);connection.setRequestMethod("POST");connection.setDoOutput(true);connection.setUseCaches(false);
                connection.setRequestProperty("Content-Type","application/json");connection.setRequestProperty("Accept","application/json");
                if(request.configuration.anthropic()){connection.setRequestProperty("anthropic-version","2023-06-01");connection.setRequestProperty("x-api-key",key);}else connection.setRequestProperty("Authorization","Bearer "+key);
                byte[] data=request.body.getBytes(StandardCharsets.UTF_8);connection.setFixedLengthStreamingMode(data.length);try(OutputStream out=connection.getOutputStream()){token.check();out.write(data);}
                int status=connection.getResponseCode();token.check();if(status<200||status>=300)throw new Failure("接口请求失败（HTTP "+status+"），未自动重试。请核对服务地址、模型和账户。");
                String result=read(connection.getInputStream(),1048576);token.check();return result;
            }catch(Failure error){throw error;}catch(Exception error){token.check();throw new Failure("接口请求失败或超时，未自动重试。请核对服务地址、模型和账户。");}
            finally{token.connection=null;connection.disconnect();}
        }
    }
    final Contract contract;final Transport transport;final Source source;final Listener listener;final Token token=new Token();
    int requests,queries,rechecks;boolean approved;JSONArray insights=new JSONArray();JSONObject changeSummary;
    AssistantRunner(Contract contract,Transport transport,Source source,Listener listener){this.contract=contract;this.transport=transport;this.source=source;this.listener=listener;}
    static boolean reasoning(Configuration config){return !config.anthropic()&&config.model.toLowerCase(Locale.ROOT).matches("(?:o[1-9](?:-.*)?|gpt-(?:[5-9]|[1-9][0-9])(?:[.-].*)?)");}
    String run(Configuration config,JSONArray baseMessages,String key)throws Exception{
        config.endpoint();if(key.isEmpty()||key.length()>8192||key.chars().anyMatch(Character::isWhitespace)||key.chars().anyMatch(Character::isISOControl))throw new Failure("请打开 API 设置填写密钥，或主动从本机安全存储载入。");
        contract.check(baseMessages.toString(),key);long deadline=System.currentTimeMillis()+1200000;
        while(true){token.check();Snapshot shot=source.snapshot();try{return attempt(config,baseMessages,key,shot,deadline);}catch(Changed error){token.check();if(++rechecks>3)throw new Failure("课表仍在更新，稍后可重试查询。");listener.proposal(null);listener.activity(CHANGED);}}
    }
    private String attempt(Configuration config,JSONArray base,String key,Snapshot shot,long deadline)throws Exception{
        insights=new JSONArray();changeSummary=null;
        String instructions=contract.instructions+"\n"+AssistantChart.INSTRUCTIONS+"\n本机日期："+shot.today+"；时区："+shot.zone.getId()+"。";
        JSONArray messages=new JSONArray();if(!config.anthropic())messages.put(object("role",reasoning(config)?"developer":"system","content",instructions));
        for(int i=0;i<base.length();i++)messages.put(CourseTools.copy(base.getJSONObject(i)));
        List<JSONObject> evidence=new ArrayList<>();List<AssistantInsights.Query> displayQueries=new ArrayList<>();Set<String> callIDs=new HashSet<>();boolean proposed=false;
        while(true){
            token.check();source.current(shot);if(requests>=8||System.currentTimeMillis()>deadline)throw new Failure("本轮已到查询上限，请缩小问题范围后重试。");
            // OpenAI's o-series requires max_completion_tokens; compatible chat endpoints retain max_tokens.
            // https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
            JSONObject payload=object("model",config.model,"messages",messages,"tools",contract.schemas(config.anthropic()),reasoning(config)?"max_completion_tokens":"max_tokens",4096,"stream",false);
            if(config.anthropic())payload.put("system",instructions);else payload.put("tool_choice","auto");
            Request request=new Request(config,payload,contract,key);
            if(!approved){listener.activity("请确认本轮课表内容");boolean allow=listener.approve(request,contract.findings(base.toString()));token.check();if(System.currentTimeMillis()>=request.expires)throw new Failure("确认已过期，请重新发送并核对。");if(!allow)throw new Failure("已拒绝发送，本轮已停止。");approved=true;}
            token.check();source.current(shot);listener.activity(requests==0?"正在分析问题…":"正在整理查询结果…");requests++;
            String response=transport.send(request,key,token);token.check();source.current(shot);limit(response,1048576);contract.check(response,key);
            JSONObject root=parse(response,1048576);JSONArray calls=new JSONArray();String text="",reason;
            if(config.anthropic()){
                JSONArray content=root.getJSONArray("content"),safe=new JSONArray();StringBuilder answer=new StringBuilder();reason=root.getString("stop_reason");
                for(JSONObject block:Planner.list(content)){
                    switch(block.getString("type")){case "text":String part=block.getString("text");answer.append(part);safe.put(object("type","text","text",part));break;
                    case "tool_use":JSONObject call=object("id",block.getString("id"),"name",block.getString("name"),"input",block.getJSONObject("input"));calls.put(call);safe.put(object("type","tool_use","id",call.getString("id"),"name",call.getString("name"),"input",call.getJSONObject("input")));break;
                    default:throw invalid();}
                }
                text=answer.toString();if(calls.length()>0){if(!reason.equals("tool_use"))throw invalid();messages.put(object("role","assistant","content",safe));}
                else if(!reason.equals("end_turn"))throw invalid();
            }else{
                JSONArray choices=root.getJSONArray("choices");if(choices.length()!=1)throw invalid();JSONObject choice=choices.getJSONObject(0),message=choice.getJSONObject("message");reason=choice.getString("finish_reason");
                Object content=message.opt("content");if(content!=null&&content!=JSONObject.NULL&&!(content instanceof String))throw invalid();text=content instanceof String?(String)content:"";
                JSONArray raw=message.optJSONArray("tool_calls"),safe=new JSONArray();if(raw!=null)for(JSONObject call:Planner.list(raw)){
                    if(!call.getString("type").equals("function"))throw invalid();JSONObject function=call.getJSONObject("function"),input=parse(function.getString("arguments"),16000);calls.put(object("id",call.getString("id"),"name",function.getString("name"),"input",input));
                    safe.put(object("id",call.getString("id"),"type","function","function",object("name",function.getString("name"),"arguments",input.toString())));
                }
                if(calls.length()>0){if(!reason.equals("tool_calls"))throw invalid();JSONObject retained=object("role","assistant","content",text.isEmpty()?null:text,"tool_calls",safe);if(message.opt("reasoning_content") instanceof String)retained.put("reasoning_content",message.getString("reasoning_content"));messages.put(retained);}
                else if(!reason.equals("stop"))throw invalid();
            }
            if(calls.length()==0){if(text.trim().isEmpty())throw invalid();limit(text,64000);String answer=AssistantChart.materialize(text,evidence,shot.stamp(shot.now)+" "+shot.zone.getId()).replaceAll("\\[E[0-9]+(?:\\s*[,，、]\\s*E?[0-9]+)*\\]","");insights=AssistantInsights.build(displayQueries,answer);contract.check(insights.toString(),key);return answer;}
            // Validate the entire batch before executing any tool; no arbitrary model fields are forwarded.
            for(JSONObject call:Planner.list(calls)){String id=call.getString("id");if(id.isEmpty()||id.length()>128||!callIDs.add(id))throw invalid();contract.arguments(call.getString("name"),call.getJSONObject("input"));}
            JSONArray results=new JSONArray();for(JSONObject call:Planner.list(calls)){
                token.check();source.current(shot);if(++queries>24)throw new Failure("本轮已到查询上限，请缩小问题范围后重试。");String name=call.getString("name");listener.activity(AssistantTools.activity(name));
                JSONObject result;
                if(name.startsWith("preview_")||name.equals("list_events")){
                    AssistantActions.Result action=AssistantActions.execute(name,call.getJSONObject("input"),shot,"E"+queries,proposed);result=action.evidence;
                    if(action.proposal!=null){contract.check(action.proposal.title+action.proposal.summary+String.join("\n",action.proposal.details),key);proposed=true;changeSummary=AssistantChangeSummary.build(action.proposal);contract.check(changeSummary.toString(),key);listener.proposal(action.proposal);}
                }else{result=AssistantTools.query(name,call.getJSONObject("input"),shot,evidence);result.put("evidence_id","E"+queries);}
                token.check();source.current(shot);limit(result.toString(),128000);contract.check(result.toString(),key);evidence.add(result);displayQueries.add(new AssistantInsights.Query(name,call.getJSONObject("input"),result));
                if(config.anthropic())results.put(object("type","tool_result","tool_use_id",call.getString("id"),"content",result.toString()));
                else messages.put(object("role","tool","tool_call_id",call.getString("id"),"content",result.toString()));
            }
            if(config.anthropic())messages.put(object("role","user","content",results));
        }
    }
}
