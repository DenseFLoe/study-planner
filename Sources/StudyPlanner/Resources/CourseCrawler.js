/* Read-only adapter for the site's own authenticated GET client. No tokens leave the page. */
(() => {
  const INFO = '/learn/v1/delivery/pc/my_delivery/info/';
  const STRUCTURE = '/learn/v1/delivery/my_outline/structure/';
  const LIST = '/ytky/v4/course/mycourse';
  const INVALID = '/ytky/v1/course/mycourse/invalid';
  const OTO = '/learn/v1/oto/livings/';
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  function checkedURL(value, base) {
    const url = new URL(value, base);
    if (url.origin !== location.origin || !url.pathname.startsWith('/_nuxt/') || !url.pathname.endsWith('.js')) throw Error('网页脚本来源异常');
    return url.href;
  }
  async function source(url) {
    const response = await fetch(url, {credentials: 'same-origin', signal: AbortSignal.timeout(15000)});
    if (!response.ok) throw Error('网页脚本加载失败');
    const text = await response.text();
    if (text.length > 5000000) throw Error('网页脚本过大');
    return text;
  }
  let client;
  async function discoverClient() {
    if (client) return client;
    const entry = [...document.scripts].map(s => s.src).find(s => s.startsWith(location.origin + '/_nuxt/') && s.endsWith('.js'));
    if (!entry) throw Error('尚未进入课程网站，请先登录');
    const entryText = await source(checkedURL(entry, location.href));
    const route = entryText.match(/name:["']appmanage-my-mycourse-delivery-packages-id-outline["'][\s\S]{0,500}?import\(["']([^"']+)["']\)/);
    if (!route) throw Error('研途网页已更新，未找到课程大纲模块');
    const outlineURL = checkedURL(route[1], entry);
    const outlineSource = await source(outlineURL);
    const imports = [...outlineSource.matchAll(/from\s*["']([^"']+)["']/g)].map(m => checkedURL(m[1], outlineURL));
    for (const url of [...new Set(imports)].slice(0,30)) {
      if (url === entry) continue;
      const text = await source(url);
      if (!text.includes(STRUCTURE)) continue;
      // The API module imports the site's authenticated request wrapper as r.
      const requestImport = text.match(/import\s*\{\s*r\s*\}\s*from\s*["']([^"']+)["']/);
      if (!requestImport) throw Error('研途请求封装已更新');
      const requestURL = checkedURL(requestImport[1], url);
      const module = await import(requestURL);
      if (typeof module.r?.get !== 'function') throw Error('研途请求接口不可用');
      client = module.r;
      return client;
    }
    throw Error('未找到完整大纲接口，请刷新后重试');
  }
  function normaliseSection(section, context) {
    if (section.course_section_id === undefined || !section.name) throw Error('课节缺少稳定 ID 或名称');
    const kind = String(section.mold || 'unknown');
    const published = section.publish_status === 'published';
    const duration = kind === 'video' ? section.video?.duration : section.living?.record?.duration;
    const seconds = Number(duration) / 1000;
    const percent = section.percent === null || section.percent === undefined || section.percent === '' ? null : Number(section.percent);
    return {
      id: context.packageID + ':' + String(section.course_section_id), name: String(section.name),
      subject: context.subject, stage: context.stage, chapter: context.chapter, kind, published,
      durationSeconds: Number.isFinite(seconds) && seconds > 0 ? seconds : null,
      watchedPercent: percent !== null && Number.isFinite(percent) && percent >= 0 && percent <= 100 ? percent : null,
      markedFinished: section.is_mark_finished === true,
      requiresDuration: kind === 'video' || (kind === 'living' && !!section.living?.has_record)
    };
  }
  async function collect(packageID, request, progress = () => {}) {
    if (!/^\d+$/.test(packageID)) throw Error('课程包编号无效');
    progress('正在读取课程包和全部科目…');
    const info = await request(INFO, {my_delivery_id: packageID});
    if (!info || !Array.isArray(info.outlines) || !info.name) throw Error('课程包信息无效或登录已失效');
    const outlines = [...new Map(info.outlines.map(o => [String(o.delivery_outline_id), o])).values()];
    const extras = Array.isArray(info.oto) ? info.oto : [];
    const result = {packageID, name: info.name,
      sourceURL: 'https://www.kaoyanvip.cn/appmanage/my/mycourse/delivery-packages/' + packageID + '/outline',
      fetchedAt: Date.now()/1000, expectedOutlines: outlines.length + extras.length, fetchedOutlines: 0, lessons: [], issues: []};
    const seen = new Map();
    function add(lesson) {
      const previous = seen.get(lesson.id);
      if (previous && (previous.durationSeconds !== lesson.durationSeconds || previous.watchedPercent !== lesson.watchedPercent || previous.published !== lesson.published)) {
        throw Error('重复课节的时长或进度不一致：' + lesson.name);
      }
      if (!previous) { seen.set(lesson.id, lesson); result.lessons.push(lesson); }
    }
    for (const outline of outlines) {
      progress(`正在抓取 ${outline.name}（${result.fetchedOutlines + 1}/${result.expectedOutlines}）…`);
      try {
        if (!outline.delivery_outline_id) throw Error('科目缺少编号');
        const data = await request(STRUCTURE, {my_delivery_id: packageID, delivery_outline_id: outline.delivery_outline_id});
        if (!Array.isArray(data?.outline)) throw Error('大纲结构无效');
        function walk(node, context) {
          if (!node || typeof node !== 'object') throw Error('章节结构无效');
          const next = {...context};
          if (node.stage_name) next.stage = String(node.stage_name);
          if (node.name) next.chapter = [context.chapter, node.name].filter(Boolean).join(' / ');
          if (node.course_sections !== undefined && !Array.isArray(node.course_sections)) throw Error('课节列表无效');
          for (const section of node.course_sections || []) add(normaliseSection(section, next));
          if (node.children !== undefined && !Array.isArray(node.children)) throw Error('子章节列表无效');
          for (const child of node.children || []) walk(child, next);
        }
        for (const stage of data.outline) walk(stage, {packageID, subject: String(outline.name || ''), stage:'', chapter:''});
        result.fetchedOutlines++;
      } catch (error) { result.issues.push(String(outline.name || '未知科目') + '：' + (error.message || '请求失败')); }
      await pause(200);
    }
    for (const extra of extras) {
      try {
        const data = await request(OTO, {my_delivery_id: packageID, outline_tp: extra.type});
        if (!Array.isArray(data?.livings)) throw Error('直播大纲结构无效');
        // Preserve special live lessons, but do not invent duration/progress for unverified fields.
        for (const subject of data.livings) for (const live of subject.livings || []) {
          if (!live.course_section_uuid || !live.name) throw Error('直播课节缺少编号');
          add({id: packageID + ':' + live.course_section_uuid, name: live.name, subject: subject.subject_name || extra.name || '直播',
            stage:'', chapter:'', kind:'living', published: live.status === 3,
            durationSeconds:null, watchedPercent:null, markedFinished:false, requiresDuration: !!live.has_record});
        }
        result.fetchedOutlines++;
      } catch (error) { result.issues.push((extra.name || '直播') + '：' + (error.message || '请求失败')); }
    }
    return result;
  }
  async function account(request, progress = () => {}) {
    const packages = new Map(), unavailable = [], issues = [];
    for (const p_type of [1,2]) for (const state of ['visible','hidden','expired']) {
      const path = state === 'expired' ? INVALID : LIST;
      let page = 1, pages = 1, count = null, loaded = 0;
      const pageKeys = new Set();
      do {
        progress(`正在获取${p_type === 1 ? '正式课' : '体验课'}·${state} 第 ${page} 页…`);
        try {
          const params = {paginator:1, p_type, page, size:50};
          if (state !== 'expired') params.is_display = state === 'visible' ? 1 : 0;
          const data = await request(path, params);
          if (!Array.isArray(data?.results)) throw Error('课程包列表格式异常');
          pages = Number(data.total_page);
          if (!Number.isInteger(pages) || pages < 0 || pages > 200 || Number(data.current_page) !== page) throw Error('分页信息异常');
          if (count === null) count = Number(data.count);
          if (!Number.isInteger(count) || count < 0 || Number(data.count) !== count) throw Error('抓取过程中课程包数量变化，请重试');
          const key = data.results.map(p => p.my_delivery_id || p.uuid).join('|');
          if (data.results.length && pageKeys.has(key)) throw Error('接口重复返回同一页');
          pageKeys.add(key); loaded += data.results.length;
          for (const item of data.results) {
            const id = String(item.my_delivery_id || '');
            if (state === 'expired' || !/^\d+$/.test(id)) {
              unavailable.push({name:String(item.name || '未命名课程'), reason:state === 'expired' ? '课程已失效，仅取得课程包信息，不能读取完整课节' : '旧版课程结构尚不支持，未计入学习量'});
            } else if (!packages.has(id)) packages.set(id, item);
          }
          page++;
          if (page > pages && loaded !== count) throw Error('分页数量与课程总数不一致');
          await pause(200);
        } catch (error) { issues.push(`${p_type === 1 ? '正式课' : '体验课'} ${state}：${error.message || '列表请求失败'}`); break; }
      } while (page <= pages);
    }
    const snapshots = [];
    let index = 0;
    for (const [id,item] of packages) {
      index++;
      try { snapshots.push(await collect(id, request, message => progress(`课程包 ${index}/${packages.size} · ${message}`))); }
      catch (error) { unavailable.push({name:String(item.name || id),reason:error.message || '课程包抓取失败'}); }
    }
    return {snapshots, unavailable, issues, packageCount:packages.size};
  }
  window.studyCourseCrawler = {
    collect, account, normaliseSection,
    async crawl(packageID) {
      const request = await discoverClient();
      const get = async (path, params) => {
        if (![INFO, STRUCTURE, OTO, LIST, INVALID].includes(path)) throw Error('不允许的接口');
        let timer;
        try {
          return await Promise.race([request.get(path, {params, headers: path === LIST ? {ytversion:'v5.9.0'} : {}}), new Promise((_, reject) => { timer = setTimeout(() => reject(Error('接口请求超时')), 20000); })]);
        } finally { clearTimeout(timer); }
      };
      return (packageID ? collect(packageID, get, status => window.webkit?.messageHandlers?.courseStatus?.postMessage(status)) : account(get, status => window.webkit?.messageHandlers?.courseStatus?.postMessage(status)));
    }
  };
})();
