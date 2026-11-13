package local.studyplanner;

import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;
import android.text.*;
import org.json.*;
import java.text.Normalizer;
import java.util.*;
import static local.studyplanner.AssistantProtocol.*;

/** Phone presentation of the Mac assistant workflow; no planner or credential data in Intents. */
public final class AssistantActivity extends Activity {
    private static AssistantSession shared;
    AssistantSession session;AssistantSession.State state;AssistantSession.View observer;
    FrameLayout surface,drawer;LinearLayout root,chat,composer,historyList;PlannerUi.Flow historyActions;ScrollView scroll;EditText question,historyQuery;TextView status,heading;Button send,stop,retry,historyButton,apiButton,memoryButton,newButton,undo;
    boolean multiHistory;final Set<String> historySelection=new HashSet<>();final List<JSONObject> visibleHistory=new ArrayList<>();
    boolean foreground,applying,rendering;int shown=40;String selected="",lastEntry="";final List<EditText> secretFields=new ArrayList<>();
    static synchronized AssistantSession get(Context context)throws Exception{
        if(shared==null){Context app=context.getApplicationContext();Contract contract=new Contract(new JSONObject(read(app.getAssets().open("assistant-contract.json"),100000)));
            shared=new AssistantSession(new AssistantHistory(app.getFilesDir(),contract),PlannerRuntime.get(app).database,new AssistantRunner.HTTP(),()->{
                app.sendBroadcast(new Intent(CloudSync.ACTION).setPackage(app.getPackageName()).putExtra("changed",true));CloudSync.get(app).request(null);
            });
        }return shared;
    }
    @Override public void onCreate(Bundle saved){super.onCreate(saved);getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);build();
        observer=value->runOnUiThread(()->{if(foreground&&!isDestroyed())render(value);});
        new Thread(()->{try{AssistantSession ready=get(this);runOnUiThread(()->{if(isDestroyed())return;session=ready;if(foreground)session.attach(observer);});}catch(Exception error){runOnUiThread(()->{if(isDestroyed())return;status.setText("助手未能打开，本机日程未改变。请点击“重新读取聊天”重试或检查安装包。");retry.setVisibility(View.VISIBLE);retry.setEnabled(true);});}},"assistant-open").start();
    }
    @Override protected void onStart(){super.onStart();foreground=true;if(session!=null)session.attach(observer);}
    @Override protected void onStop(){foreground=false;for(EditText field:secretFields)field.setText("");secretFields.clear();if(session!=null)session.detach(observer);super.onStop();}
    @Override public void onBackPressed(){if(drawer!=null&&drawer.getVisibility()==View.VISIBLE){closeHistory();return;}if(applying||state!=null&&state.saving){Toast.makeText(this,"正在保存，请稍后",Toast.LENGTH_SHORT).show();return;}finish();}
    int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
    LinearLayout column(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.VERTICAL);return v;}
    LinearLayout row(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.HORIZONTAL);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    TextView text(String value,int size){return AssistantMarkdown.text(this,value,size);}
    Button button(String value,Runnable action){Button b=new Button(this);b.setText(value);PlannerUi.styleButton(b);AssistantUi.tone(b,false);b.setOnClickListener(v->{try{action.run();}catch(Exception error){notice("操作未完成，请核对输入后重试。");}});return b;}
    EditText field(LinearLayout parent,String label,String value){parent.addView(text(label,13));EditText edit=new EditText(this);edit.setSingleLine(true);edit.setText(value);PlannerUi.styleField(edit);edit.setSaveEnabled(false);edit.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);parent.addView(edit);return edit;}
    ScrollView scrolling(LinearLayout content){ScrollView v=new ScrollView(this);v.addView(content);return v;}
    void build(){
        getWindow().setStatusBarColor(AssistantUi.WHITE);getWindow().setNavigationBarColor(AssistantUi.WHITE);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|(Build.VERSION.SDK_INT>=26?View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR:0));
        surface=new FrameLayout(this);surface.setFitsSystemWindows(true);surface.setBackgroundColor(AssistantUi.WHITE);setContentView(surface);
        root=column();root.setFocusableInTouchMode(true);surface.addView(root,new FrameLayout.LayoutParams(-1,-1));
        LinearLayout top=row();top.setPadding(dp(8),dp(2),dp(8),dp(2));
        historyButton=AssistantUi.icon(this,AssistantUi.MENU,"打开聊天记录",false,this::history);top.addView(historyButton,new LinearLayout.LayoutParams(dp(48),dp(48)));
        heading=text("新对话",17);heading.setTextIsSelectable(false);heading.setSingleLine(true);heading.setEllipsize(TextUtils.TruncateAt.END);heading.setGravity(Gravity.CENTER);heading.setTypeface(null,Typeface.BOLD);top.addView(heading,new LinearLayout.LayoutParams(0,-2,1));
        newButton=AssistantUi.icon(this,AssistantUi.NEW,"新对话",false,()->{if(session!=null)session.newConversation();});top.addView(newButton,new LinearLayout.LayoutParams(dp(48),dp(48)));root.addView(top);
        scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setClipToPadding(false);scroll.setPadding(dp(20),0,dp(20),dp(12));chat=column();scroll.addView(chat);root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout bottom=column();bottom.setPadding(dp(12),dp(4),dp(12),dp(8));root.addView(bottom);
        status=text("正在读取本机聊天…",13);status.setTextColor(AssistantUi.MUTED);status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);status.setPadding(dp(8),dp(4),dp(8),dp(4));bottom.addView(status);
        retry=button("重新读取聊天",this::retry);AssistantUi.quiet(retry);bottom.addView(retry);retry.setVisibility(View.GONE);
        composer=row();composer.setGravity(Gravity.BOTTOM);composer.setPadding(dp(8),dp(6),dp(8),dp(8));composer.setBackground(AssistantUi.shape(this,AssistantUi.SURFACE,24));bottom.addView(composer);
        question=new EditText(this);question.setHint("给学习助手发送消息");question.setContentDescription("消息输入框");question.setMinLines(1);question.setMaxLines(5);question.setGravity(Gravity.TOP);question.setTextSize(16);question.setTextColor(AssistantUi.INK);question.setHintTextColor(AssistantUi.MUTED);question.setPadding(dp(8),dp(10),dp(8),dp(10));question.setBackgroundColor(android.graphics.Color.TRANSPARENT);question.setSaveEnabled(false);question.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);question.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE|android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);question.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI);composer.addView(question,new LinearLayout.LayoutParams(0,-2,1));
        LinearLayout tools=column();composer.addView(tools);PlannerUi.Flow options=new PlannerUi.Flow(this);bottom.addView(options,new LinearLayout.LayoutParams(-1,-2));
        apiButton=button("API 设置",this::settings);memoryButton=button("本机记忆",this::memories);for(Button b:new Button[]{apiButton,memoryButton}){b.setTextSize(12);b.setPadding(dp(10),dp(8),dp(10),dp(8));AssistantUi.quiet(b);options.addView(b);}
        send=AssistantUi.icon(this,AssistantUi.SEND,"发送消息",true,()->{if(session!=null)session.send(question.getText().toString());});stop=AssistantUi.icon(this,AssistantUi.STOP,"停止回答",true,()->{if(session!=null)session.stop();});tools.addView(send,new LinearLayout.LayoutParams(dp(48),dp(48)));tools.addView(stop,new LinearLayout.LayoutParams(dp(48),dp(48)));stop.setVisibility(View.GONE);
        question.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){if(!rendering&&state!=null&&state.busy&&session!=null)session.stop();updateSend();}public void afterTextChanged(Editable e){}});
        undo=button("撤销上次修改",()->session.undo());buildHistory();
        for(Button b:new Button[]{send,stop,retry,newButton,historyButton,apiButton,memoryButton,undo})b.setEnabled(false);question.setEnabled(false);undo.setVisibility(View.GONE);
    }
    void updateSend(){send.setEnabled(state!=null&&state.ready&&!state.busy&&!state.saving&&!question.getText().toString().trim().isEmpty());}
    void hideKeyboard(){((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(question.getWindowToken(),0);question.clearFocus();}
    void welcome(){
        LinearLayout intro=column();intro.setGravity(Gravity.CENTER);intro.setPadding(dp(8),dp(32),dp(8),dp(32));chat.addView(intro,new LinearLayout.LayoutParams(-1,-2));
        ImageView mark=new ImageView(this);mark.setImageDrawable(new AssistantUi.Symbol(AssistantUi.CHAT,AssistantUi.BLUE));mark.setPadding(dp(13),dp(13),dp(13),dp(13));mark.setBackground(AssistantUi.shape(this,AssistantUi.PALE,20));intro.addView(mark,new LinearLayout.LayoutParams(dp(56),dp(56)));
        TextView title=text("今天想怎么安排？",22);title.setTypeface(null,Typeface.BOLD);title.setGravity(Gravity.CENTER);title.setPadding(0,dp(20),0,dp(8));intro.addView(title);
        TextView hint=text("查日程、看进度，或一起调整学习计划",14);hint.setGravity(Gravity.CENTER);hint.setTextColor(AssistantUi.MUTED);intro.addView(hint);
        for(String prompt:new String[]{"今天有哪些学习安排？","看看各门课程的学习进度","用图表对比近七天实际和计划学习量","帮我分析近期的排程和冲突"}){Button suggestion=button(prompt,()->{question.setText(prompt);question.setSelection(question.length());question.requestFocus();});suggestion.setEnabled(state!=null&&state.ready);suggestion.setTextSize(14);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-2,-2);p.topMargin=dp(10);intro.addView(suggestion,p);}
    }
    void retry(){
        if(session==null){recreate();return;}
        if(state==null||!state.ready){session.reloadHistory();return;}
        try{JSONArray entries=AssistantHistory.selected(state.workspace).getJSONArray("entries");for(int i=entries.length()-1;i>=0;i--)if(entries.getJSONObject(i).getString("role").equals("你")){session.send(entries.getJSONObject(i).getString("text"));break;}}catch(Exception error){notice(HISTORY);}
    }
    LinearLayout card(){LinearLayout box=column();box.setPadding(dp(16),dp(14),dp(16),dp(14));box.setBackground(AssistantUi.shape(this,AssistantUi.PALE,18));LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(-1,-2);params.setMargins(0,dp(8),0,dp(8));chat.addView(box,params);return box;}
    void message(JSONObject entry)throws Exception{
        boolean user=entry.getString("role").equals("你");LinearLayout line=column();line.setGravity(user?Gravity.END:Gravity.START);line.setPadding(user?dp(36):0,dp(10),0,dp(14));chat.addView(line,new LinearLayout.LayoutParams(-1,-2));
        LinearLayout box=column();if(user){box.setPadding(dp(16),dp(10),dp(16),dp(10));box.setBackground(AssistantUi.shape(this,AssistantUi.PALE,20));}else{TextView label=text(entry.getString("role").equals("助手")?"学习助手":"本机操作",12);label.setTextColor(AssistantUi.BLUE);box.addView(label);}line.addView(box,new LinearLayout.LayoutParams(user?-2:-1,-2));
        if(user)box.addView(text(entry.getString("text"),16));else AssistantMarkdown.render(this,box,entry.getString("text"));
        if(!user){AssistantInsightView.cards(this,box,entry.optJSONArray("insights"));JSONObject summary=entry.optJSONObject("changeSummary");if(summary!=null){LinearLayout preview=AssistantInsightView.render(this,box,summary);preview.addView(text("预览快照不代表已应用 · 当前结果请以日程与本机操作记录为准",12));}PlannerUi.Flow actions=new PlannerUi.Flow(this);actions.addView(button("复制回答",()->{try{AssistantInsightView.copy(this,AssistantInsights.entryText(entry));}catch(Exception e){notice("复制失败，请重试。");}}));box.addView(actions,new LinearLayout.LayoutParams(-1,-2));}
        if(!entry.optString("status").equals("完成")){TextView label=text(entry.optString("status"),12);label.setTextColor(AssistantUi.MUTED);line.addView(label);}
        JSONArray steps=entry.optJSONArray("steps");if(steps!=null&&steps.length()>0){Button detail=button("查询过程 · "+steps.length()+" 步",()->{StringBuilder s=new StringBuilder();for(int j=0;j<steps.length();j++)s.append(j+1).append(". ").append(steps.optString(j)).append('\n');showText("查询过程",s.toString());});AssistantUi.quiet(detail);line.addView(detail);}
    }
    void render(AssistantSession.State value){
        if(isDestroyed())return;AssistantSession.State previous=state;state=value;applying=value.saving;
        rendering=true;try{
            JSONObject conversation=AssistantHistory.selected(value.workspace);String current=conversation.getString("id");if(!current.equals(selected)){selected=current;shown=40;question.setText("");lastEntry="";}
            JSONArray entries=conversation.getJSONArray("entries");if(value.busy&&(previous==null||!previous.busy))question.setText("");
            heading.setText(entries.length()==0?"新对话":AssistantHistory.title(conversation));
            status.setText(value.message.isEmpty()?value.activity:value.message);status.setVisibility(!value.message.isEmpty()||!value.ready||value.busy||value.saving?View.VISIBLE:View.GONE);question.setEnabled(value.ready&&!value.saving);stop.setEnabled(value.busy);send.setVisibility(value.busy?View.GONE:View.VISIBLE);stop.setVisibility(value.busy?View.VISIBLE:View.GONE);updateSend();
            retry.setText(value.ready?"重试上次问题":"重新读取聊天");retry.setEnabled(!value.busy&&!value.saving&&(!value.ready||entries.length()>0));retry.setVisibility(!value.busy&&!value.saving&&(!value.ready||!value.message.isEmpty()&&entries.length()>0)?View.VISIBLE:View.GONE);
            for(Button b:new Button[]{newButton,historyButton,apiButton,memoryButton})b.setEnabled(value.ready&&!value.saving);undo.setVisibility(value.undo?View.VISIBLE:View.GONE);undo.setEnabled(value.undo&&!value.busy&&!value.saving);
            int oldY=scroll.getScrollY();boolean nearBottom=chat.getHeight()-scroll.getHeight()-oldY<dp(80);
            chat.removeAllViews();chat.setGravity(entries.length()==0?Gravity.CENTER_VERTICAL:Gravity.TOP);if(entries.length()==0)welcome();
            int first=Math.max(0,entries.length()-shown);if(first>0)chat.addView(button("显示更早消息（还有 "+first+" 条）",()->{shown+=40;render(state);}));
            View replyAnchor=null;for(int i=first;i<entries.length();i++){message(entries.getJSONObject(i));if(i==entries.length()-1&&entries.getJSONObject(i).optString("role").equals("助手"))replyAnchor=chat.getChildAt(chat.getChildCount()-1);}
            if(value.approval!=null){LinearLayout box=card();box.addView(text("课表内容确认",20));box.addView(text(value.approval.scope(),14));if(value.findings.length()>0)box.addView(text("本机隐私提示：\n"+value.findings.toString(),14));box.addView(button("查看本次发送详情",()->showText("精确请求 · 不含认证密钥",value.approval.details())));PlannerUi.Flow choices=new PlannerUi.Flow(this);Button approve=button("确认本轮发送",()->session.decide(true));AssistantUi.tone(approve,true);choices.addView(approve);choices.addView(button("拒绝",()->session.decide(false)));box.addView(choices);}
            if(value.change!=null&&!value.busy){LinearLayout box=card();box.addView(text("核对日程修改",20));box.addView(text(value.change.title,16));box.addView(text("尚未写入日程。两分钟、课表变化或任务开始后方案失效。",12));Button review=button("核对全部差异",()->review(value.change));AssistantUi.tone(review,true);box.addView(review,new LinearLayout.LayoutParams(-1,-2));PlannerUi.Flow secondary=new PlannerUi.Flow(this);Button cancel=button("取消方案",()->session.dismiss(value.change.id));AssistantUi.quiet(cancel);secondary.addView(cancel);box.addView(secondary);if(replyAnchor==null)replyAnchor=box;}
            String tail=entries.length()==0?"":entries.getJSONObject(entries.length()-1).getString("id");boolean move=!lastEntry.equals(tail)||value.approval!=null||value.change!=null&&(previous==null||previous.change==null);lastEntry=tail;
            final View completedReply=replyAnchor;if(previous!=null&&previous.busy&&!value.busy&&completedReply!=null)scroll.post(()->scroll.scrollTo(0,completedReply.getTop()));else if(move&&(nearBottom||previous==null||!current.equals(previous.workspace.optString("selectedID"))||value.busy))scroll.post(()->scroll.scrollTo(0,chat.getHeight()));else scroll.post(()->scroll.scrollTo(0,oldY));
            if(drawer.getVisibility()==View.VISIBLE){if(value.saving)closeHistory();else renderHistory();}
        }catch(Exception error){status.setText(HISTORY);status.setVisibility(View.VISIBLE);}finally{rendering=false;}
    }
    void notice(String message){new AlertDialog.Builder(this).setMessage(message).setPositiveButton("好",null).show();}
    void showText(String title,String value){LinearLayout body=column();body.setPadding(dp(16),dp(8),dp(16),dp(8));TextView text=text("",14);text.setText(value);body.addView(text);AlertDialog d=new AlertDialog.Builder(this).setTitle(title).setView(scrolling(body)).setPositiveButton("关闭",null).create();d.show();d.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);}
    void review(AssistantActions.Proposal proposal){
        LinearLayout body=column();body.setPadding(dp(14),0,dp(14),0);body.addView(text(proposal.title+"\n"+proposal.summary,14));TextView pageLabel=text("",13),detail=text("",14);body.addView(pageLabel);ScrollView list=new ScrollView(this);list.addView(detail);body.addView(list,new LinearLayout.LayoutParams(-1,dp(300)));PlannerUi.Flow nav=new PlannerUi.Flow(this);body.addView(nav);int[] page={0};Set<Integer> visited=new HashSet<>();int pages=Math.max(1,(proposal.details.size()+24)/25);
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
    void buildHistory(){
        drawer=new FrameLayout(this);drawer.setVisibility(View.GONE);surface.addView(drawer,new FrameLayout.LayoutParams(-1,-1));
        View scrim=new View(this);scrim.setBackgroundColor(0x55202738);scrim.setContentDescription("关闭聊天记录");scrim.setOnClickListener(v->closeHistory());drawer.addView(scrim,new FrameLayout.LayoutParams(-1,-1));
        LinearLayout panel=column();panel.setClickable(true);panel.setBackgroundColor(AssistantUi.WHITE);panel.setPadding(dp(16),dp(8),dp(16),dp(12));
        FrameLayout.LayoutParams size=new FrameLayout.LayoutParams(Math.min(dp(344),getResources().getDisplayMetrics().widthPixels-dp(48)),-1,Gravity.START);ScrollView panelScroll=scrolling(panel);panelScroll.setFillViewport(true);panelScroll.setBackgroundColor(AssistantUi.WHITE);drawer.addView(panelScroll,size);
        LinearLayout top=row();TextView title=text("聊天记录",20);title.setTypeface(null,Typeface.BOLD);top.addView(title,new LinearLayout.LayoutParams(0,-2,1));top.addView(AssistantUi.icon(this,AssistantUi.CLOSE,"关闭聊天记录",false,this::closeHistory),new LinearLayout.LayoutParams(dp(48),dp(48)));panel.addView(top);
        Button fresh=button("＋  新对话",()->{closeHistory();session.newConversation();});AssistantUi.tone(fresh,true);panel.addView(fresh,new LinearLayout.LayoutParams(-1,-2));
        historyQuery=new EditText(this);historyQuery.setHint("搜索聊天内容");historyQuery.setContentDescription("搜索聊天内容");historyQuery.setSingleLine(true);historyQuery.setSaveEnabled(false);historyQuery.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);historyQuery.setTextSize(14);historyQuery.setTextColor(AssistantUi.INK);historyQuery.setHintTextColor(AssistantUi.MUTED);historyQuery.setPadding(dp(14),dp(12),dp(14),dp(12));historyQuery.setBackground(AssistantUi.shape(this,AssistantUi.SURFACE,16));LinearLayout.LayoutParams searchSize=new LinearLayout.LayoutParams(-1,-2);searchSize.setMargins(0,dp(12),0,dp(4));panel.addView(historyQuery,searchSize);
        Button manage=button("管理聊天记录",()->{multiHistory=!multiHistory;historySelection.clear();renderHistory();});AssistantUi.quiet(manage);panel.addView(manage);
        historyActions=new PlannerUi.Flow(this);historyActions.addView(button("全选结果",()->{for(JSONObject c:visibleHistory)historySelection.add(c.optString("id"));renderHistory();}));historyActions.addView(button("删除所选",()->{if(!historySelection.isEmpty())confirmDelete(new HashSet<>(historySelection),this::closeHistory);}));historyActions.addView(button("清空全部",()->{Set<String> all=new HashSet<>();for(JSONObject c:Planner.list(state.workspace.optJSONArray("conversations")))all.add(c.optString("id"));confirmDelete(all,this::closeHistory);}));panel.addView(historyActions);
        historyList=column();ScrollView conversations=scrolling(historyList);conversations.setMinimumHeight(dp(120));panel.addView(conversations,new LinearLayout.LayoutParams(-1,0,1));
        View rule=new View(this);rule.setBackgroundColor(AssistantUi.LINE);panel.addView(rule,new LinearLayout.LayoutParams(-1,dp(1)));
        PlannerUi.Flow footer=new PlannerUi.Flow(this);footer.addView(button("API 设置",()->{closeHistory();settings();}));footer.addView(button("本机记忆",()->{closeHistory();memories();}));panel.addView(footer);panel.addView(undo);
        Button back=button("返回学习日程",()->{closeHistory();onBackPressed();});AssistantUi.quiet(back);panel.addView(back);
        historyQuery.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){renderHistory();}public void afterTextChanged(Editable e){}});
    }
    void history(){
        if(state==null||!state.ready||state.saving)return;hideKeyboard();multiHistory=false;historySelection.clear();historyQuery.setText("");renderHistory();drawer.setVisibility(View.VISIBLE);root.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);drawer.requestFocus();
    }
    void closeHistory(){
        ((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(historyQuery.getWindowToken(),0);historyQuery.clearFocus();drawer.setVisibility(View.GONE);root.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO);
    }
    void renderHistory(){
        if(state==null)return;historyActions.setVisibility(multiHistory?View.VISIBLE:View.GONE);historyList.removeAllViews();visibleHistory.clear();String term=normalized(historyQuery.getText().toString());List<JSONObject> conversations=new ArrayList<>(Planner.list(state.workspace.optJSONArray("conversations")));conversations.sort((a,b)->Double.compare(b.optDouble("updatedAt"),a.optDouble("updatedAt")));
        for(JSONObject c:conversations){
            if(!term.isEmpty()&&!normalized(c.toString()).contains(term))continue;visibleHistory.add(c);String id=c.optString("id");LinearLayout line=row();
            if(multiHistory){CheckBox check=new CheckBox(this);check.setContentDescription("选择对话："+AssistantHistory.title(c));check.setChecked(historySelection.contains(id));check.setOnCheckedChangeListener((v,on)->{if(on)historySelection.add(id);else historySelection.remove(id);});line.addView(check);}
            Button open=button(AssistantHistory.title(c)+"\n"+Planner.date(c.optDouble("updatedAt"))+" "+Planner.clock(c.optDouble("updatedAt")),()->{if(multiHistory){if(!historySelection.add(id))historySelection.remove(id);renderHistory();}else{session.select(id);closeHistory();}});open.setTextSize(14);open.setGravity(Gravity.START|Gravity.CENTER_VERTICAL);open.setMaxLines(3);open.setEllipsize(TextUtils.TruncateAt.END);open.setSelected(id.equals(selected));PlannerUi.buttonBackground(open,id.equals(selected)?AssistantUi.PALE:AssistantUi.WHITE,AssistantUi.SURFACE,AssistantUi.BUTTON_OUTLINE,14,0x224d6bfe);line.addView(open,new LinearLayout.LayoutParams(0,-2,1));historyList.addView(line);
        }
        if(visibleHistory.isEmpty())historyList.addView(text("没有匹配的对话",14));
    }
    void confirmDelete(Set<String> ids,Runnable close){StringBuilder titles=new StringBuilder();for(JSONObject c:Planner.list(state.workspace.optJSONArray("conversations")))if(ids.contains(c.optString("id")))titles.append("• ").append(AssistantHistory.title(c)).append('\n');new AlertDialog.Builder(this).setTitle("删除 "+ids.size()+" 段对话？").setMessage(titles+"\n仅删除此手机的聊天；日程与独立记忆保留，已发送内容无法撤回。").setNegativeButton("取消",null).setPositiveButton("删除",(d,w)->{session.delete(ids);close.run();}).show();}
    void memories(){
        LinearLayout body=column();body.setPadding(dp(14),0,dp(14),0);body.addView(text("记忆默认关闭；主动启用后随问题发送。记忆不代表当前课表事实，也不能授权修改或跳过确认。请勿保存密钥。",14));AlertDialog dialog=new AlertDialog.Builder(this).setTitle("本机记忆").setView(scrolling(body)).setNegativeButton("关闭",null).create();body.addView(button("添加记忆",()->{dialog.dismiss();editMemory(null);}));
        for(JSONObject memory:Planner.list(state.workspace.optJSONArray("memories"))){CheckBox enabled=new CheckBox(this);enabled.setText(memory.optString("text"));enabled.setChecked(memory.optBoolean("enabled"));enabled.setOnCheckedChangeListener((v,on)->session.memory(memory.optString("id"),memory.optString("text"),on,false));body.addView(enabled);PlannerUi.Flow actions=new PlannerUi.Flow(this);actions.addView(button("编辑",()->{dialog.dismiss();editMemory(memory);}));actions.addView(button("删除",()->new AlertDialog.Builder(this).setTitle("删除这条本机记忆？").setNegativeButton("取消",null).setPositiveButton("删除",(d,w)->{session.memory(memory.optString("id"),"",false,true);dialog.dismiss();}).show()));body.addView(actions);}dialog.show();dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
    void editMemory(JSONObject memory){LinearLayout body=column();body.setPadding(dp(16),0,dp(16),0);EditText edit=field(body,"回答偏好或背景（最多2000字节）",memory==null?"":memory.optString("text"));edit.setSingleLine(false);edit.setMinLines(4);new AlertDialog.Builder(this).setTitle(memory==null?"添加记忆":"编辑记忆").setView(body).setNegativeButton("取消",null).setPositiveButton("保存",(d,w)->session.memory(memory==null?"":memory.optString("id"),edit.getText().toString(),memory!=null&&memory.optBoolean("enabled"),false)).show();}
}
