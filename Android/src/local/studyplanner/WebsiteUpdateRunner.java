package local.studyplanner;

import android.content.*;
import android.os.*;
import android.webkit.*;
import androidx.webkit.*;
import org.json.*;
import java.net.URI;
import java.util.*;
import java.util.function.Consumer;

/** One bounded browser update. Account values only enter a checked provider login form. */
final class WebsiteUpdateRunner {
    static WebsiteUpdateRunner current;
    static boolean initialized;
    final Context context;
    final String courseID;
    final boolean interactive;
    final Handler handler=new Handler(Looper.getMainLooper());
    final PlannerRuntime runtime;
    final Consumer<String> notice;
    final Consumer<Boolean> completion;
    final Map<String,String> scripts=new HashMap<>();
    WebView browser,replay;
    JSONObject binding,credentials,original;
    String site,url;
    volatile boolean closed,completed;
    boolean reading,submitted;
    volatile int generation;
    long loginDeadline;
    WebsiteUpdateRunner(Context c,String id,boolean interactive,Consumer<String> notice,Consumer<Boolean> completion){
        context=c;courseID=id;this.interactive=interactive;this.notice=notice;this.completion=completion;runtime=PlannerRuntime.get(c);
    }
    void start(Consumer<WebView> ready){
        if(current!=null){notice.accept("已有网站更新正在进行，请稍后重试。");completion.accept(false);return;}current=this;
        notice.accept("正在准备网站更新…");
        runtime.worker.execute(()->{try{
            binding=WebsiteSourceSettings.get(context,courseID);original=Planner.course(runtime.database.load(),courseID);
            if(original==null)throw new IllegalArgumentException("课程已删除。");
            url=WebsiteUpdatePolicy.sourceURL(binding.getString("url"),original);site=WebsiteUpdatePolicy.site(url);
            credentials=WebsiteSourceSettings.credentials(context,site);
            for(String name:new String[]{"CourseCrawler","GenericCrawler","XuechengCrawler","XuechengReplay"})scripts.put(name,MainActivity.read(context.getAssets().open("crawlers/"+name+".js")));
            scripts.put("login",MainActivity.read(context.getAssets().open("website/login.js")));
            binding.put("lastAttempt",System.currentTimeMillis()).put("status","正在读取网站课程");WebsiteSourceSettings.put(context,courseID,binding);
            handler.post(()->{if(closed)return;try{
                if(!initialized){if(Build.VERSION.SDK_INT>=28)WebView.setDataDirectorySuffix("website-updates");initialized=true;}
                browser=web(false);ready.accept(browser);restart();
                if(!interactive)handler.postDelayed(()->fail("本次更新达到时间上限，原课程已保留。",false),8*60*1000);
            }catch(Exception error){fail("无法启动网页，请检查系统 WebView。",false);}});
        }catch(Exception error){handler.post(()->fail("更新设置或本机账号无法读取，请重新核对。",false));}});
    }
    boolean allowed(String target,boolean child){
        if(site.equals(WebsiteUpdatePolicy.site(target)))return true;
        if(child)try{URI u=new URI(target);return "https".equals(u.getScheme())&&"view.csslcloud.net".equals(u.getHost())&&u.getUserInfo()==null&&(u.getPort()==-1||u.getPort()==443);}catch(Exception ignored){}
        return false;
    }
    WebView web(boolean child){
        WebView view=new WebView(context);if(!interactive){view.measure(android.view.View.MeasureSpec.makeMeasureSpec(1080,android.view.View.MeasureSpec.EXACTLY),android.view.View.MeasureSpec.makeMeasureSpec(1920,android.view.View.MeasureSpec.EXACTLY));view.layout(0,0,1080,1920);}
        WebSettings settings=view.getSettings();settings.setJavaScriptEnabled(true);settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);settings.setAllowContentAccess(false);settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSupportMultipleWindows(true);settings.setJavaScriptCanOpenWindowsAutomatically(true);settings.setMediaPlaybackRequiresUserGesture(true);
        settings.setUserAgentString(settings.getUserAgentString().replace("; wv","").replace("Mobile ",""));
        CookieManager.getInstance().setAcceptCookie(true);CookieManager.getInstance().setAcceptThirdPartyCookies(view,true);
        if(!child&&WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)){
            Set<String> origins=new HashSet<>();for(String host:hosts())origins.add("https://"+host);
            WebViewCompat.addDocumentStartJavaScript(view,scripts.get("GenericCrawler"),origins);
        }
        view.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView v,WebResourceRequest r){return !allowed(r.getUrl().toString(),child);}
            @Override public void onPageStarted(WebView v,String target,android.graphics.Bitmap icon){
                if(!allowed(target,child)){v.stopLoading();fail("网页离开已绑定的网站，更新已暂停。",true);return;}
                if(!child){generation++;if(reading){fail("课程读取期间页面已变化，请重新更新。",false);return;}v.evaluateJavascript(scripts.get("GenericCrawler"),null);}
            }
            @Override public void onPageFinished(WebView v,String target){if(closed)return;if(child){replayURL(v,target);return;}if(!completed)handler.postDelayed(WebsiteUpdateRunner.this::login,1500);}
            @Override public void onReceivedError(WebView v,WebResourceRequest request,WebResourceError error){if(request.isForMainFrame())fail("网页加载失败，请检查网络后重试。",false);}
            @Override public boolean onRenderProcessGone(WebView v,RenderProcessGoneDetail detail){fail("网页进程已结束，请关闭窗口后重新打开更新。原课程已保留。",false);close();return true;}
        });
        view.setWebChromeClient(new WebChromeClient(){
            @Override public boolean onCreateWindow(WebView v,boolean dialog,boolean gesture,Message message){
                if(closed||!reading)return false;if(replay!=null)replay.destroy();replay=web(true);
                ((WebView.WebViewTransport)message.obj).setWebView(replay);message.sendToTarget();return true;
            }
        });return view;
    }
    String[] hosts(){return site.equals("yantu")?new String[]{"kaoyanvip.cn","www.kaoyanvip.cn"}:new String[]{"ixuecheng.cn","www.ixuecheng.cn"};}
    void restart(){if(closed||browser==null)return;generation++;reading=false;completed=false;submitted=false;loginDeadline=SystemClock.elapsedRealtime()+45000;browser.loadUrl(url);}
    void login(){
        if(closed||reading||completed)return;
        if(SystemClock.elapsedRealtime()>loginDeadline){fail("需要登录或人工验证，请在窗口中处理后重新更新。",true);return;}
        if(!allowed(browser.getUrl(),false)){fail("网页离开已绑定的网站。",true);return;}
        final int currentGeneration=generation;
        String script=scripts.get("login")+";studyWebsiteLogin("+new JSONArray(Arrays.asList(hosts()))+","+JSONObject.quote(site)+","+(!submitted&&credentials!=null?credentials.toString():"null")+")";
        browser.evaluateJavascript(script,encoded->{if(closed||generation!=currentGeneration||completed)return;try{
            Object value=new JSONTokener(encoded).nextValue();String status=String.valueOf(value);
            if(status.equals("submitted")){submitted=true;handler.postDelayed(this::login,2500);}
            else if(status.equals("switching"))handler.postDelayed(this::login,1000);
            else if(status.equals("ready")){
                WebsiteUpdatePolicy.sourceURL(browser.getUrl(),original);
                capture();
            }else if(status.equals("login-required")&&submitted&&SystemClock.elapsedRealtime()<loginDeadline-20000)handler.postDelayed(this::login,1500);
            else fail("需要登录或人工验证，请在窗口中处理后重新更新。",true);
        }catch(Exception error){
            // Login pages may report ready before redirecting to the bound course.
            if(!closed&&!completed&&allowed(browser.getUrl(),false)){browser.loadUrl(url);}else fail("课程网页无法核对。",true);
        }});
    }
    void inject(){browser.evaluateJavascript("window.webkit={messageHandlers:{courseStatus:{postMessage:v=>window.__studyStatus=String(v)}}};",null);for(String name:new String[]{"GenericCrawler","CourseCrawler","XuechengCrawler"})browser.evaluateJavascript(scripts.get(name),null);}
    interface ValueWork<T>{T run()throws Exception;}
    <T> void background(ValueWork<T> work,Consumer<T> done){final int token=generation;runtime.worker.execute(()->{try{if(closed||generation!=token||completed)return;T value=work.run();handler.post(()->{if(!closed&&generation==token&&!completed)done.accept(value);});}catch(Exception error){handler.post(()->{if(!closed&&generation==token&&!completed)fail(error instanceof IllegalArgumentException?error.getMessage():"课程读取或保存失败，原数据已保留。",false);});}});}
    void promise(WebView web,String expression,long timeout,Consumer<Object> done){
        final int token=generation;final long until=SystemClock.elapsedRealtime()+timeout;String key="__plannerUpdate"+UUID.randomUUID().toString().replace("-","");
        web.evaluateJavascript("window['"+key+"']={pending:true};Promise.resolve().then(()=> ("+expression+")).then(value=>window['"+key+"']={value}).catch(()=>window['"+key+"']={error:true});",null);
        Runnable poll=new Runnable(){public void run(){if(closed||completed||generation!=token)return;if(SystemClock.elapsedRealtime()>until){fail("课程读取超时，原课程已保留。",false);return;}
            web.evaluateJavascript("JSON.stringify(window['"+key+"']||{pending:true})",encoded->background(()->{if(encoded==null||encoded.length()>16*1024*1024)throw new IllegalArgumentException("课程结果超出读取上限。");return CourseCaptureIntake.envelope(encoded);},value->{
                if(value.optBoolean("pending")){handler.postDelayed(this,350);return;}web.evaluateJavascript("delete window['"+key+"']",null);
                if(value.optBoolean("error")){fail("网站未返回完整课程，请核对登录与课程权限。",true);return;}done.accept(value.opt("value"));
            }));}};handler.postDelayed(poll,250);
    }
    void capture(){if(closed||reading||completed)return;reading=true;notice.accept("正在读取课程目录与课节…");inject();
        if(site.equals("yantu"))promise(browser,"studyCourseCrawler.run()",360000,value->background(()->CourseCaptureIntake.yantu((JSONObject)value),prepared->accept(prepared.values)));
        else promise(browser,"(async()=>{const catalog=await studyXuechengCrawler.catalog(true);return {catalog,responses:studyGenericCrawler.snapshot(),activity:studyGenericCrawler.activity(),url:location.href,title:document.title};})()",180000,value->background(()->CourseCaptureIntake.generic((JSONObject)value,Planner.now()),prepared->{if(prepared.replay==null)accept(prepared.values);else readReplay(prepared.replay,prepared.replayRows,0,prepared.values);}));
    }
    void replayURL(WebView view,String target){
        if(!allowed(target,true)){fail("回放网址不受支持。",false);return;}
        view.evaluateJavascript("window.webkit={messageHandlers:{replayMetadata:{postMessage:v=>window.__studyReplay=v}}};"+scripts.get("XuechengReplay"),null);
        if(!target.startsWith("https://view.csslcloud.net/"))view.evaluateJavascript("(()=>{const f=[...document.querySelectorAll('iframe')].find(f=>{try{return new URL(f.src).hostname==='view.csslcloud.net'}catch{return false}});return f?f.src:null})()",encoded->{try{Object raw=new JSONTokener(encoded).nextValue();if(raw instanceof String&&allowed((String)raw,true))view.loadUrl((String)raw);}catch(Exception ignored){}});
    }
    void readReplay(JSONObject snapshot,JSONArray rows,int index,List<JSONObject> base){try{
        while(index<rows.length()&&(!rows.getJSONObject(index).optBoolean("replay")||snapshot.getJSONArray("lessons").getJSONObject(index).has("durationSeconds")))index++;
        if(index==rows.length()){background(()->WebsiteCapture.merge(base,Collections.singletonList(snapshot)),this::accept);return;}
        final int row=index;notice.accept("正在读取直播回放 "+(index+1)+" / "+rows.length());if(replay!=null){replay.destroy();replay=null;}
        promise(browser,"studyXuechengCrawler.open("+index+")",30000,value->{if(!Boolean.TRUE.equals(value)){fail("回放入口无法打开。",false);return;}pollReplay(snapshot,rows,row,base,SystemClock.elapsedRealtime()+45000,generation);});
    }catch(Exception error){fail("回放目录不完整。",false);}}
    void pollReplay(JSONObject snapshot,JSONArray rows,int index,List<JSONObject> base,long until,int token){
        if(closed||completed||token!=generation)return;if(SystemClock.elapsedRealtime()>until){fail("回放时长未能完整读取，更新已暂停。",false);return;}
        if(replay==null){handler.postDelayed(()->pollReplay(snapshot,rows,index,base,until,token),400);return;}
        replay.evaluateJavascript("JSON.stringify(window.__studyReplay||null)",encoded->{if(closed||completed||token!=generation)return;try{
            Object raw=new JSONTokener(encoded).nextValue();JSONObject meta=raw instanceof String?new JSONObject((String)raw):null;
            if(meta!=null&&meta.optString("title").replaceAll("\\s+","").equals(rows.getJSONObject(index).optString("name").replaceAll("\\s+",""))){
                JSONObject lesson=snapshot.getJSONArray("lessons").getJSONObject(index);
                if(meta.optString("availability").equals("blocked")){fail("回放需要登录或权限核对。",true);return;}
                if(meta.optString("availability").equals("pending")){lesson.put("published",false).put("requiresDuration",false);lesson.remove("durationSeconds");readReplay(snapshot,rows,index+1,base);return;}
                if(meta.optDouble("durationSeconds")>0){lesson.put("durationSeconds",meta.getDouble("durationSeconds"));if(!lesson.has("watchedPercent"))lesson.put("watchedPercent",0);readReplay(snapshot,rows,index+1,base);return;}
            }
        }catch(Exception ignored){}handler.postDelayed(()->pollReplay(snapshot,rows,index,base,until,token),400);});
    }
    void accept(List<JSONObject> captures){background(()->{
        JSONObject found=null;for(JSONObject capture:captures)if(WebCourseImport.sameIdentity(original.getJSONObject("webCourse"),capture)){if(found!=null)throw new IllegalArgumentException("同一来源出现多个课程，更新已暂停。");found=capture;}
        if(found==null)throw new IllegalArgumentException("未读取到绑定课程，原课程已保留。");return WebsiteUpdatePolicy.validate(found,original);
    },this::save);}
    void save(JSONObject snapshot){
        if(closed||completed)return;
        if(DraftEditorDialog.openCount>0){notice.accept("目录读取完成，等待关闭课程或事项编辑窗口后保存…");handler.postDelayed(()->save(snapshot),500);return;}
        background(()->{
            if(DraftEditorDialog.openCount>0)throw new IllegalArgumentException("编辑窗口已打开，结果未写入，请稍后更新。");
            JSONObject latestBinding=WebsiteSourceSettings.get(context,courseID);
            if(!binding.optString("revision").equals(latestBinding.optString("revision"))||!interactive&&!latestBinding.optBoolean("enabled"))throw new IllegalArgumentException("更新设置已变化，本次结果未写入。");
            runtime.database.update(state->{
                if(closed||completed)throw new IllegalArgumentException("更新已取消。");
                JSONObject course=Planner.course(state,courseID);if(course==null||!url.equals(WebsiteUpdatePolicy.sourceURL(url,course)))throw new IllegalArgumentException("课程来源已变化，本次结果未写入。");
                WebsiteUpdatePolicy.apply(state,courseID,snapshot,Planner.now());
                if(closed||completed)throw new IllegalArgumentException("更新已取消。");
            });
            // A preferences failure after a committed course must not be reported as a rollback.
            try{latestBinding.put("lastSuccess",System.currentTimeMillis()).put("needsAttention",false).put("status","课程已更新");WebsiteSourceSettings.put(context,courseID,latestBinding);WebsiteSourceSettings.recovered(context,site);}catch(Exception ignored){}
            return true;
        },ok->{completed=true;reading=false;credentials=null;notice.accept("课程已更新，学习记录已保留。");context.sendBroadcast(new Intent(CloudSync.ACTION).setPackage(context.getPackageName()));completion.accept(true);if(!interactive)close();});
    }
    void fail(String message,boolean login){
        if(closed||completed)return;completed=true;reading=false;generation++;credentials=null;notice.accept(message);
        runtime.worker.execute(()->{try{if(login&&site!=null)WebsiteSourceSettings.pauseSite(context,site);else WebsiteSourceSettings.status(context,courseID,message,true);}catch(Exception ignored){}});
        completion.accept(false);if(!interactive)close();
    }
    void close(){if(closed)return;closed=true;generation++;handler.removeCallbacksAndMessages(null);credentials=null;
        for(WebView view:new WebView[]{browser,replay})if(view!=null){view.stopLoading();if(view.getParent() instanceof android.view.ViewGroup)((android.view.ViewGroup)view.getParent()).removeView(view);view.destroy();}
        browser=null;replay=null;if(current==this)current=null;
    }
}
