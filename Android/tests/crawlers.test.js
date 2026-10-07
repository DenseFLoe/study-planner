const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
let checks = 0;
const verify = (value, message) => { checks++; assert.ok(value, message); };
const source = fs.readFileSync('Android/assets/crawlers/QuarkScan.js', 'utf8');
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
  // Verify all five adapters stay byte-for-byte identical to the desktop resources.
  for(const name of ['CourseCrawler','GenericCrawler','XuechengCrawler','XuechengReplay','QuarkCrawler']){
    const android=fs.readFileSync('Android/assets/crawlers/'+name+'.js');
    const desktop=fs.readFileSync('Sources/StudyPlanner/Resources/'+name+'.js');
    verify(android.equals(desktop),name+' adapter diverged');
    new vm.Script(android.toString());
  }
  console.log(`Crawler tests: ${checks} checks passed`);
})().catch(error=>{console.error(error);process.exitCode=1;});
