package local.studyplanner;

import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;
import android.text.*;
import org.json.*;
import java.io.File;
import java.text.Normalizer;
import java.util.*;
import static local.studyplanner.AssistantProtocol.*;

/** Phone presentation of the Mac assistant workflow; no planner or credential data in Intents. */
public final class AssistantActivity extends Activity {
    private static AssistantSession shared;
    AssistantSession session;AssistantSession.State state;AssistantSession.View observer;
    LinearLayout root,chat,actions;ScrollView scroll;EditText question;TextView status,heading;Button send,stop,historyButton,apiButton,memoryButton,newButton,undo;
    boolean foreground,applying,rendering;int shown=40;String selected="",lastEntry="";final List<EditText> secretFields=new ArrayList<>();
    static synchronized AssistantSession get(Context context)throws Exception{
        if(shared==null){Context app=context.getApplicationContext();Contract contract=new Contract(new JSONObject(read(app.getAssets().open("assistant-contract.json"),100000)));
            shared=new AssistantSession(new AssistantHistory(new File(app.getFilesDir(),"assistant/workspace-v1.json"),contract),PlannerRuntime.get(app).database,new AssistantRunner.HTTP(),()->{
                app.sendBroadcast(new Intent(CloudSync.ACTION).setPackage(app.getPackageName()).putExtra("changed",true));CloudSync.get(app).request(null);
            });
        }return shared;
    }
    @Override public void onCreate(Bundle saved){super.onCreate(saved);getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);build();
        observer=value->runOnUiThread(()->{if(foreground&&!isDestroyed())render(value);});
        new Thread(()->{try{AssistantSession ready=get(this);runOnUiThread(()->{if(isDestroyed())return;session=ready;if(foreground)session.attach(observer);});}catch(Exception error){runOnUiThread(()->status.setText("助手未能打开，本机日程未改变。请重新打开或检查安装包。"));}},"assistant-open").start();
    }
    @Override protected void onStart(){super.onStart();foreground=true;if(session!=null)session.attach(observer);}
    @Override protected void onStop(){foreground=false;for(EditText field:secretFields)field.setText("");secretFields.clear();if(session!=null)session.detach(observer);super.onStop();}
    @Override public void onBackPressed(){if(applying||state!=null&&state.saving){Toast.makeText(this,"正在保存，请稍后",Toast.LENGTH_SHORT).show();return;}finish();}
    int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
    LinearLayout column(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.VERTICAL);return v;}
    LinearLayout row(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.HORIZONTAL);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    TextView text(String value,int size){return AssistantMarkdown.text(this,value,size);}
    Button button(String value,Runnable action){Button b=new Button(this);b.setText(value);b.setOnClickListener(v->{try{action.run();}catch(Exception error){notice("操作未完成，请核对输入后重试。");}});return b;}
    EditText field(LinearLayout parent,String label,String value){parent.addView(text(label,13));EditText edit=new EditText(this);edit.setSingleLine(true);edit.setText(value);edit.setSaveEnabled(false);edit.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);parent.addView(edit);return edit;}
    ScrollView scrolling(LinearLayout content){ScrollView v=new ScrollView(this);v.addView(content);return v;}
    void build(){
        root=column();root.setBackgroundColor(0xfff5f6f7);root.setFitsSystemWindows(true);root.setPadding(dp(12),dp(8),dp(12),dp(8));setContentView(root);
        LinearLayout top=row();top.addView(button("‹ 返回",this::onBackPressed));heading=text("智能助手",20);heading.setTypeface(null,Typeface.BOLD);top.addView(heading,new LinearLayout.LayoutParams(0,-2,1));newButton=button("新对话",()->session.newConversation());top.addView(newButton);root.addView(top);
        PlannerUi.Flow menu=new PlannerUi.Flow(this);historyButton=button("聊天记录",this::history);apiButton=button("API 设置",this::settings);memoryButton=button("本机记忆",this::memories);undo=button("撤销上次修改",()->session.undo());for(Button b:new Button[]{historyButton,apiButton,memoryButton,undo})menu.addView(b);root.addView(menu);
        status=text("正在读取本机聊天…",13);root.addView(status);scroll=new ScrollView(this);scroll.setFillViewport(true);chat=column();scroll.addView(chat);root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        question=new EditText(this);question.setHint("询问日程，或说明你想怎样调整");question.setMinLines(2);question.setMaxLines(5);question.setGravity(Gravity.TOP);question.setSaveEnabled(false);question.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);question.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE|android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);root.addView(question);
        question.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){if(!rendering&&state!=null&&state.busy&&session!=null)session.stop();}public void afterTextChanged(Editable e){}});
        actions=row();send=button("发送",()->{String text=question.getText().toString();if(!text.trim().isEmpty()&&session!=null){session.send(text);}});stop=button("停止",()->session.stop());Button retry=button("重试上次问题",()->{try{JSONArray entries=AssistantHistory.selected(state.workspace).getJSONArray("entries");for(int i=entries.length()-1;i>=0;i--)if(entries.getJSONObject(i).getString("role").equals("你")){session.send(entries.getJSONObject(i).getString("text"));break;}}catch(Exception ignored){}});actions.addView(send);actions.addView(stop);actions.addView(retry);root.addView(actions);
        send.setEnabled(false);newButton.setEnabled(false);historyButton.setEnabled(false);apiButton.setEnabled(false);memoryButton.setEnabled(false);undo.setEnabled(false);
    }
    LinearLayout card(){LinearLayout box=column();box.setPadding(dp(12),dp(10),dp(12),dp(10));android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(0xffffffff);bg.setCornerRadius(dp(12));box.setBackground(bg);LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,-2);params.setMargins(0,dp(6),0,dp(6));chat.addView(box,params);return box;}
    void render(AssistantSession.State value){
        if(isDestroyed())return;AssistantSession.State previous=state;state=value;applying=value.saving;
        rendering=true;try{
            JSONObject conversation=AssistantHistory.selected(value.workspace);String current=conversation.getString("id");if(!current.equals(selected)){selected=current;shown=40;question.setText("");lastEntry="";}
            JSONArray entries=conversation.getJSONArray("entries");if(value.busy&&(previous==null||!previous.busy))question.setText("");
            status.setText(value.message.isEmpty()?value.activity:value.message);send.setEnabled(value.ready&&!value.busy&&!value.saving);question.setEnabled(value.ready&&!value.saving);stop.setEnabled(value.busy);
            for(Button b:new Button[]{newButton,historyButton,apiButton,memoryButton})b.setEnabled(value.ready&&!value.saving);undo.setVisibility(value.undo?View.VISIBLE:View.GONE);undo.setEnabled(value.undo&&!value.busy&&!value.saving);
            chat.removeAllViews();if(entries.length()==0){LinearLayout intro=card();intro.addView(text("用自然语言查看和调整学习日程",21));intro.addView(text("可以问“今天有哪些安排”“这周实际学了多久”，也可以提出课程或事项修改。发送前核对接收方和课表范围；修改预览另行确认后才会保存。",15));intro.addView(text("API 密钥、聊天和记忆只保存在此手机，不进入课表同步或日程备份。",13));}
            int first=Math.max(0,entries.length()-shown);if(first>0)chat.addView(button("显示更早消息（还有 "+first+" 条）",()->{shown+=40;render(state);}));
            for(int i=first;i<entries.length();i++){JSONObject e=entries.getJSONObject(i);LinearLayout box=card();box.addView(text(e.getString("role")+(e.optString("status").equals("完成")?"":" · "+e.optString("status")),12));AssistantMarkdown.render(this,box,e.getString("text"));JSONArray steps=e.optJSONArray("steps");if(steps!=null&&steps.length()>0){final JSONArray details=steps;box.addView(button("查询过程（"+steps.length()+"步）",()->{StringBuilder s=new StringBuilder();for(int j=0;j<details.length();j++)s.append(j+1).append(". ").append(details.optString(j)).append('\n');showText("查询过程",s.toString());}));}}
            if(value.approval!=null){LinearLayout box=card();box.addView(text("课表内容确认",20));box.addView(text(value.approval.scope(),14));if(value.findings.length()>0)box.addView(text("本机隐私提示：\n"+value.findings.toString(),14));box.addView(button("查看本次发送详情",()->showText("精确请求 · 不含认证密钥",value.approval.details())));PlannerUi.Flow choices=new PlannerUi.Flow(this);choices.addView(button("确认本轮发送",()->session.decide(true)));choices.addView(button("拒绝",()->session.decide(false)));box.addView(choices);}
            if(value.change!=null&&!value.busy){LinearLayout box=card();box.addView(text("核对日程修改",20));box.addView(text(value.change.title+"\n"+value.change.summary,14));box.addView(text("两分钟、课表变化或任务开始后方案失效。尚未写入日程。",12));box.addView(button("展开全部差异并确认",()->review(value.change)));box.addView(button("取消方案",()->session.dismiss(value.change.id)));}
            if(value.busy&&value.approval==null)card().addView(text(value.activity,14));
            String tail=entries.length()==0?"":entries.getJSONObject(entries.length()-1).getString("id");boolean move=!lastEntry.equals(tail)||value.approval!=null||value.change!=null&&(previous==null||previous.change==null);lastEntry=tail;
            if(move)scroll.post(()->scroll.fullScroll(View.FOCUS_DOWN));
        }catch(Exception error){status.setText(HISTORY);}finally{rendering=false;}
    }
    void notice(String message){new AlertDialog.Builder(this).setMessage(message).setPositiveButton("好",null).show();}
    void showText(String title,String value){LinearLayout body=column();body.setPadding(dp(16),dp(8),dp(16),dp(8));TextView text=text("",14);text.setText(value);body.addView(text);AlertDialog d=new AlertDialog.Builder(this).setTitle(title).setView(scrolling(body)).setPositiveButton("关闭",null).create();d.show();d.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);}
    void review(AssistantActions.Proposal proposal){
        LinearLayout body=column();body.setPadding(dp(14),0,dp(14),0);body.addView(text(proposal.title+"\n"+proposal.summary,14));TextView pageLabel=text("",13),detail=text("",14);body.addView(pageLabel);ScrollView list=new ScrollView(this);list.addView(detail);body.addView(list,new LinearLayout.LayoutParams(-1,dp(300)));LinearLayout nav=row();body.addView(nav);int[] page={0};Set<Integer> visited=new HashSet<>();int pages=Math.max(1,(proposal.details.size()+24)/25);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("核对日程修改").setView(body).setNegativeButton("返回",null).setPositiveButton("确认应用",null).create();
        Runnable render=()->{visited.add(page[0]);StringBuilder value=new StringBuilder();for(int i=page[0]*25;i<Math.min(proposal.details.size(),(page[0]+1)*25);i++)value.append(i+1).append(". ").append(proposal.details.get(i)).append("\n\n");detail.setText(value);pageLabel.setText("全部差异 · "+(page[0]+1)+" / "+pages+" 页");list.scrollTo(0,0);if(dialog.isShowing())dialog.getButton(-1).setEnabled(visited.size()==pages);};
        nav.addView(button("上一页",()->{if(page[0]>0){page[0]--;render.run();}}));nav.addView(button("下一页",()->{if(page[0]+1<pages){page[0]++;render.run();}}));dialog.setOnShowListener(d->{render.run();dialog.getButton(-1).setOnClickListener(v->{applying=true;session.apply(proposal.id);dialog.dismiss();});});dialog.show();dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
    void settings(){
        try{
            JSONObject saved=state.workspace.getJSONObject("configuration");LinearLayout body=column();body.setPadding(dp(16),0,dp(16),0);body.addView(text("支持工具调用的模型；密钥仅用于当前地址的认证，不进入聊天、记忆、备份或同步。",13));Spinner provider=new Spinner(this);String[] ids={"openai","deepseek","anthropic"},names={"OpenAI / 兼容接口","DeepSeek","Anthropic"};provider.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,names));int selected=Arrays.asList(ids).indexOf(saved.optString("provider"));provider.setSelection(Math.max(0,selected));body.addView(provider);
            EditText endpoint=field(body,"HTTPS 服务地址",saved.getString("baseURL")),model=field(body,"模型名称",saved.getString("model")),key=field(body,"API 密钥（不回显已存密钥）","");key.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);secretFields.add(key);
            body.addView(text(state.keyLoaded?"本次会话已载入密钥；关闭后需主动重新载入。":"本次会话尚未载入密钥。",12));
            int[] last={Math.max(0,selected)};provider.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener(){public void onNothingSelected(android.widget.AdapterView<?> p){}public void onItemSelected(android.widget.AdapterView<?> p,View view,int n,long id){if(n!=last[0]){last[0]=n;endpoint.setText(n==1?"https://api.deepseek.com/v1":n==2?"https://api.anthropic.com/v1":"https://api.openai.com/v1");key.setText("");}}});
            AlertDialog dialog=new AlertDialog.Builder(this).setTitle("API 设置").setView(scrolling(body)).setNegativeButton("关闭",null).create();
            java.util.function.Supplier<JSONObject> config=()->{try{return object("provider",ids[provider.getSelectedItemPosition()],"baseURL",endpoint.getText().toString().trim(),"model",model.getText().toString().trim());}catch(Exception e){return new JSONObject();}};
            body.addView(button("仅在本次会话使用",()->{session.configure(config.get(),key.getText().toString(),false,null);dialog.dismiss();}));
            body.addView(button("保存到本机安全存储",()->{String typed=key.getText().toString();session.configure(config.get(),typed,true,c->{AssistantVault.save(getApplicationContext(),c,typed);return typed;});dialog.dismiss();}));
            body.addView(button("载入已保存密钥",()->{session.configure(config.get(),"",false,c->AssistantVault.load(getApplicationContext(),c));dialog.dismiss();}));
            dialog.setOnDismissListener(d->{key.setText("");secretFields.remove(key);});dialog.show();dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        }catch(Exception error){notice("无法读取助手配置。");}
    }
    String normalized(String value){return Normalizer.normalize(value,Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);}
    void history(){
        if(state==null)return;LinearLayout body=column();body.setPadding(dp(12),0,dp(12),0);EditText query=field(body,"搜索聊天内容","");PlannerUi.Flow menu=new PlannerUi.Flow(this);body.addView(menu);LinearLayout list=column();ScrollView scrolling=scrolling(list);body.addView(scrolling,new LinearLayout.LayoutParams(-1,dp(350)));Set<String> selected=new HashSet<>();boolean[] multi={false};List<JSONObject> visible=new ArrayList<>();
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("聊天记录").setView(body).setNegativeButton("关闭",null).create();Runnable[] render={null};
        Runnable remove=()->{if(selected.isEmpty())return;confirmDelete(new HashSet<>(selected),()->dialog.dismiss());};
        menu.addView(button("多选",()->{multi[0]=!multi[0];selected.clear();render[0].run();}));menu.addView(button("全选搜索结果",()->{multi[0]=true;for(JSONObject c:visible)selected.add(c.optString("id"));render[0].run();}));menu.addView(button("删除所选",remove));menu.addView(button("清空全部",()->{Set<String> all=new HashSet<>();for(JSONObject c:Planner.list(state.workspace.optJSONArray("conversations")))all.add(c.optString("id"));confirmDelete(all,dialog::dismiss);}));
        render[0]=()->{list.removeAllViews();visible.clear();String term=normalized(query.getText().toString());List<JSONObject> conversations=new ArrayList<>(Planner.list(state.workspace.optJSONArray("conversations")));conversations.sort((a,b)->Double.compare(b.optDouble("updatedAt"),a.optDouble("updatedAt")));
            for(JSONObject c:conversations){if(!term.isEmpty()&&!normalized(c.toString()).contains(term))continue;visible.add(c);LinearLayout line=row();String id=c.optString("id");if(multi[0]){CheckBox check=new CheckBox(this);check.setChecked(selected.contains(id));check.setOnCheckedChangeListener((v,on)->{if(on)selected.add(id);else selected.remove(id);});line.addView(check);}
                JSONArray entries=c.optJSONArray("entries");String preview=entries==null||entries.length()==0?"暂无消息":trim(entries.optJSONObject(entries.length()-1).optString("text"),55);
                Button open=button(AssistantHistory.title(c)+"\n"+Planner.date(c.optDouble("updatedAt"))+" "+Planner.clock(c.optDouble("updatedAt"))+" · "+preview,()->{if(multi[0]){if(!selected.add(id))selected.remove(id);render[0].run();}else{session.select(id);dialog.dismiss();}});open.setSingleLine(false);open.setMaxLines(3);open.setGravity(Gravity.START|Gravity.CENTER_VERTICAL);line.addView(open,new LinearLayout.LayoutParams(0,-2,1));line.addView(button("⋯",()->confirmDelete(Collections.singleton(id),dialog::dismiss)));list.addView(line);
            }if(visible.isEmpty())list.addView(text("没有匹配的对话",14));};
        query.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){render[0].run();}public void afterTextChanged(Editable e){}});render[0].run();dialog.show();dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
    void confirmDelete(Set<String> ids,Runnable close){StringBuilder titles=new StringBuilder();for(JSONObject c:Planner.list(state.workspace.optJSONArray("conversations")))if(ids.contains(c.optString("id")))titles.append("• ").append(AssistantHistory.title(c)).append('\n');new AlertDialog.Builder(this).setTitle("删除 "+ids.size()+" 段对话？").setMessage(titles+"\n仅删除此手机的聊天；日程与独立记忆保留，已发送内容无法撤回。").setNegativeButton("取消",null).setPositiveButton("删除",(d,w)->{session.delete(ids);close.run();}).show();}
    void memories(){
        LinearLayout body=column();body.setPadding(dp(14),0,dp(14),0);body.addView(text("记忆默认关闭；主动启用后随问题发送。记忆不代表当前课表事实，也不能授权修改或跳过确认。请勿保存密钥。",14));AlertDialog dialog=new AlertDialog.Builder(this).setTitle("本机记忆").setView(scrolling(body)).setNegativeButton("关闭",null).create();body.addView(button("添加记忆",()->{dialog.dismiss();editMemory(null);}));
        for(JSONObject memory:Planner.list(state.workspace.optJSONArray("memories"))){CheckBox enabled=new CheckBox(this);enabled.setText(memory.optString("text"));enabled.setChecked(memory.optBoolean("enabled"));enabled.setOnCheckedChangeListener((v,on)->session.memory(memory.optString("id"),memory.optString("text"),on,false));body.addView(enabled);PlannerUi.Flow actions=new PlannerUi.Flow(this);actions.addView(button("编辑",()->{dialog.dismiss();editMemory(memory);}));actions.addView(button("删除",()->new AlertDialog.Builder(this).setTitle("删除这条本机记忆？").setNegativeButton("取消",null).setPositiveButton("删除",(d,w)->{session.memory(memory.optString("id"),"",false,true);dialog.dismiss();}).show()));body.addView(actions);}dialog.show();dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
    void editMemory(JSONObject memory){LinearLayout body=column();body.setPadding(dp(16),0,dp(16),0);EditText edit=field(body,"回答偏好或背景（最多2000字节）",memory==null?"":memory.optString("text"));edit.setSingleLine(false);edit.setMinLines(4);new AlertDialog.Builder(this).setTitle(memory==null?"添加记忆":"编辑记忆").setView(body).setNegativeButton("取消",null).setPositiveButton("保存",(d,w)->session.memory(memory==null?"":memory.optString("id"),edit.getText().toString(),memory!=null&&memory.optBoolean("enabled"),false)).show();}
}
