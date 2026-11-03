const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
// Pass an extracted APK assets directory to verify the delivered package too.
if (!process.argv[2]) execFileSync('python3', ['Android/prepare-assets.py'], {stdio: 'inherit'});
const assets = process.argv[2] || 'Android/build/assets';
const readCrawler = name => fs.readFileSync(path.join(assets, 'crawlers', name + '.js'));
let checks = 0;
const verify = (value, message) => { checks++; assert.ok(value, message); };
const source = readCrawler('QuarkScan').toString();
const envelope = data => ({ok:true,status:200,text:JSON.stringify(data)});
async function run(detail, folders = 60, files = 2000, host = 'pan.quark.cn') {
  const calls=[];
  const context={window:{},location:{hostname:host,pathname:'/s/synthetic'},URLSearchParams,document:{title:'Synthetic course'},Date,Set,Number,String,Error};
  context.studyQuarkCrawler={post:async(path,query,body)=>{calls.push({path,body});return envelope({code:0,data:{stoken:'PLACEHOLDER_TRANSIENT',title:'Synthetic course'}})},get:async(path,query)=>{calls.push({path,query});return envelope(await detail(query));}};
  vm.createContext(context);vm.runInContext(source,context);
  return {value:await context.window.studyQuarkScan('PLACEHOLDER_PASSCODE',folders,files),calls};
}
(async()=>{
  const item=(fid,name,dir=false)=>({fid,file_name:name,dir,size:1000,duration:600,share_fid_token:'PLACEHOLDER_FILE_TOKEN'});
  const result=await run(query=>query.pdir_fid==='0'?{code:0,data:{list:[item('folder','基础',true)]},metadata:{_count:1}}:{code:0,data:{list:[item('video','第一讲.mp4')]},metadata:{_count:1}});
  verify(result.value.entries.length===2,'Recursive directory missing');
  verify(result.value.entries[1].relativePath==='基础/第一讲.mp4','File path missing');
  verify(result.value.entries[1].durationSeconds===600,'Duration conversion changed');
  const serialized=JSON.stringify(result.value);
  verify(!serialized.includes('PLACEHOLDER')&&!serialized.includes('stoken')&&!serialized.includes('share_fid_token'),'Share credentials escaped into result');
  verify(result.calls.every(c=>c.path.includes('/share/sharepage/')),'Unexpected mutation API');
  const paged=await run(query=>({code:0,data:{list:query._page===1?[item('one','第一讲.mp4')]:[item('two','第二讲.mp4')]},metadata:{_count:2,_size:1}}));
  verify(paged.value.entries.length===2,'Shrunken provider page size stopped traversal early');
  for(const [detail,folders,files,host,pattern] of [
    [q=>({code:0,data:{list:[item('one','第一讲.mp4')]},metadata:{_count:2}}),60,2000,'pan.quark.cn',/重复/],
    [q=>({code:0,data:{list:[]},metadata:{_count:1}}),60,2000,'pan.quark.cn',/不完整/],
    [q=>({code:0,data:{list:[item('one','第一讲.mp4'),item('two','第二讲.mp4')]},metadata:{_count:2}}),60,1,'pan.quark.cn',/上限/],
    [q=>({code:41013,data:{}}),60,2000,'pan.quark.cn',/提取码/],
    [q=>({code:0,data:{list:[]},metadata:{_count:0}}),60,2000,'evil.test',/有效/],
  ]) {await assert.rejects(()=>run(detail,folders,files,host),pattern);checks++;}
  // Test the exact assets consumed by aapt2, including dependencies needed in
  // separate WebViews. No independently maintained Android copies remain.
  for(const name of ['CourseCrawler','GenericCrawler','XuechengCrawler','XuechengReplay','QuarkCrawler']){
    const android=readCrawler(name);
    const desktop=fs.readFileSync('Sources/StudyPlanner/Resources/'+name+'.js');
    const expected=name.startsWith('Xuecheng')
      ? Buffer.concat([fs.readFileSync('Sources/StudyPlanner/Resources/XuechengAvailability.js'), Buffer.from('\n'), desktop])
      : desktop;
    verify(android.equals(expected),name+' packaged adapter diverged');
    new vm.Script(android.toString());
  }
  // A catalog WebView and a replay WebView do not share window globals.
  // Exercise both packaged entry points in fresh contexts, rather than only
  // checking source equality (which missed the new classifier dependency).
  const label = textContent => ({textContent, children: [], getClientRects:()=>[{}], closest:()=>null});
  const rows = [['第一讲','直播回放'], ['第二讲','直播回放','回放未更新']].map(labels=>({
    isConnected:true, querySelectorAll:()=>labels.map(label), click(){this.clicked=true;}
  }));
  const catalogContext = {
    window:{}, location:{hostname:'www.ixuecheng.cn',pathname:'/detail',search:'?id=synthetic'},
    URLSearchParams, getComputedStyle:()=>({visibility:'visible'}),
    document:{body:{innerText:'示例课程\n课程有效期'},querySelectorAll:selector=>
      selector.includes('ic_course_live') ? rows.map(row=>({closest:()=>row})) : []}
  };
  vm.createContext(catalogContext);
  vm.runInContext(readCrawler('XuechengCrawler').toString(),catalogContext);
  const catalog = await catalogContext.window.studyXuechengCrawler.catalog();
  verify(catalog.rows.length===2 && catalog.rows[0].name==='第一讲','Packaged catalog failed to load');
  verify(catalog.rows[1].availability==='pending','Packaged catalog lost availability dependency');
  verify(await catalogContext.window.studyXuechengCrawler.open(0) && rows[0].clicked,'Published replay did not open');
  verify(!await catalogContext.window.studyXuechengCrawler.open(1) && !rows[1].clicked,'Pending replay should not open');
  const replay = (status, duration) => {
    const messages=[];
    const body={innerText:'第一讲\n'+status,querySelectorAll:()=>[label('第一讲'),label(status)]};
    const context={
      window:{webkit:{messageHandlers:{replayMetadata:{postMessage:value=>messages.push(value)}}}},
      location:{hostname:'view.csslcloud.net',pathname:'/replay'},
      document:{body,documentElement:body,addEventListener(){},querySelector:()=>duration ? {duration} : null},
      getComputedStyle:()=>({visibility:'visible'}),MutationObserver:class{observe(){}}
    };
    vm.createContext(context);
    vm.runInContext(readCrawler('XuechengReplay').toString(),context);
    return messages;
  };
  verify(replay('',600)[0]?.durationSeconds===600,'Standalone replay asset did not report duration');
  const pending=replay('回放未更新',null)[0];
  verify(pending?.availability==='pending' && pending.durationSeconds===null,'Pending replay misreported duration');
  const blocked=replay('请先登录',600)[0];
  verify(blocked?.availability==='blocked' && blocked.durationSeconds===null,'Blocked replay misreported duration');
  console.log(`Crawler tests: ${checks} checks passed`);
})().catch(error=>{console.error(error);process.exitCode=1;});
