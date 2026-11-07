package local.studyplanner;

import org.json.*;
import java.util.*;
import java.util.concurrent.*;
import static local.studyplanner.AssistantProtocol.*;

/** One ordered owner for history, edits and saves, retained across Activity recreation. */
final class AssistantSession {
    interface VersionedStore extends AssistantActions.CheckedStore {long assistantRevision();}
    interface View {void update(State value);}
    interface KeyOperation {String run(Configuration config)throws Exception;}
    interface Edit {void apply(JSONObject workspace)throws Exception;}
    static final class State {
        final JSONObject workspace;final boolean ready,busy,saving,keyLoaded;final String message,activity;final AssistantActions.Proposal change;
        final AssistantRunner.Request approval;final JSONArray findings;final boolean undo;
        State(AssistantSession s)throws Exception{workspace=CourseTools.copy(s.workspace);ready=s.ready;busy=s.busy;saving=s.saving;message=s.message;activity=s.activity;change=s.change;approval=s.approval;findings=s.findings;undo=s.undoBefore!=null;keyLoaded=!s.key.isEmpty();}
    }
    final ExecutorService queue=Executors.newSingleThreadExecutor(r->new Thread(r,"assistant-history"));
    final ExecutorService network=Executors.newSingleThreadExecutor(r->new Thread(r,"assistant-requests"));
    final AssistantHistory history;final StateMutation.Store<JSONObject> database;final AssistantRunner.Transport transport;final Runnable changed;
    final Set<String> knownKeys=new HashSet<>();JSONObject workspace;boolean ready,busy,saving;String key="",message="",activity="正在读取本机聊天…",runID;
    volatile AssistantRunner runner;View view;AssistantActions.Proposal change;AssistantRunner.Request approval;JSONArray findings=new JSONArray();CompletableFuture<Boolean> decision;
    JSONObject undoBefore;String undoAfter,undoTitle;
    AssistantSession(AssistantHistory history,StateMutation.Store<JSONObject> database,AssistantRunner.Transport transport,Runnable changed){this.history=history;this.database=database;this.transport=transport;this.changed=changed;queue.execute(()->{try{workspace=history.load();ready=true;activity="可发送问题";}catch(Exception error){try{workspace=AssistantHistory.empty();}catch(Exception ignored){}message=HISTORY;}publish();});}
    void attach(View view){queue.execute(()->{this.view=view;publish();});}
    void detach(View view){AssistantRunner active=runner;if(active!=null)active.token.cancel();queue.execute(()->{if(this.view==view){this.view=null;stopInternal();key="";}});}
    void publish(){if(view==null||workspace==null)return;try{view.update(new State(this));}catch(Exception error){message=HISTORY;}}
    static String safe(Exception error){return error instanceof Failure?error.getMessage():"操作未完成，原有数据已保留。请核对输入或稍后重试。";}
    void persist()throws Exception{history.save(workspace,knownKeys);}
    void edit(Edit edit){queue.execute(()->{
        if(!ready||saving)return;JSONObject before=null;try{stopInternal();before=CourseTools.copy(workspace);edit.apply(workspace);persist();message="";}catch(Exception error){if(before!=null)workspace=before;message=safe(error);}publish();
    });}
    void newConversation(){edit(w->{JSONArray values=w.getJSONArray("conversations");if(values.length()>=100)throw new Failure("最多保留100段对话，请先删除部分记录。");JSONObject value=AssistantHistory.conversation();values.put(value);w.put("selectedID",value.getString("id"));});}
    void select(String id){edit(w->{boolean found=false;for(JSONObject c:Planner.list(w.getJSONArray("conversations")))if(c.getString("id").equals(id))found=true;if(!found)throw invalid();w.put("selectedID",id);});}
    void delete(Set<String> ids){edit(w->{JSONArray old=w.getJSONArray("conversations"),kept=new JSONArray();for(JSONObject c:Planner.list(old))if(!ids.contains(c.getString("id")))kept.put(c);if(kept.length()==0)kept.put(AssistantHistory.conversation());w.put("conversations",kept);boolean selected=false;for(JSONObject c:Planner.list(kept))if(c.getString("id").equals(w.getString("selectedID")))selected=true;if(!selected)w.put("selectedID",kept.getJSONObject(0).getString("id"));});}
    void memory(String id,String text,boolean enabled,boolean remove){edit(w->{JSONArray values=w.getJSONArray("memories");boolean found=false;for(int i=0;i<values.length();i++)if(values.getJSONObject(i).getString("id").equals(id)){found=true;if(remove)values.remove(i);else values.put(i,object("id",id,"text",text.trim(),"enabled",enabled));break;}if(!found&&!remove)values.put(object("id",Planner.id(),"text",text.trim(),"enabled",enabled));});}
    void configure(JSONObject config,String typedKey,boolean saveKey,KeyOperation operation){queue.execute(()->{
        if(!ready||saving)return;boolean credentialStored=false;try{
            stopInternal();Configuration value=new Configuration(config);value.endpoint();history.contract.check(config.toString(),key);history.contract.check(config.toString(),typedKey);
            String resolved=operation==null?typedKey:operation.run(value);credentialStored=saveKey&&operation!=null;if(!resolved.isEmpty()){if(resolved.length()>8192||resolved.chars().anyMatch(Character::isWhitespace)||resolved.chars().anyMatch(Character::isISOControl))throw new Failure("密钥格式无效。");knownKeys.add(resolved);}
            JSONObject before=CourseTools.copy(workspace);workspace.put("configuration",value.json());try{persist();}catch(Exception error){workspace=before;throw error;}
            key=resolved;message=saveKey?"配置与密钥已安全保存在本机。":key.isEmpty()?"配置已保存，请填写或载入此地址的密钥。":"配置已保存，密钥已载入本次会话。";
        }catch(Exception error){message=credentialStored?"密钥已在本机安全存储保存，但助手配置未保存；请重新核对 API 设置。":safe(error);}publish();
    });}
    void send(String question){queue.execute(()->{
        if(!ready||busy||saving)return;
        try{
            String text=question.trim();if(text.isEmpty())return;limit(text,6000);history.contract.check(text,key);Configuration config=new Configuration(workspace.getJSONObject("configuration"));config.endpoint();if(key.isEmpty())throw new Failure("请打开 API 设置填写密钥，或主动从本机安全存储载入。");
            JSONArray messages=AssistantHistory.messages(workspace,text);history.contract.check(messages.toString(),key);change=null;append("你",text,"处理中");persist();busy=true;message="";activity="正在准备查询…";String id=Planner.id();runID=id;String secret=key;publish();
            AssistantRunner active=new AssistantRunner(history.contract,transport,new AssistantRunner.Source(){
                long revision;
                public Snapshot snapshot()throws Exception{synchronized(database){Snapshot shot=new Snapshot(database.load(),Planner.now());if(database instanceof VersionedStore)revision=((VersionedStore)database).assistantRevision();return shot;}}
                public void current(Snapshot snapshot)throws Exception{
                    if(!snapshot.zone.equals(Planner.ZONE)||!snapshot.today.equals(snapshot.day(Planner.now())))throw new Changed();
                    if(database instanceof VersionedStore&&revision==((VersionedStore)database).assistantRevision())return;
                    synchronized(database){snapshot.current(database.load());if(database instanceof VersionedStore)revision=((VersionedStore)database).assistantRevision();}
                }
            },new AssistantRunner.Listener(){
                public boolean approve(AssistantRunner.Request request,JSONArray result)throws Exception{
                    CompletableFuture<Boolean> answer=new CompletableFuture<>();queue.execute(()->{if(!id.equals(runID)){answer.complete(false);return;}approval=request;findings=result;decision=answer;publish();});
                    try{return answer.get(120,TimeUnit.SECONDS);}catch(TimeoutException error){throw new Failure("确认已过期，请重新发送并核对。");}
                }
                public void activity(String text){queue.execute(()->{if(id.equals(runID)){record(text);publish();}});}
                public void proposal(AssistantActions.Proposal proposed){queue.execute(()->{if(id.equals(runID)){change=proposed;publish();}});}
            });runner=active;
            network.execute(()->{String answer=null;Exception failure=null;try{answer=active.run(config,messages,secret);}catch(Exception error){failure=error;}final String result=answer;final Exception error=failure;
                queue.execute(()->{if(!id.equals(runID))return;busy=false;runID=null;runner=null;approval=null;decision=null;
                    try{if(error==null)record("查询完成");mark(error==null?"完成":"未完成");if(error==null){append("助手",result,"完成");activity="回答完成 · 可继续追问";}else{change=null;message=safe(error);activity="本轮已结束 · 可重试";}persist();}catch(Exception saveError){message=safe(saveError);}publish();});
            });
        }catch(Exception error){message=safe(error);try{mark("未完成");}catch(Exception ignored){}publish();}
    });}
    void decide(boolean allow){queue.execute(()->{if(decision==null||approval==null)return;boolean timely=System.currentTimeMillis()<approval.expires;CompletableFuture<Boolean> pending=decision;approval=null;decision=null;pending.complete(allow&&timely);publish();});}
    void stop(){AssistantRunner active=runner;if(active!=null)active.token.cancel();queue.execute(()->{stopInternal();publish();});}
    void stopInternal(){
        change=null;if(!busy&&decision==null)return;AssistantRunner active=runner;if(active!=null)active.token.cancel();runID=null;runner=null;busy=false;approval=null;if(decision!=null)decision.complete(false);decision=null;message=STOPPED;activity="本轮已停止 · 可重试";
        try{mark("未完成");persist();}catch(Exception error){message=safe(error);}
    }
    void record(String text)throws RuntimeException{activity=text;try{JSONArray entries=AssistantHistory.selected(workspace).getJSONArray("entries");for(int i=entries.length()-1;i>=0;i--){JSONObject e=entries.getJSONObject(i);if(e.optString("role").equals("你")&&e.optString("status").equals("处理中")){JSONArray steps=e.optJSONArray("steps");if(steps==null){steps=new JSONArray();e.put("steps",steps);}if(steps.length()<120&&(steps.length()==0||!steps.getString(steps.length()-1).equals(text)))steps.put(text);break;}}}catch(Exception ignored){}}
    void append(String role,String text,String status)throws Exception{JSONObject c=AssistantHistory.selected(workspace);c.getJSONArray("entries").put(object("id",Planner.id(),"role",role,"text",text,"status",status));c.put("updatedAt",Planner.now());}
    void mark(String status)throws Exception{for(JSONObject e:Planner.list(AssistantHistory.selected(workspace).getJSONArray("entries")))if(e.optString("status").equals("处理中"))e.put("status",status);}
    void apply(String id){queue.execute(()->{
        if(!ready||busy||saving||change==null||!change.id.equals(id)){publish();return;}AssistantActions.Proposal proposal=change;change=null;saving=true;activity="正在保存已确认的修改…";publish();boolean applied=false;
        try{JSONObject actual=AssistantActions.apply(database,proposal,Planner::now);applied=true;undoBefore=proposal.before;undoAfter=signature(actual);undoTitle=proposal.title;append("本机操作","已应用："+proposal.title+"\n"+proposal.summary+"\n修改前已创建自动备份，可撤销本次修改。","完成");persist();message="";}catch(Exception error){message=applied?"日程修改已保存，但本机聊天记录保存失败；请勿重复应用，可到数据与备份核对。":safe(error);}finally{if(applied)changed.run();saving=false;activity="本机操作结束";publish();}
    });}
    void dismiss(String id){queue.execute(()->{if(busy||saving||change==null||!change.id.equals(id))return;change=null;try{append("本机操作","已取消修改方案，日程未改变。","完成");persist();}catch(Exception error){message=safe(error);}publish();});}
    void undo(){queue.execute(()->{
        if(!ready||busy||saving||undoBefore==null)return;change=null;saving=true;activity="正在撤销助手修改…";publish();boolean restored=false;
        try{AssistantActions.undo(database,undoBefore,undoAfter);restored=true;undoBefore=null;append("本机操作","已撤销："+undoTitle+"。","完成");persist();message="";}catch(Exception error){message=restored?"日程已撤销，但本机聊天记录保存失败；请到主页面核对当前日程。":safe(error);}finally{if(restored)changed.run();saving=false;activity="本机操作结束";publish();}
    });}
}
