/* Traverse ixuecheng.cn's accordion depth-first. Siblings cannot stay open
   together, so save each branch before moving on. Replay links stay in WebKit. */
(() => {
  if (!/^(www\.)?ixuecheng\.cn$/i.test(location.hostname) || window.studyXuechengCrawler) return;
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const clean = value => String(value || '').trim().replace(/\s+/g, ' ');
  let state;
  const pageKey = () => location.pathname + location.search;
  const visible = element => element.isConnected && element.getClientRects().length > 0 &&
    getComputedStyle(element).visibility !== 'hidden';
  const direct = (element, selector) => [...element.children].find(child => child.matches(selector));
  const items = list => [...list.children].filter(child => child.matches('.ant-collapse-item'));
  const header = item => direct(item, '.ant-collapse-header');
  const panel = item => direct(item, '.ant-collapse-content');
  function lists(scope) {
    return [...scope.querySelectorAll('.ant-collapse[role="tablist"]')].filter(list => {
      const parent = list.parentElement.closest('.ant-collapse[role="tablist"]');
      return !parent || !scope.contains(parent);
    });
  }
  function rows(scope = document) {
    return [...scope.querySelectorAll('img[src*="ic_course_live"]')]
      .map(image => image.closest('div.cursor-pointer'))
      .filter((row, index, all) => row && all.indexOf(row) === index);
  }
  function describe(row) {
    const labels = [...row.querySelectorAll('span')].map(span => clean(span.textContent)).filter(Boolean);
    const name = labels.find(line => line !== '上次观看' && line !== '直播回放' &&
      !line.startsWith('直播时间') && !/^\d+$/.test(line)) || '';
    // textContent also works for retained, currently collapsed panels.
    const text = clean(row.textContent);
    return {name, replay: text.includes('直播回放'), previouslyWatched: text.includes('上次观看')};
  }
  function courseName() {
    const lines = (document.body?.innerText || '').split('\n').map(clean).filter(Boolean);
    const validity = lines.findIndex(line => line.startsWith('课程有效期'));
    return validity > 0 ? lines[validity - 1] : '';
  }
  function check(current) {
    if (state !== current || current.page !== pageKey()) throw Error('课程页面已切换，请重新读取');
  }
  const activity = () => window.studyGenericCrawler?.activity?.() ?? {pending: 0, completed: 0, failed: 0};
  async function settle(scope, current, ready = () => true) {
    const started = Date.now();
    const failed = activity().failed;
    let previous = '', changed = started;
    while (Date.now() - started < 8000) {
      check(current);
      const requests = activity();
      if (requests.failed > failed) throw Error('课程目录请求失败，请重新识别课程');
      const fingerprint = scope.textContent + ':' + scope.querySelectorAll('*').length + ':' + requests.completed;
      if (fingerprint !== previous) changed = Date.now();
      previous = fingerprint;
      const loading = scope.querySelector('[aria-busy="true"], .ant-spin-spinning, .ant-skeleton');
      if (!requests.pending && !loading && Date.now() - started >= 1000 && Date.now() - changed >= 500 && ready()) return;
      await pause(100);
    }
    throw Error('课程目录加载超时，请重新识别课程');
  }
  async function expand(item, current) {
    const control = header(item);
    if (!control) throw Error('课程目录结构已变化');
    if (control.getAttribute('aria-expanded') !== 'true') control.click();
    await settle(item, current, () => control.getAttribute('aria-expanded') === 'true' &&
      !!panel(item));
  }
  function remember(scope, path, current) {
    rows(scope).forEach((row, index) => {
      const entry = describe(row);
      if (!entry.name) return;
      const key = path.flat().join('.') + ':' + index;
      current.entries.set(key, {...entry, key, path, rowIndex: index});
    });
  }
  async function walk(scope, path, current) {
    const children = lists(scope);
    if (!children.length) { remember(scope, path, current); return; }
    for (const [listIndex, list] of children.entries()) {
      for (const [itemIndex, item] of items(list).entries()) {
        check(current);
        const branch = [...path, [listIndex, itemIndex]];
        const key = branch.flat().join('.');
        if (current.visited.has(key)) continue;
        await expand(item, current);
        await walk(panel(item), branch, current);
        current.visited.add(key);
      }
    }
  }
  async function collect(current) {
    if (lists(document).length) {
      await walk(document, [], current);
    } else {
      // Small flat catalogs: click the actual control, never its broad parent.
      const clicked = new Set();
      for (;;) {
        const control = [...document.querySelectorAll('[role="tab"][aria-expanded="false"], button')]
          .find(element => visible(element) && !clicked.has(element) &&
            (element.getAttribute('aria-expanded') === 'false' || clean(element.textContent) === '展开'));
        if (!control) break;
        clicked.add(control);
        control.click();
        await settle(document.body, current);
      }
      remember(document, [], current);
    }
    check(current);
    return {courseID: current.courseID, name: courseName(), rows: [...current.entries.values()].map(
      ({name, replay, previouslyWatched, key}) => ({name, replay, previouslyWatched, key}))};
  }
  window.studyXuechengCrawler = {
    async catalog(force = false) {
      if (location.pathname !== '/detail') return null;
      const courseID = new URLSearchParams(location.search).get('id');
      if (!courseID || !courseName()) return null;
      if (!state || state.page !== pageKey() || (force && !state.pending)) {
        state = {page: pageKey(), courseID, entries: new Map(), visited: new Set()};
      }
      const current = state;
      // Timer ticks and page responses share one traversal rather than toggling each other.
      if (!current.pending) current.pending = collect(current).finally(() => { current.pending = null; });
      return current.pending;
    },
    async open(index) {
      const current = state;
      if (!current || current.page !== pageKey()) return false;
      const entry = [...current.entries.values()][index];
      if (!entry?.replay) return false;
      let scope = document;
      for (const [listIndex, itemIndex] of entry.path) {
        check(current);
        const list = lists(scope)[listIndex];
        const item = list && items(list)[itemIndex];
        if (!item) return false;
        await expand(item, current);
        scope = panel(item);
      }
      check(current);
      const row = rows(scope)[entry.rowIndex];
      if (!row || describe(row).name !== entry.name || !describe(row).replay) return false;
      row.click();
      return true;
    }
  };
})();
