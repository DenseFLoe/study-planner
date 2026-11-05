package local.studyplanner;

import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.Color;
import android.net.Uri;
import android.view.*;
import android.webkit.*;
import android.widget.*;
import android.text.*;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;

/** Isolated, temporary login session. Native code receives metadata by polling, without a JS bridge. */
public class CourseImportActivity extends Activity {
    private static boolean webKitInitialized;
    boolean previewing,delivering;
    WebView browser, replay;
    Dialog popup;
    LinearLayout root, results;
    EditText address, passcode, folderLimit, fileLimit, query, deadline, mergedName;
    CheckBox autoRefresh, mergeSelected;
    TextView status, selectionSummary, resultPosition;
    ScrollView resultsScroll;
    Button previousResultPage, nextResultPage;
    int resultPage, groupPage;
    boolean groupChoicesExpanded;
    List<JSONObject> filteredCaptures=Collections.emptyList();
    CourseImportCatalog.SearchResult searchResult;
    LatestWork<CourseImportCatalog.SearchResult> searchWork;
    LatestWork<CourseImportPreview> previewWork;
    ProgressDialog previewProgress;
    Runnable pendingSearch;
    List<JSONObject> requestedSource;
    String requestedQuery;
    boolean filtering;
    PlannerUi.Flow selectionActions;
    Button importButton, refreshButton, previewButton;
    Button clearFilterButton;
    final Handler handler = new Handler();
    final ExecutorService worker = Executors.newSingleThreadExecutor();
    final Map<String,String> scripts = new HashMap<>();
    final Set<String> selected = new HashSet<>();
    List<JSONObject> captures = new ArrayList<>(), xuechengBase = new ArrayList<>();
    boolean netdisk, capturing, documentStart;
    volatile int generation;
    long lastRefresh;
    String pageTitle = "", failure = "";
    JSONObject directory;
    int observedRevision=-1;
    final Runnable passive = new Runnable(){public void run(){if(!isDestroyed()&&!netdisk&&!capturing&&!previewing&&!delivering&&browser!=null){final int current=generation;String host=Uri.parse(browser.getUrl()==null?"":browser.getUrl()).getHost();if(host!=null&&!WebsiteCapture.isYantuHost(host))browser.evaluateJavascript("JSON.stringify(window.studyGenericCrawler?{revision:studyGenericCrawler.revision(),count:studyGenericCrawler.count(),activity:studyGenericCrawler.activity()}:null)",encoded->{if(current!=generation||capturing||previewing||delivering||isDestroyed())return;try{Object raw=new JSONTokener(encoded).nextValue();if(!(raw instanceof String))return;JSONObject value=new JSONObject((String)raw);int revision=value.getInt("revision");if(revision!=observedRevision&&value.optInt("count")>0&&value.getJSONObject("activity").optInt("pending")==0){observedRevision=revision;capture();}}catch(Exception ignored){}});}handler.postDelayed(this,3000);}};
    final Runnable refreshTimer = new Runnable() { public void run() {
        if (!isDestroyed() && autoRefresh.isChecked() && !capturing && !previewing && !delivering && !netdisk && System.currentTimeMillis()-lastRefresh >= 300000) capture();
        handler.postDelayed(this, 30000);
    }};

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        // The manifest places this activity in its own process; do this before any WebKit API.
        if (!webKitInitialized) { if (Build.VERSION.SDK_INT >= 28) WebView.setDataDirectorySuffix("course-import"); webKitInitialized=true; }
        netdisk = "netdisk".equals(getIntent().getStringExtra("mode"));
        previewWork=new LatestWork<>(worker,this::runOnUiThread,value->{
            endPreview();if(isDestroyed())return;renderResults();showPreview(value.schedule,value.warnings);
        },error->{endPreview();if(isDestroyed())return;renderResults();message(error.getMessage());});
        searchWork=new LatestWork<>(worker,this::runOnUiThread,value->{
            if(isDestroyed()||!value.isCurrent(captures,query.getText().toString()))return;
            searchResult=value;filtering=false;renderResults();
        },error->{
            if(isDestroyed())return;
            filtering=false;selectionSummary.setText("筛选暂未完成，原选择已保留；请修改搜索词或重新读取后重试。");
        });
        try { for (String name : new String[]{"CourseCrawler", "GenericCrawler", "XuechengCrawler", "XuechengReplay", "QuarkCrawler", "QuarkScan"}) scripts.put(name, MainActivity.read(getAssets().open("crawlers/"+name+".js"))); }
        catch (Exception error) { finish(); return; }
        root = column(); root.setPadding(dp(12),dp(8),dp(12),dp(8)); root.setFitsSystemWindows(true); root.setBackgroundColor(0xffededed);ScrollView content=new ScrollView(this);content.setFillViewport(true);content.addView(root);setContentView(content);
        root.addView(label(netdisk ? "夸克分享课程导入" : "网站课程导入",20));
        address = field(root,"HTTPS 网址",netdisk ? "https://pan.quark.cn/" : "https://www.kaoyanvip.cn/appmanage/my/mycourse",false);
        PlannerUi.Flow controls = new PlannerUi.Flow(this);
        controls.addView(button("打开",()->open(address.getText().toString())));
        controls.addView(button("默认地址",()->open(netdisk?"https://pan.quark.cn/":"https://www.kaoyanvip.cn/appmanage/my/mycourse")));
        controls.addView(button("后退",()->{if(browser.canGoBack())browser.goBack();}));
        controls.addView(button("重新登录",this::resetSession));
        controls.addView(button("关闭",this::finish));
        root.addView(controls);
        if (netdisk) { LinearLayout share = row(); passcode = field(share,"提取码（可留空）","",false); passcode.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD); folderLimit=field(share,"目录上限","60",true); fileLimit=field(share,"条目上限","2000",true); root.addView(share); }
        status=label("请在网页中登录并打开课程页面。关闭导入窗口后会清除本次登录会话。",12);root.addView(status);
        browser = webView(false); root.addView(browser,new LinearLayout.LayoutParams(-1,dp(320)));root.addView(button("展开 / 收起网页",()->browser.setVisibility(browser.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE)));
        PlannerUi.Flow actions=new PlannerUi.Flow(this);
        refreshButton=button(netdisk?"读取分享目录":"抓取 / 刷新课程",this::capture);
        actions.addView(refreshButton);
        autoRefresh=new CheckBox(this);
        autoRefresh.setText("每5分钟刷新");
        autoRefresh.setVisibility(netdisk?View.GONE:View.VISIBLE);
        actions.addView(autoRefresh);
        if(netdisk)actions.addView(button("分享目录",this::directory));
        root.addView(actions);
        query=field(root,"搜索课程、课节、路径或网站","",false);query.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){resultPage=0;groupPage=0;renderResults();if(resultsScroll!=null)resultsScroll.scrollTo(0,0);}public void afterTextChanged(Editable s){}});
        selectionActions=new PlannerUi.Flow(this);
        selectionActions.addView(button("勾选搜索结果",()->selectMatches(true)));
        selectionActions.addView(button("取消搜索结果",()->selectMatches(false)));
        selectionActions.addView(button("只选搜索结果",()->{if(capturing||previewing||delivering||!filterReady())return;Set<String> ids=searchResult.selectableIDs;if(ids.isEmpty()){message("当前搜索结果中没有可导入课程，原选择已保留。");return;}selected.clear();selected.addAll(ids);renderResults();}));
        clearFilterButton=button("清除筛选",()->query.setText(""));selectionActions.addView(clearFilterButton);
        root.addView(selectionActions);selectionSummary=label("尚未识别课程。",12);root.addView(selectionSummary);resultsScroll=new ScrollView(this);results=column();resultsScroll.addView(results);root.addView(resultsScroll,new LinearLayout.LayoutParams(-1,dp(240)));
        resultPosition=label("",12);root.addView(resultPosition);PlannerUi.Flow resultNavigation=new PlannerUi.Flow(this);
        previousResultPage=button("上一页课程",()->{resultPage--;renderResults();resultsScroll.scrollTo(0,0);});
        nextResultPage=button("下一页课程",()->{resultPage++;renderResults();resultsScroll.scrollTo(0,0);});
        previousResultPage.setEnabled(false);nextResultPage.setEnabled(false);
        resultNavigation.addView(previousResultPage);resultNavigation.addView(nextResultPage);root.addView(resultNavigation);
        LinearLayout options=row();deadline=field(options,"新课程截止日期",LocalDate.now(Planner.ZONE).plusMonths(3).toString(),false);deadline.setFocusable(false);deadline.setOnClickListener(v->{LocalDate date;try{date=LocalDate.parse(deadline.getText().toString());}catch(Exception e){date=LocalDate.now(Planner.ZONE);}new DatePickerDialog(this,(picker,y,m,d)->deadline.setText(LocalDate.of(y,m+1,d).toString()),date.getYear(),date.getMonthValue()-1,date.getDayOfMonth()).show();});root.addView(options);
        if(netdisk){mergeSelected=new CheckBox(this);mergeSelected.setText("将所选目录合为一门课程");root.addView(mergeSelected);mergedName=field(root,"合并名称","合并课程",false);}
        PlannerUi.Flow bottom=new PlannerUi.Flow(this);
        previewButton=button("编排预览",this::preview);previewButton.setEnabled(false);bottom.addView(previewButton);
        importButton=button("导入所选课程",this::deliver);
        importButton.setEnabled(false);
        bottom.addView(importButton);
        root.addView(bottom);
        handler.postDelayed(refreshTimer,30000);
        handler.postDelayed(passive,3000);
        CookieManager.getInstance().removeAllCookies(removed->{WebStorage.getInstance().deleteAllData();browser.clearCache(true);open(address.getText().toString());});
    }

    WebView webView(boolean child) {
        WebView view=new WebView(this);WebSettings settings=view.getSettings();settings.setJavaScriptEnabled(true);settings.setDomStorageEnabled(true);settings.setAllowFileAccess(false);settings.setAllowContentAccess(false);settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);settings.setSupportMultipleWindows(true);settings.setJavaScriptCanOpenWindowsAutomatically(true);settings.setMediaPlaybackRequiresUserGesture(true);
        // Use desktop catalogs, which contain the complete metadata consumed by the shared crawlers.
        settings.setUserAgentString(settings.getUserAgentString().replace("; wv","").replace("Mobile ",""));
        CookieManager.getInstance().setAcceptCookie(true);CookieManager.getInstance().setAcceptThirdPartyCookies(view,true);
        if(!child){try{documentStart=WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT);if(documentStart)WebViewCompat.addDocumentStartJavaScript(view,scripts.get("GenericCrawler"),Collections.singleton("*"));}catch(RuntimeException error){documentStart=false;}}
        view.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView web,WebResourceRequest request){return !https(request.getUrl().toString());}
            @Override public void onPageStarted(WebView web,String url,android.graphics.Bitmap icon){if(!child){generation++;cancelPreview();observedRevision=-1;capturing=false;refreshButton.setEnabled(true);if(netdisk){directory=null;captures=Collections.emptyList();selected.clear();}renderResults();if(!documentStart)web.evaluateJavascript(scripts.get("GenericCrawler"),null);}else replayURL(web,url);}
            @Override public void onPageFinished(WebView web,String url){if(child){replayURL(web,url);return;}address.setText(url);pageTitle=web.getTitle()==null?"":web.getTitle();inject(web);status.setText(documentStart?"页面已打开，可以抓取课程。":"当前系统 WebView 不支持加载前捕获：请升级 WebView，或在页面内切换课程后再抓取。研途专用抓取仍可使用。");String host=Uri.parse(url).getHost();if(!netdisk&&WebsiteCapture.isYantuHost(host)&&url.contains("/mycourse"))handler.postDelayed(()->{if(!capturing&&!isDestroyed())capture();},1800);}
            @Override public void onReceivedError(WebView web,WebResourceRequest request,WebResourceError error){if(request.isForMainFrame())status.setText("网页加载失败，请检查网址和网络。");}
        });
        view.setWebChromeClient(new WebChromeClient(){
            @Override public boolean onCreateWindow(WebView web,boolean dialog,boolean user,Message message){if(popup!=null){popup.dismiss();popup=null;}if(replay!=null){replay.stopLoading();replay.destroy();}replay=webView(true);if(!capturing){popup=new Dialog(CourseImportActivity.this);LinearLayout content=column();content.addView(button("关闭网页窗口",()->{if(popup!=null)popup.dismiss();}));content.addView(replay,new LinearLayout.LayoutParams(-1,0,1));popup.setContentView(content);popup.show();popup.getWindow().setLayout(-1,-1);}WebView.WebViewTransport transport=(WebView.WebViewTransport)message.obj;transport.setWebView(replay);message.sendToTarget();return true;}
            @Override public void onCloseWindow(WebView window){if(popup!=null){popup.dismiss();popup=null;}}
        });return view;
    }
    static boolean https(String url){try{Uri value=Uri.parse(url);return "https".equalsIgnoreCase(value.getScheme())&&value.getHost()!=null&&value.getUserInfo()==null;}catch(Exception error){return false;}}
    void inject(WebView web){web.evaluateJavascript("window.webkit={messageHandlers:{courseStatus:{postMessage:v=>{window.__studyStatus=String(v)}},replayMetadata:{postMessage:v=>{window.__studyReplay=v}}}};",null);for(String name:new String[]{"GenericCrawler","CourseCrawler","XuechengCrawler","QuarkCrawler","QuarkScan"})web.evaluateJavascript(scripts.get(name),null);}
    void open(String input){String url=input.trim();if(!url.contains("://"))url="https://"+url; if(!https(url)){message("请填写不含账号信息的 HTTPS 网址。");return;}browser.loadUrl(url);}
    void resetSession(){generation++;cancelPreview();capturing=false;captures=Collections.emptyList();selected.clear();browser.stopLoading();CookieManager.getInstance().removeAllCookies(done->{WebStorage.getInstance().deleteAllData();browser.clearCache(true);browser.clearHistory();open(address.getText().toString());});renderResults();}
    void directory(){
        if(directory==null){message("请先读取分享目录。");return;}
        final JSONObject scan=directory;
        showImportDetails(scan.optString("shareTitle","分享目录"),"搜索文件名、目录路径、视频或不可用条目",false,()->CourseImportDetails.directory(scan));
    }
    boolean matches(JSONObject snapshot,String term){return CourseImportCatalog.matches(snapshot,term);}
    void selectMatches(boolean select){if(capturing||previewing||delivering||!filterReady())return;Set<String> ids=searchResult.selectableIDs;if(select)selected.addAll(ids);else selected.removeAll(ids);renderResults();}
    boolean importable(JSONObject snapshot){return CourseImportCatalog.importable(snapshot);}
    void updateSelectionSummary(){if(selectionSummary!=null)selectionSummary.setText(CourseImportCatalog.summary(captures,selected,filteredCaptures));}
    void groupChoices(){
        if(!netdisk)return;
        List<CourseImportCatalog.Group> groups=searchResult.groups;if(groups.isEmpty())return;
        results.addView(button(groupChoicesExpanded?"收起目录批选":"按目录批选（"+groups.size()+" 类）",()->{groupChoicesExpanded=!groupChoicesExpanded;renderResults();}));
        if(!groupChoicesExpanded)return;
        int pages=CourseImportCatalog.groupPageCount(groups);groupPage=Math.max(0,Math.min(groupPage,pages-1));
        results.addView(label("目录批选 · 仅当前搜索结果 · 第 "+(groupPage+1)+" / "+pages+" 页",12));
        for(CourseImportCatalog.Group group:CourseImportCatalog.groupPage(groups,groupPage)){
            CheckBox check=new CheckBox(this);int count=0;for(String id:group.ids)if(selected.contains(id))count++;
            check.setText(group.title()+" · 已选 "+count+" / "+group.ids.size()+" 门");check.setChecked(count==group.ids.size());
            check.setEnabled(!capturing&&!previewing&&!delivering);
            check.setOnCheckedChangeListener((button,value)->{
                if(capturing||previewing||delivering||!filterReady())return;
                if(value)selected.addAll(group.ids);else selected.removeAll(group.ids);handler.post(this::renderResults);
            });results.addView(check);
        }
        if(pages>1){
            PlannerUi.Flow navigation=new PlannerUi.Flow(this);
            Button previous=button("上一页目录",()->{groupPage--;renderResults();resultsScroll.scrollTo(0,0);});
            Button next=button("下一页目录",()->{groupPage++;renderResults();resultsScroll.scrollTo(0,0);});
            previous.setEnabled(groupPage>0);next.setEnabled(groupPage+1<pages);navigation.addView(previous);navigation.addView(next);results.addView(navigation);
        }
        results.addView(label("课程列表",13));
    }

    /** Evaluate a Promise in page memory and poll only its completed metadata envelope. */
    void promise(WebView web,String expression,long timeout,Consumer<Object> done) {
        final int current=generation;final String key="__studyCapture_"+UUID.randomUUID().toString().replace("-","");final long until=System.currentTimeMillis()+timeout;
        web.evaluateJavascript("window["+JSONObject.quote(key)+"]={pending:true};Promise.resolve().then(()=> ("+expression+")).then(value=>window["+JSONObject.quote(key)+"]={value:value}).catch(()=>window["+JSONObject.quote(key)+"]={error:true});",null);
        Runnable poll=new Runnable(){public void run(){
            if(isDestroyed()||current!=generation)return;
            if(System.currentTimeMillis()>until){failed("读取超时，请检查网络并重试。");return;}
            web.evaluateJavascript("JSON.stringify(Object.assign({},window["+JSONObject.quote(key)+"]||{pending:true},{status:window.__studyStatus}))",encoded->{
                if(isDestroyed()||current!=generation)return;
                intake(()->CourseCaptureIntake.envelope(encoded),value->{
                    if(value.optBoolean("pending")){
                        if(!value.optString("status").isEmpty())status.setText(value.optString("status"));
                        handler.postDelayed(this,350);return;
                    }
                    web.evaluateJavascript("delete window["+JSONObject.quote(key)+"]",null);
                    if(value.optBoolean("error")){failed("页面读取失败。请确认已经登录、课程可见、分享提取码正确，刷新后重试。");return;}
                    done.accept(value.opt("value"));
                },"页面返回的数据无法读取，请重试。");
            });
        }};handler.postDelayed(poll,200);
    }

    void capture(){if(capturing||previewing||delivering)return;generation++;capturing=true;lastRefresh=System.currentTimeMillis();refreshButton.setEnabled(false);importButton.setEnabled(false);status.setText("正在读取全部课程，请保留此窗口…");failure="";renderResults();inject(browser);
        if(netdisk){try{int folders=Integer.parseInt(folderLimit.getText().toString()),files=Integer.parseInt(fileLimit.getText().toString());if(folders<1||folders>500||files<1||files>20000)throw new Exception();String expression="studyQuarkScan("+JSONObject.quote(passcode.getText().toString())+","+folders+","+files+")";promise(browser,expression,600000,value->{if(!(value instanceof JSONObject)){failed("目录数据不完整。");return;}directory=(JSONObject)value;background(()->{List<JSONObject> values=NetdiskImport.build((JSONObject)value);NetdiskImport.compareExisting(values,PlannerRuntime.get(this).database.load());return values;});});}catch(Exception error){failed("目录上限须为1–500，条目上限须为1–20000。");}return;}
        String host=Uri.parse(browser.getUrl()==null?"":browser.getUrl()).getHost();
        if(WebsiteCapture.isYantuHost(host)){
            promise(browser,"studyCourseCrawler.run()",600000,value->intake(
                ()->CourseCaptureIntake.yantu((JSONObject)value),
                prepared->accept(prepared.values,prepared.notice),"课程列表不完整。"));
        }else{
            promise(browser,"(async()=>{const catalog=await studyXuechengCrawler.catalog(true);const activity=studyGenericCrawler.activity();return {catalog,responses:studyGenericCrawler.snapshot(),activity,url:location.href,title:document.title};})()",180000,value->intake(
                ()->CourseCaptureIntake.generic((JSONObject)value,Planner.now()),prepared->{
                    if(prepared.replay==null)accept(prepared.values);
                    else{xuechengBase=prepared.values;readReplay(prepared.replay,prepared.replayRows,0);}
                },"无法读取课程目录，请进入课程详情页后重试。"));
        }
    }
    void replayURL(WebView view,String url){try{if("view.csslcloud.net".equals(Uri.parse(url).getHost())){view.evaluateJavascript("window.webkit={messageHandlers:{replayMetadata:{postMessage:v=>window.__studyReplay=v}}};"+scripts.get("XuechengReplay"),null);}else view.evaluateJavascript("(()=>{const frame=[...document.querySelectorAll('iframe')].find(f=>{try{return new URL(f.src).hostname==='view.csslcloud.net'}catch{return false}});return frame?frame.src:null})()",encoded->{try{Object raw=new JSONTokener(encoded).nextValue();if(raw instanceof String&&https((String)raw))view.loadUrl((String)raw);}catch(Exception ignored){}});}catch(Exception ignored){}}
    void readReplay(JSONObject snapshot,JSONArray rows,int index){try{while(index<rows.length()&&(!rows.getJSONObject(index).optBoolean("replay")||snapshot.getJSONArray("lessons").getJSONObject(index).has("durationSeconds")))index++;if(index==rows.length()){final List<JSONObject> base=xuechengBase;background(()->WebsiteCapture.merge(base,Collections.singletonList(snapshot)));return;}final int rowIndex=index;status.setText("正在读取直播回放 "+(index+1)+" / "+rows.length()+"…");if(replay!=null){replay.destroy();replay=null;}promise(browser,"studyXuechengCrawler.open("+index+")",30000,value->{if(!Boolean.TRUE.equals(value)){failed("回放入口无法打开，请重新进入课程详情页。");return;}pollReplay(snapshot,rows,rowIndex,System.currentTimeMillis()+45000,generation);});}catch(Exception error){failed("回放信息不完整。");}}
    void pollReplay(JSONObject snapshot,JSONArray rows,int index,long until,int current){if(current!=generation||isDestroyed())return;if(System.currentTimeMillis()>until){try{snapshot.getJSONArray("issues").put("回放时长未能读取："+rows.getJSONObject(index).getString("name"));readReplay(snapshot,rows,index+1);}catch(Exception error){failed("回放时长读取失败。");}return;}if(replay==null){handler.postDelayed(()->pollReplay(snapshot,rows,index,until,current),400);return;}replay.evaluateJavascript("JSON.stringify(window.__studyReplay||null)",encoded->{if(current!=generation)return;try{Object raw=new JSONTokener(encoded).nextValue();JSONObject metadata=raw instanceof String?new JSONObject((String)raw):null;if(metadata!=null&&metadata.optDouble("durationSeconds")>0&&metadata.optString("title").replaceAll("\\s+","").equals(rows.getJSONObject(index).optString("name").replaceAll("\\s+",""))){JSONObject lesson=snapshot.getJSONArray("lessons").getJSONObject(index);lesson.put("durationSeconds",metadata.getDouble("durationSeconds"));if(!lesson.has("watchedPercent")){lesson.put("watchedPercent",0);}readReplay(snapshot,rows,index+1);return;}}catch(Exception ignored){}handler.postDelayed(()->pollReplay(snapshot,rows,index,until,current),400);});}

    interface CaptureWork {List<JSONObject> run()throws Exception;}
    /** Only decoded, current results reach the UI; callbacks never share a changing page context. */
    <T> void intake(LatestWork.Work<T> work,Consumer<T> done,String failureMessage){
        final int current=generation;
        worker.execute(()->{try{
            T value=BackgroundCancellation.call(()->current!=generation||Thread.currentThread().isInterrupted(),work::run);
            runOnUiThread(()->{if(current!=generation||isDestroyed())return;try{done.accept(value);}catch(Exception error){failed(failureMessage);}});
        }catch(CancellationException cancelled){
            // Navigation or activity destruction invalidated this read-only capture.
        }catch(Exception error){runOnUiThread(()->{if(current==generation&&!isDestroyed())
            failed(error instanceof IllegalArgumentException?error.getMessage():failureMessage);});}});
    }
    void background(CaptureWork work){intake(work::run,this::accept,"目录识别失败，请重试。");}
    void accept(List<JSONObject> values){accept(values,"");}
    void accept(List<JSONObject> values,String notice){
        String host=Uri.parse(browser.getUrl()==null?"":browser.getUrl()).getHost();
        final boolean append=!netdisk&&host!=null&&!WebsiteCapture.isYantuHost(host);
        final List<JSONObject> previous=captures;
        final Set<String> choices=new HashSet<>(selected);
        intake(()->CourseCaptureIntake.accept(previous,values,append,choices),prepared->{
            captures=prepared.captures;selected.clear();selected.addAll(prepared.selected);
            capturing=false;refreshButton.setEnabled(true);
            String summary="识别到 "+captures.size()+" 门课程。请选择、核对课节与进度后导入；已有课程将保留完成流水。";
            if(values.isEmpty())summary=captures.isEmpty()?"尚未捕获可排程课节，请进入课程详情并展开章节，再重新抓取。":"本轮没有新的课程，已保留此前识别的课程。";
            status.setText(summary+notice);renderResults();
        },"课程合并识别失败，请重试。");
    }
    void failed(String message){capturing=false;failure=message;refreshButton.setEnabled(true);captures=Collections.emptyList();selected.clear();status.setText(message);renderResults();}
    boolean filterReady(){return !filtering&&searchResult!=null&&searchResult.isCurrent(captures,query.getText().toString());}
    void renderResults(){
        if(results==null)return;
        String term=query.getText().toString();
        if(searchResult==null||!searchResult.isCurrent(captures,term)){
            if(!filtering||requestedSource!=captures||!term.equals(requestedQuery)){
                searchWork.clear();if(pendingSearch!=null)handler.removeCallbacks(pendingSearch);
                filtering=true;requestedSource=captures;requestedQuery=term;
                final List<JSONObject> source=captures;
                pendingSearch=()->searchWork.submit(()->new CourseImportCatalog.SearchResult(source,term));
                handler.postDelayed(pendingSearch,150);
            }
            results.removeAllViews();filteredCaptures=Collections.emptyList();
            selectionSummary.setText("正在筛选课程…已选 "+selected.size()+" 门，选择仍保留。");
            resultPosition.setText("");previousResultPage.setEnabled(false);nextResultPage.setEnabled(false);
            for(int i=0;i<selectionActions.getChildCount();i++)selectionActions.getChildAt(i).setEnabled(false);
            clearFilterButton.setEnabled(!capturing&&!previewing&&!delivering);importButton.setEnabled(false);previewButton.setEnabled(false);
            return;
        }
        searchWork.clear();if(pendingSearch!=null)handler.removeCallbacks(pendingSearch);pendingSearch=null;
        filtering=false;filteredCaptures=searchResult.matches;
        int pages=CourseImportCatalog.pageCount(filteredCaptures);
        resultPage=Math.max(0,Math.min(resultPage,pages-1));
        results.removeAllViews();
        if(selectionActions!=null)for(int i=0;i<selectionActions.getChildCount();i++)selectionActions.getChildAt(i).setEnabled(!capturing&&!previewing&&!delivering);
        updateSelectionSummary();groupChoices();
        for(JSONObject snapshot:CourseImportCatalog.page(filteredCaptures,resultPage)){
            String problem=snapshot.optString("refusal",WebCourseImport.problem(snapshot));
            CheckBox choice=new CheckBox(this);String id=WebCourseImport.identity(snapshot),website=CourseImportCatalog.website(snapshot);
            choice.setText(snapshot.optString("name")+" · "+snapshot.optJSONArray("lessons").length()+" 课节"+(website.isEmpty()?"":"\n"+website)+(problem==null?"":"\n"+problem));
            choice.setEnabled(problem==null&&!capturing&&!previewing&&!delivering);choice.setChecked(selected.contains(id));
            choice.setOnCheckedChangeListener((button,checked)->{if(checked)selected.add(id);else selected.remove(id);handler.post(this::renderResults);});
            results.addView(choice);results.addView(button("查看课节与来源",()->details(snapshot)));
            JSONArray existing=snapshot.optJSONArray("existingCourses");
            if(existing!=null)for(JSONObject course:Planner.list(existing))results.addView(button("查看已有计划 · "+course.optString("name"),()->{setResult(RESULT_OK,new Intent().putExtra("courseID",course.optString("id")));finish();}));
        }
        if(resultPosition!=null)resultPosition.setText((filteredCaptures.isEmpty()?"没有匹配的课程。":"第 "+(resultPage+1)+" / "+pages+" 页 · 每页最多 "+CourseImportCatalog.PAGE_SIZE+" 门。")+" 批选作用于全部搜索结果，选择跨页保留。");
        if(previousResultPage!=null)previousResultPage.setEnabled(resultPage>0);
        if(nextResultPage!=null)nextResultPage.setEnabled(resultPage+1<pages);
        importButton.setEnabled(!capturing&&!previewing&&!delivering&&filterReady()&&!selected.isEmpty());
        previewButton.setEnabled(!capturing&&!previewing&&!delivering&&filterReady()&&!selected.isEmpty());
    }
    void details(JSONObject snapshot){
        showImportDetails(snapshot.optString("name","课程详情"),"搜索课节、章节、文件路径或识别提示",true,()->new CourseImportDetails(snapshot));
    }
    void showImportDetails(String title,String searchHint,boolean allowReview,LatestWork.Work<CourseImportDetails> prepare){
        LinearLayout form=column(),rows=column();form.setPadding(dp(16),dp(8),dp(16),dp(8));
        EditText search=field(form,searchHint,"",false);
        CheckBox reviewOnly=new CheckBox(this);reviewOnly.setText("只看需核对课节");reviewOnly.setEnabled(false);if(allowReview)form.addView(reviewOnly);
        TextView summary=label("正在整理详情…",13),position=label("",12);form.addView(summary);form.addView(position);
        ScrollView scroll=new ScrollView(this);scroll.addView(rows);form.addView(scroll,new LinearLayout.LayoutParams(-1,dp(360)));
        PlannerUi.Flow navigation=new PlannerUi.Flow(this);form.addView(navigation);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle(title).setView(form).setPositiveButton("关闭",null).create();
        CourseImportDetails[] catalog={null},details={null};int[] page={0};Button[] buttons=new Button[2];
        Runnable render=()->{
            rows.removeAllViews();CourseImportDetails current=details[0];if(current==null)return;
            summary.setText(current.summary);page[0]=current.pageIndex(page[0]);
            position.setText(current.count()==0?(current.totalCount==0?"尚无条目信息，请返回后重新读取目录。":"没有匹配内容，可缩短搜索词或清除筛选。")
                :"匹配 "+current.count()+" / "+current.totalCount+" 条 · 第 "+(page[0]+1)+" / "+current.pageCount()+" 页");
            for(String line:current.page(page[0])){TextView row=label(line,14);row.setPadding(0,dp(8),0,dp(8));row.setTextIsSelectable(true);rows.addView(row);}
            buttons[0].setEnabled(page[0]>0);buttons[1].setEnabled(page[0]+1<current.pageCount());scroll.scrollTo(0,0);
        };
        buttons[0]=button("上一页",()->{page[0]--;render.run();});buttons[1]=button("下一页",()->{page[0]++;render.run();});
        for(Button button:buttons){button.setEnabled(false);navigation.addView(button);}
        LatestWork<CourseImportDetails> work=new LatestWork<>(worker,this::runOnUiThread,value->{
            if(isDestroyed()||!dialog.isShowing())return;details[0]=value;reviewOnly.setEnabled(allowReview&&value.reviewCount>0);render.run();
        },error->{if(!isDestroyed()&&dialog.isShowing())summary.setText("详情暂未读取成功，可关闭后重试；原选择仍保留。");});
        Runnable[] pending={null};
        Runnable load=()->{
            work.clear();if(pending[0]!=null)handler.removeCallbacks(pending[0]);
            details[0]=null;page[0]=0;rows.removeAllViews();position.setText("正在筛选详情…");
            for(Button button:buttons)button.setEnabled(false);
            final String term=search.getText().toString();final boolean only=allowReview&&reviewOnly.isChecked();
            pending[0]=()->work.submit(()->{if(catalog[0]==null)catalog[0]=prepare.run();return catalog[0].find(term,only);});
            handler.postDelayed(pending[0],150);
        };
        search.addTextChangedListener(new TextWatcher(){
            public void beforeTextChanged(CharSequence value,int start,int count,int after){}
            public void onTextChanged(CharSequence value,int start,int before,int count){load.run();}
            public void afterTextChanged(Editable value){}
        });
        reviewOnly.setOnCheckedChangeListener((button,checked)->load.run());
        navigation.addView(button("清除筛选",()->{reviewOnly.setChecked(false);search.setText("");}));
        dialog.setOnDismissListener(value->{work.close();if(pending[0]!=null)handler.removeCallbacks(pending[0]);});dialog.show();load.run();
    }
    CourseImportRequest importRequest(){return new CourseImportRequest(captures,selected,
        netdisk&&mergeSelected.isChecked()?mergedName.getText().toString():null,importDeadline());}
    double importDeadline(){return Planner.at(LocalDate.parse(deadline.getText().toString()),0);}
    void endPreview(){previewing=false;if(previewProgress!=null){previewProgress.dismiss();previewProgress=null;}}
    void cancelPreview(){if(previewWork!=null)previewWork.clear();endPreview();}
    void preview(){
        if(previewing||capturing||delivering||!filterReady())return;
        try{
            CourseImportRequest request=importRequest();previewing=true;
            previewProgress=new ProgressDialog(this);previewProgress.setMessage("正在预览…");previewProgress.setIndeterminate(true);
            previewProgress.setCancelable(true);previewProgress.setCanceledOnTouchOutside(false);
            previewProgress.setButton(DialogInterface.BUTTON_NEGATIVE,"取消预览",(dialog,which)->{cancelPreview();renderResults();});
            previewProgress.setOnCancelListener(dialog->{cancelPreview();renderResults();});previewProgress.show();
            previewWork.submit(()->CourseImportPreview.calculate(PlannerRuntime.get(this).database.load(),request,Planner.now()));
        }catch(Exception error){cancelPreview();renderResults();message(error.getMessage());}
    }
    void showPreview(SchedulePreview result,String warnings){
        LinearLayout form=column(),rows=column();form.setPadding(dp(16),dp(8),dp(16),dp(8));
        form.addView(label("已排 "+result.plannedMinutes+" 分钟 · 剩余 "+result.remainingMinutes+" 分钟 · 未排入 "+Math.max(0,result.remainingMinutes-result.plannedMinutes)+" 分钟\n预览不保存日程。",13));
        TextView position=label("",12);form.addView(position);ScrollView scroll=new ScrollView(this);scroll.addView(rows);form.addView(scroll,new LinearLayout.LayoutParams(-1,dp(360)));
        PlannerUi.Flow navigation=new PlannerUi.Flow(this);form.addView(navigation);int[] page={0};Button[] buttons=new Button[2];
        Runnable render=()->{rows.removeAllViews();position.setText(result.count()==0?"没有可排入的未完成课节。":result.count()+" 项安排 · 第 "+(page[0]+1)+" / "+result.pageCount()+" 页");for(String line:result.page(page[0]))rows.addView(label(line,14));buttons[0].setEnabled(page[0]>0);buttons[1].setEnabled(page[0]+1<result.pageCount());scroll.scrollTo(0,0);};
        buttons[0]=button("上一页",()->{page[0]--;render.run();});buttons[1]=button("下一页",()->{page[0]++;render.run();});navigation.addView(buttons[0]);navigation.addView(buttons[1]);
        if(!warnings.isEmpty())form.addView(button("查看排程提示",()->message(warnings)));render.run();
        new AlertDialog.Builder(this).setTitle(result.courseName).setView(form).setPositiveButton("关闭",null).show();
    }
    void deliver(){
        if(capturing||previewing||delivering||!filterReady())return;
        try{
            CourseImportRequest request=importRequest();int current=generation;delivering=true;importButton.setEnabled(false);
            ProgressDialog progress=ProgressDialog.show(this,"","正在准备导入文件…",true,false);
            worker.execute(()->{try{
                File file=CourseImportReceipt.stage(getCacheDir(),request.prepare(),request.deadline);
                runOnUiThread(()->{delivering=false;progress.dismiss();if(isDestroyed())return;renderResults();if(current!=generation)return;setResult(RESULT_OK,new Intent().putExtra("captureFile",file.getAbsolutePath()));finish();});
            }catch(Exception error){runOnUiThread(()->{delivering=false;progress.dismiss();if(isDestroyed())return;renderResults();if(current!=generation)return;message("导入文件未生成："+error.getMessage()+"\n当前选择仍保留，可重试。");});}});
        }catch(Exception error){delivering=false;renderResults();message(error.getMessage());}
    }
    void message(String value){TextView text=label(value,14);text.setPadding(dp(16),dp(8),dp(16),dp(8));ScrollView scroll=new ScrollView(this);scroll.addView(text);new AlertDialog.Builder(this).setTitle("课程导入").setView(scroll).setPositiveButton("知道了",null).show();}
    int dp(int value){return (int)(value*getResources().getDisplayMetrics().density+.5f);}
    LinearLayout column(){LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.VERTICAL);return layout;}
    LinearLayout row(){LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.HORIZONTAL);return layout;}
    TextView label(String value,int size){TextView text=new TextView(this);text.setText(value);text.setTextSize(size);text.setTextColor(0xff191919);return text;}
    Button button(String title,Runnable action){return PlannerUi.compactButton(this,title,action);}
    EditText field(LinearLayout parent,String hint,String value,boolean numeric){EditText input=new EditText(this);input.setHint(hint);input.setText(value);input.setTextSize(13);input.setSingleLine();if(numeric)input.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);parent.addView(input,new LinearLayout.LayoutParams(parent.getOrientation()==LinearLayout.HORIZONTAL?0:-1,-2,parent.getOrientation()==LinearLayout.HORIZONTAL?1:0));return input;}
    @Override protected void onStop(){cancelPreview();super.onStop();}
    @Override protected void onDestroy(){generation++;cancelPreview();if(previewWork!=null)previewWork.close();if(searchWork!=null)searchWork.close();if(popup!=null)popup.dismiss();handler.removeCallbacksAndMessages(null);worker.shutdownNow();if(browser!=null){browser.stopLoading();browser.clearCache(true);browser.destroy();}if(replay!=null){replay.stopLoading();replay.destroy();}CookieManager.getInstance().removeAllCookies(null);WebStorage.getInstance().deleteAllData();super.onDestroy();}
}
