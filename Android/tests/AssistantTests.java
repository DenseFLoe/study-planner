package local.studyplanner;

import org.json.*;
import java.io.*;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import static local.studyplanner.AssistantProtocol.*;

/** Synthetic-only integration checks: real planner calculations and files, no API or personal state. */
public final class AssistantTests {
    static int checks;static Contract contract;
    static final LocalDate DAY=LocalDate.of(2026,11,7);
    static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    interface Throwing{void run()throws Exception;}
    static void rejects(Throwing action,String message)throws Exception{boolean rejected=false;try{action.run();}catch(Exception expected){rejected=true;}check(rejected,message);}
    static JSONObject fixture()throws Exception{
        JSONObject s=PlannerTests.empty();s.getJSONObject("settings").put("availability",StudySettingsTests.windows(480,1320));
        JSONObject c=PlannerTests.course("合成数学",120,DAY,DAY.plusDays(2),60).put("type","录播课程").put("notes","不应发出的本机备注");s.getJSONArray("courses").put(c);Planner.replan(s,Planner.at(DAY,420));return s;
    }
    static Snapshot shot(JSONObject s)throws Exception{return new Snapshot(s,Planner.at(DAY,420));}
    static JSONObject input(Object...pairs)throws Exception{return object(pairs);}
    static Path temporary(String prefix)throws Exception{Path base=Paths.get(System.getProperty("java.io.tmpdir")).toRealPath();return Files.createTempDirectory(base,prefix);}
    static JSONObject query(String name,JSONObject input,Snapshot shot)throws Exception{contract.arguments(name,input);JSONObject result=AssistantTools.execute(name,input,shot,new ArrayList<>());contract.check(result.toString(),"");return result.getJSONObject("data");}
    static AssistantActions.Result action(String name,JSONObject in,Snapshot shot)throws Exception{contract.arguments(name,in);return AssistantActions.execute(name,in,shot,"E1",false);}
    static final class Store implements StateMutation.Store<JSONObject>{
        JSONObject state;boolean fail;int saves;Store(JSONObject state)throws Exception{this.state=CourseTools.copy(state);}
        public synchronized JSONObject load()throws Exception{return CourseTools.copy(state);}
        public synchronized void save(JSONObject value)throws Exception{if(fail)throw new IOException("synthetic save failure");state=CourseTools.copy(value);saves++;}
    }
    static final class CheckedStore implements AssistantActions.CheckedStore {
        final Store store;double time;boolean advance;int checks;
        CheckedStore(JSONObject value,double time)throws Exception{store=new Store(value);this.time=time;}
        public JSONObject load()throws Exception{return store.load();}public void save(JSONObject value)throws Exception{store.save(value);}
        public void saveChecked(JSONObject value,AssistantActions.Check guard)throws Exception{guard.run();checks++;if(advance)time+=300;guard.run();checks++;store.save(value);}
    }
    static void tools()throws Exception{
        check(contract.tools.length()==17,"Tool contract drift");Set<String> names=new HashSet<>();for(JSONObject d:Planner.list(contract.tools))check(names.add(d.getString("name")),"Duplicate tool");
        JSONObject s=fixture();Snapshot shot=shot(s);String cid=s.getJSONArray("courses").getJSONObject(0).getString("id"),before=s.toString();
        JSONObject result=query("list_courses",input("offset","0"),shot);check(result.getInt("total")==1,"Course list wrong");check(!result.toString().contains("本机备注"),"Notes left whitelist");
        result=query("inspect_course",input("course",cid,"offset","0"),shot);check(result.getInt("total_minutes")==120&&result.getInt("remaining_minutes")==120,"Progress wrong");
        query("inspect_rules",input(),shot);query("inspect_conflicts",input("offset","0"),shot);query("inspect_progress",input("start_date",DAY.toString(),"end_date",DAY.plusDays(30).toString(),"course",""),shot);
        rejects(()->query("inspect_progress",input("start_date",DAY.toString(),"end_date",DAY.plusDays(31).toString(),"course",""),shot),"Unbounded progress");
        rejects(()->contract.arguments("inspect_rules",input("command","arbitrary")),"Extra fields accepted");rejects(()->contract.arguments("read_file",input()),"Arbitrary tool accepted");rejects(()->query("list_courses",input("offset","01"),shot),"Noncanonical page accepted");
        List<JSONObject> evidence=new ArrayList<>();evidence.add(AssistantTools.evidence("E1","合成",input("left",12,"right",3,"boolean",true),shot));
        JSONObject calculated=AssistantTools.execute("calculate",input("left","E1.data.left","right","E1.data.right","operation","divide"),shot,evidence).getJSONObject("data");check(calculated.getDouble("result")==4,"Native arithmetic wrong");
        rejects(()->AssistantTools.execute("calculate",input("left","12","right","E1.data.right","operation","add"),shot,evidence),"Model number accepted");rejects(()->AssistantTools.execute("calculate",input("left","E1.data.boolean","right","E1.data.right","operation","add"),shot,evidence),"Boolean accepted as number");
        JSONObject c=s.getJSONArray("courses").getJSONObject(0);String raw="synthetic-share/lesson-private";c.put("type","不定时录播课程").put("manualLessons",new JSONArray().put(input("id",raw,"name","合成第一节","durationMinutes",120)));Planner.replan(s,Planner.at(DAY,420));Snapshot lessons=shot(s);
        JSONObject course=query("inspect_course",input("course",cid,"offset","0"),lessons),schedule=query("inspect_schedule",input("date",DAY.toString(),"offset","0"),lessons);String reference=course.getJSONArray("lessons").getJSONObject(0).getString("lesson_id");
        check(reference.equals(hash("assistant-lesson:"+cid+":"+raw)),"Opaque lesson identity differs from Mac");check(!course.toString().contains(raw)&&!schedule.toString().contains(raw),"Source lesson identity leaked");
        JSONObject row=schedule.getJSONArray("rows").getJSONObject(0);check(row.getString("lesson_id").equals(reference)&&row.getString("lesson_match").equals("matched"),"Schedule lesson association lost");
        JSONObject untouched=fixture();String unmodified=untouched.toString();query("inspect_schedule",input("date",DAY.toString(),"offset","0"),shot(untouched));check(unmodified.equals(untouched.toString()),"Query mutated original state");check(shot.state.toString().equals(before),"Query mutated original snapshot");
        JSONObject many=PlannerTests.empty();for(int i=0;i<41;i++)many.getJSONArray("courses").put(PlannerTests.course("合成"+i,1,DAY,DAY,1));JSONObject page=query("list_courses",input("offset","20"),shot(many));check(page.getJSONArray("courses").length()==20&&page.getString("next_offset").equals("40"),"Course pagination lost");
    }
    static JSONObject event(String name,int first,int last)throws Exception{return input("id",Planner.id(),"title",name,"startDate",Planner.at(DAY,0),"endDate",Planner.at(DAY,0),"startMinute",first,"endMinute",last,"weekdays",new JSONArray(),"excludedDates",new JSONArray(),"notes","","color","orange");}
    static void timeChecks()throws Exception{
        JSONObject s=fixture();s.put("tasks",new JSONArray());int[][] spans={{480,720},{540,600},{600,660},{570,630}};for(int[] pair:spans)s.getJSONArray("fixedEvents").put(event("合成事项",pair[0],pair[1]));
        JSONObject result=AssistantTools.timeCheck(shot(s),DAY,0);check(result.getInt("fixed_overlap_count")==5,"Nested overlap pairs missed or adjacent counted");
        JSONObject course=s.getJSONArray("courses").getJSONObject(0);s.getJSONArray("tasks").put(Planner.task(course.getString("id"),Planner.at(DAY,500),60).put("status","completed").put("completedMinutes",60).put("confirmedAt",Planner.at(DAY,560)));
        result=AssistantTools.timeCheck(shot(s),DAY,0);check(result.getInt("fixed_overlap_count")==5&&result.getInt("excluded_confirmed_task_count")==1,"Historical task treated as occupied");
        s.put("fixedEvents",new JSONArray().put(event("浮动甲",480,540).put("floatingDurationMinutes",40)).put(event("浮动乙",480,540).put("floatingDurationMinutes",40)));
        result=AssistantTools.timeCheck(shot(s),DAY,0);check(result.getInt("fixed_overlap_count")==0&&result.getString("joint_floating_status").equals("proven_deficit"),"Floating windows treated as fixed or joint deficit missed");
        s.getJSONArray("fixedEvents").getJSONObject(1).put("floatingDurationMinutes",20);result=AssistantTools.timeCheck(shot(s),DAY,0);check(result.getString("joint_floating_status").equals("not_verified"),"Capacity passing claimed feasibility");
        JSONObject many=fixture();many.put("tasks",new JSONArray());for(int i=0;i<22;i++)many.getJSONArray("fixedEvents").put(event("浮动",480,540).put("floatingDurationMinutes",1));result=AssistantTools.timeCheck(shot(many),DAY,20);check(result.getJSONArray("rows").length()==2&&result.getInt("total")==22,"Time pagination incorrect");
    }
    static void actions()throws Exception{
        JSONObject state=fixture();Snapshot shot=shot(state);String before=state.toString(),cid=state.getJSONArray("courses").getJSONObject(0).getString("id");
        AssistantActions.Result r=action("preview_edit_course",input("course",cid,"field","name","value","已核对的新名称"),shot);check(r.proposal!=null&&before.equals(state.toString()),"Preview mutated state");check(r.evidence.getJSONObject("data").getString("status").equals("awaiting_local_confirmation")&&!r.evidence.toString().contains("after"),"Full state left device");
        Store store=new Store(state);JSONObject saved=AssistantActions.apply(store,r.proposal,shot.now+1);check(Planner.course(saved,cid).getString("name").equals("已核对的新名称")&&store.saves==1,"Confirmed edit missing");
        AssistantActions.undo(store,r.proposal.before,signature(saved));check(signature(store.load()).equals(signature(state)),"Undo wrong");
        store.state.getJSONArray("courses").getJSONObject(0).put("notes","新同步修改");rejects(()->AssistantActions.apply(store,r.proposal,shot.now+1),"Stale proposal overwrote concurrent change");rejects(()->AssistantActions.undo(store,r.proposal.before,r.proposal.afterID),"Stale undo accepted");
        final Store failed=new Store(state);failed.fail=true;rejects(()->AssistantActions.apply(failed,r.proposal,shot.now+1),"Save failure accepted");check(signature(failed.state).equals(signature(state)),"Failed save changed state");
        final Store fresh=new Store(state);rejects(()->AssistantActions.apply(fresh,r.proposal,r.proposal.expires),"Expired preview accepted");
        CheckedStore timed=new CheckedStore(state,r.proposal.expires-1);timed.advance=true;rejects(()->AssistantActions.apply(timed,r.proposal,()->timed.time),"Expiry during backup accepted");check(timed.store.saves==0,"Expired guarded write reached commit");
        AssistantActions.Result second=AssistantActions.execute("preview_replan",input(),shot,"E2",true);check(second.proposal==null&&second.evidence.getJSONObject("data").getString("status").equals("not_applied"),"Second proposal allowed");
        check(action("preview_edit_course",input("course",cid,"field","notes","value","bad"),shot).proposal==null,"Unlisted field edited");
        for(String[] edit:new String[][]{{"priority","5"},{"daily_weight","2.5"},{"minimum_block","30"},{"deadline",DAY.plusDays(4).toString()},{"start_date",DAY.plusDays(1).toString()},{"auto_schedule","false"},{"total_minutes","180"}})check(action("preview_edit_course",input("course",cid,"field",edit[0],"value",edit[1]),shot).proposal!=null,"Course field unsupported: "+edit[0]);
        check(action("preview_add_course",input("name","新增合成","total_minutes","60","start_date",DAY.toString(),"deadline",DAY.plusDays(1).toString(),"minimum_block","30"),shot).proposal!=null,"Add course failed");
        AssistantActions.Result deletion=action("preview_delete_course",input("course",cid),shot);check(deletion.proposal.after.getJSONArray("courses").length()==0&&deletion.proposal.after.getJSONArray("tasks").length()==0,"Course deletion left tasks");
        JSONObject e=event("原事项",600,660);state.getJSONArray("fixedEvents").put(e);Snapshot eventShot=shot(state);String eid=e.getString("id");
        check(action("list_events",input("offset","0"),eventShot).evidence.getJSONObject("data").getInt("total")==1,"Event lookup missing");
        for(String[] edit:new String[][]{{"title","新事项"},{"start_date",DAY.plusDays(1).toString()},{"end_date",DAY.plusDays(1).toString()},{"start_time","10:15"},{"end_time","11:15"}})check(action("preview_edit_event",input("event",eid,"field",edit[0],"value",edit[1]),eventShot).proposal!=null,"Event field unsupported: "+edit[0]);
        JSONObject addition=input("title","冲突事项","start_date",DAY.toString(),"end_date",DAY.toString(),"start_time","10:30","end_time","11:30","weekdays","");check(action("preview_add_event",addition,eventShot).proposal==null,"Conflicting event automatically skipped");addition.put("start_time","13:00").put("end_time","14:00");check(action("preview_add_event",addition,eventShot).proposal!=null,"Add event failed");check(action("preview_delete_event",input("event",eid),eventShot).proposal.after.getJSONArray("fixedEvents").length()==0,"Delete full rule failed");
        JSONObject unscheduled=fixture();unscheduled.put("tasks",new JSONArray());check(action("preview_replan",input(),shot(unscheduled)).proposal.after.getJSONArray("tasks").length()>0,"Replan tool missing");
        JSONObject swap=DesktopParityTests.fixture();List<JSONObject> pending=DesktopParityTests.pending(swap);check(action("preview_swap_tasks",input("source",pending.get(0).getString("id"),"target",pending.get(1).getString("id")),new Snapshot(swap,Planner.at(DesktopParityTests.DAY,1080))).proposal!=null,"Task swap missing");
    }
    static JSONObject call(String id,String name,JSONObject input)throws Exception{return object("id",id,"type","function","function",object("name",name,"arguments",input.toString()));}
    static String response(JSONArray calls,String text)throws Exception{return object("choices",new JSONArray().put(object("finish_reason",calls.length()>0?"tool_calls":"stop","message",object("role","assistant","content",text,"tool_calls",calls)))).toString();}
    static Configuration configuration(String provider)throws Exception{return new Configuration(object("provider",provider,"baseURL","https://fixture.invalid/v1","model","synthetic-tool-model"));}
    static final class Source implements AssistantRunner.Source {
        final Store store;Source(Store store){this.store=store;}public Snapshot snapshot()throws Exception{return shot(store.load());}public void current(Snapshot shot)throws Exception{if(!shot.id.equals(signature(store.load())))throw new Changed();}
    }
    static final class Listener implements AssistantRunner.Listener {
        int approvals;AssistantActions.Proposal proposal;boolean allow=true;List<String> steps=new ArrayList<>();
        public boolean approve(AssistantRunner.Request request,JSONArray findings){approvals++;return allow;}public void activity(String text){steps.add(text);}public void proposal(AssistantActions.Proposal proposal){this.proposal=proposal;}
    }
    static void runners()throws Exception{
        Store store=new Store(fixture());Listener listener=new Listener();List<AssistantRunner.Request> requests=new ArrayList<>();String cid=store.state.getJSONArray("courses").getJSONObject(0).getString("id");
        AssistantRunner runner=new AssistantRunner(contract,(request,key,token)->{requests.add(request);switch(requests.size()){case 1:return response(new JSONArray().put(call("call-1","list_courses",input("offset","0"))),"");case 2:return response(new JSONArray().put(call("call-2","inspect_course",input("course",cid,"offset","0"))),"");default:return response(new JSONArray(),"剩余 **120 分钟**。[E2]");}},new Source(store),listener);
        String answer=runner.run(configuration("openai"),new JSONArray().put(input("role","user","content","还有多少学习量？")),"fixture-auth-value");check(answer.contains("120")&&!answer.contains("[E2]"),"Final answer wrong");check(listener.approvals==1&&runner.queries==2&&requests.size()==3,"Repeated approval or missing loop");check(!requests.get(0).body.contains("合成数学")&&requests.get(1).body.contains("合成数学")&&!requests.get(1).body.contains("本机备注"),"Unexpected outbound data");
        check(!requests.get(0).details().contains("fixture-auth-value")&&requests.get(0).details().contains("仅用于认证"),"Auth in request details");
        for(String model:new String[]{"o3","gpt-5.1"}){
            Configuration config=new Configuration(configuration("openai").json().put("model",model));AssistantRunner reasoning=new AssistantRunner(contract,(r,k,t)->{JSONObject p=new JSONObject(r.body);check(p.has("max_completion_tokens")&&!p.has("max_tokens")&&p.getJSONArray("messages").getJSONObject(0).getString("role").equals("developer"),"Reasoning model wire settings wrong");return response(new JSONArray(),"合成答复");},new Source(store),new Listener());reasoning.run(config,new JSONArray().put(input("role","user","content","合成")),"fixture-auth-value");
        }
        Listener denied=new Listener();denied.allow=false;AtomicInteger count=new AtomicInteger();AssistantRunner rejected=new AssistantRunner(contract,(r,k,t)->{count.incrementAndGet();return "";},new Source(store),denied);rejects(()->rejected.run(configuration("openai"),new JSONArray().put(input("role","user","content","合成问题")),"fixture-auth-value"),"Refusal ignored");check(count.get()==0,"Request sent before approval");
        AtomicInteger anthropicCalls=new AtomicInteger();Listener anthropicListener=new Listener();AssistantRunner anthropic=new AssistantRunner(contract,(request,key,token)->{
            JSONObject payload=new JSONObject(request.body);check(payload.has("system")&&payload.getJSONArray("tools").getJSONObject(0).has("input_schema"),"Anthropic schema wrong");
            if(anthropicCalls.getAndIncrement()==0)return object("stop_reason","tool_use","content",new JSONArray().put(input("type","tool_use","id","anthropic-1","name","inspect_rules","input",input()))).toString();
            JSONArray messages=payload.getJSONArray("messages");check(messages.getJSONObject(messages.length()-1).getJSONArray("content").getJSONObject(0).getString("type").equals("tool_result"),"Anthropic tool result misplaced");return object("stop_reason","end_turn","content",new JSONArray().put(input("type","text","text","已核对规则"))).toString();
        },new Source(store),anthropicListener);check(anthropic.run(configuration("anthropic"),new JSONArray().put(input("role","user","content","规则是什么？")),"fixture-auth-value").equals("已核对规则")&&anthropicListener.approvals==1,"Anthropic loop failed");
        Store changing=new Store(fixture());Listener refreshed=new Listener();AtomicInteger sends=new AtomicInteger();AssistantRunner stale=new AssistantRunner(contract,(r,k,t)->{if(sends.getAndIncrement()==0)changing.state.getJSONArray("courses").getJSONObject(0).put("name","更新后课程");return response(new JSONArray(),"最新回答");},new Source(changing),refreshed);check(stale.run(configuration("deepseek"),new JSONArray().put(input("role","user","content","课程？")),"fixture-auth-value").equals("最新回答")&&stale.rechecks==1&&refreshed.approvals==1,"Changed snapshot didn't requery with one approval");
        Listener proposal=new Listener();AtomicInteger turn=new AtomicInteger();AssistantRunner modifying=new AssistantRunner(contract,(r,k,t)->turn.getAndIncrement()==0?response(new JSONArray().put(call("edit-1","preview_edit_course",input("course",cid,"field","name","value","待确认名称"))),""):response(new JSONArray(),"请确认本机预览"),new Source(store),proposal);
        modifying.run(configuration("openai"),new JSONArray().put(input("role","user","content","修改课程名称")),"fixture-auth-value");check(proposal.proposal!=null&&store.saves==0,"Model wrote before confirmation");
        AssistantRunner bad=new AssistantRunner(contract,(r,k,t)->response(new JSONArray().put(call("unknown","run_command",input())),""),new Source(store),new Listener());rejects(()->bad.run(configuration("openai"),new JSONArray().put(input("role","user","content","合成")),"fixture-auth-value"),"Unknown tool reached native executor");
        AssistantRunner cancelled=new AssistantRunner(contract,(r,k,t)->{t.cancel();t.check();return "";},new Source(store),new Listener());rejects(()->cancelled.run(configuration("openai"),new JSONArray().put(input("role","user","content","合成")),"fixture-auth-value"),"Cancel ignored");
        for(String malformed:new String[]{"{}","{\"choices\":[]} ",response(new JSONArray(),"")+" trailing",object("choices",new JSONArray().put(input("finish_reason","length","message",input("content","截断回答")))).toString()}){
            AssistantRunner broken=new AssistantRunner(contract,(r,k,t)->malformed,new Source(store),new Listener());rejects(()->broken.run(configuration("openai"),new JSONArray().put(input("role","user","content","合成")),"fixture-auth-value"),"Incomplete response accepted");
        }
        String credential="sk"+"-synthetic-credential-12345";AssistantRunner leaking=new AssistantRunner(contract,(r,k,t)->response(new JSONArray(),credential),new Source(store),new Listener());rejects(()->leaking.run(configuration("openai"),new JSONArray().put(input("role","user","content","合成")),"fixture-auth-value"),"Secret answer persisted");
        Store changingAlways=new Store(fixture());AssistantRunner bounded=new AssistantRunner(contract,(r,k,t)->{changingAlways.state.getJSONArray("courses").getJSONObject(0).put("name",Planner.id());return response(new JSONArray(),"不可采用");},new Source(changingAlways),new Listener());rejects(()->bounded.run(configuration("openai"),new JSONArray().put(input("role","user","content","合成")),"fixture-auth-value"),"Continuous changes didn't stop");check(bounded.requests==4,"Requery limit changed");
    }
    static void privacyHistory()throws Exception{
        for(String text:new String[]{"sk"+"-synthetic-credential-12345","password"+"=synthetic-value","https://fixture.invalid/?token"+"=synthetic-value","{\"value\":\"\\u0073\\u006b-synthetic-credential-12345\"}","https://fixture.invalid/?%74oken=synthetic-value"})rejects(()->contract.check(text,""),"Credential escaped detection");
        rejects(()->contract.check("name includes fixture-auth-value","fixture-auth-value"),"Active key passed policy");check(contract.findings("姓名：合成用户，电话13800138000，诊断").length()>0,"Privacy summary missing");
        StringBuilder deep=new StringBuilder();for(int i=0;i<100;i++)deep.append('[');for(int i=0;i<100;i++)deep.append(']');rejects(()->contract.check(deep.toString(),""),"Nested response overflow not bounded");
        for(String endpoint:new String[]{"http://fixture.invalid","https://EXAMPLE_USERNAME:EXAMPLE_PASSWORD@fixture.invalid","https://fixture.invalid/?q=value","https://fixture.invalid/#fragment"})rejects(()->new Configuration(input("baseURL",endpoint,"model","fixture")).endpoint(),"Invalid recipient accepted");
        Path directory=temporary("study-assistant-tests-");
        try{
            File file=directory.resolve("workspace.json").toFile();AssistantHistory history=new AssistantHistory(file,contract);JSONObject workspace=history.load();history.save(workspace,Collections.emptySet());check(history.load().getJSONArray("conversations").length()==1,"History roundtrip failed");
            JSONObject conversation=AssistantHistory.selected(workspace);conversation.getJSONArray("entries").put(input("id",Planner.id(),"role","你","text","合成问题","status","处理中"));history.save(workspace,Collections.emptySet());check(AssistantHistory.selected(history.load()).getJSONArray("entries").getJSONObject(0).getString("status").contains("中断"),"Interrupted chat resumed");
            String original=new String(Files.readAllBytes(file.toPath()),java.nio.charset.StandardCharsets.UTF_8);workspace.getJSONArray("memories").put(input("id",Planner.id(),"text","fixture-auth-value","enabled",false));rejects(()->history.save(workspace,Collections.singleton("fixture-auth-value")),"Known key persisted in memory");check(original.equals(new String(Files.readAllBytes(file.toPath()),java.nio.charset.StandardCharsets.UTF_8)),"Failed save damaged file");
            Files.write(file.toPath(),"broken-json".getBytes(java.nio.charset.StandardCharsets.UTF_8));rejects(history::load,"Corrupt history accepted");check(Files.size(file.toPath())==11,"Corrupt original replaced");
            Files.delete(file.toPath());Files.createSymbolicLink(file.toPath(),directory.resolve("other.json"));rejects(history::load,"History symlink followed");
        }finally{try(java.util.stream.Stream<Path> paths=Files.walk(directory)){paths.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.deleteIfExists(p);}catch(Exception ignored){}});}}
    }
    static void session()throws Exception{
        Path dir=temporary("assistant-session-tests-");Store store=new Store(fixture());AssistantSession s=new AssistantSession(new AssistantHistory(dir.resolve("workspace.json").toFile(),contract),store,(r,k,t)->response(new JSONArray(),"合成答复"),()->{});
        try{
            s.queue.submit(()->{}).get();s.configure(configuration("openai").json(),"fixture-auth-value",false,null);s.queue.submit(()->{}).get();check(s.queue.submit(()->s.ready&&!s.key.isEmpty()).get(),"Session configure failed");
            CountDownLatch done=new CountDownLatch(1);s.attach(value->{if(value.approval!=null)s.decide(true);if(!value.busy)try{for(JSONObject e:Planner.list(AssistantHistory.selected(value.workspace).getJSONArray("entries")))if(e.optString("role").equals("助手"))done.countDown();}catch(Exception ignored){}});s.send("合成问题");check(done.await(5,TimeUnit.SECONDS),"Session never finished");
            s.newConversation();s.newConversation();s.queue.submit(()->{}).get();check(s.queue.submit(()->s.workspace.getJSONArray("conversations").length()).get()==3,"New conversation not persisted");
            s.queue.submit(()->{try{Set<String> ids=new HashSet<>();for(JSONObject c:Planner.list(s.workspace.getJSONArray("conversations")))ids.add(c.getString("id"));s.delete(ids);}catch(Exception error){throw new RuntimeException(error);}}).get();s.queue.submit(()->{}).get();check(s.queue.submit(()->s.workspace.getJSONArray("conversations").length()).get()==1,"Delete all didn't create blank chat");
            s.memory("","请简洁回答",false,false);s.queue.submit(()->{}).get();check(s.queue.submit(()->s.workspace.getJSONArray("memories").getJSONObject(0).getBoolean("enabled")).get()==false,"New memory enabled automatically");
            String selected=s.queue.submit(()->s.workspace.getString("selectedID")).get();Path original=dir.resolve("workspace.json"),preserved=dir.resolve("preserved.json");Files.move(original,preserved);Files.createSymbolicLink(original,preserved);
            s.delete(Collections.singleton(selected));s.queue.submit(()->{}).get();check(s.queue.submit(()->s.workspace.getString("selectedID").equals(selected)).get(),"Failed batch delete wasn't rolled back");Files.delete(original);Files.move(preserved,original);
            s.detach(s.view);s.queue.submit(()->{}).get();check(s.queue.submit(()->s.key.isEmpty()).get(),"Closing retained key");check(!new String(Files.readAllBytes(dir.resolve("workspace.json")),java.nio.charset.StandardCharsets.UTF_8).contains("fixture-auth-value"),"Key saved in workspace");
        }finally{s.queue.shutdownNow();s.network.shutdownNow();try(java.util.stream.Stream<Path> paths=Files.walk(dir)){paths.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.deleteIfExists(p);}catch(Exception ignored){}});}}
    }
    public static void main(String[] args)throws Exception{
        contract=new Contract(new JSONObject(read(new FileInputStream("Android/build/assets/assistant-contract.json"),100000)));tools();timeChecks();actions();runners();privacyHistory();session();System.out.println("AssistantTests: "+checks+" synthetic checks passed; no real API, credentials or personal data used");
    }
}
