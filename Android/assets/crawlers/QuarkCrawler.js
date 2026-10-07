/* Quark share reader.
   Runs inside the pan.quark.cn page so every call is same-origin and carries the user's own
   session. It only reads the share token and the share listing — it never saves, moves, deletes
   or downloads anything, and it keeps no tokens after the window closes. */
(() => {
  if (window.studyQuarkCrawler) return;

  const base = '/1/clouddrive/';
  const baseQuery = { pr: 'ucpro', fr: 'pc', uc_param_str: '' };
  let requests = 0;

  function queryString(query) {
    const merged = Object.assign({}, baseQuery, query || {});
    return Object.keys(merged)
      .filter(key => merged[key] !== undefined && merged[key] !== null)
      .map(key => encodeURIComponent(key) + '=' + encodeURIComponent(String(merged[key])))
      .join('&');
  }

  async function call(path, query, body) {
    if (typeof path !== 'string' || path.indexOf(base) !== 0) {
      return { ok: false, error: '拒绝访问非网盘接口：' + String(path) };
    }
    const url = path + '?' + queryString(query);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30000);
    const init = {
      method: body === undefined ? 'GET' : 'POST',
      credentials: 'include',
      signal: controller.signal,
      headers: { 'Accept': 'application/json, text/plain, */*' }
    };
    if (body !== undefined) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    try {
      const response = await fetch(url, init);
      requests++;
      const text = await response.text();
      return { ok: true, status: response.status, text: text };
    } catch (error) {
      return { ok: false, error: String((error && error.message) || error) };
    } finally {
      clearTimeout(timeout);
    }
  }

  window.studyQuarkCrawler = {
    ready: () => true,
    host: () => location.host,
    requests: () => requests,
    get: (path, query) => call(path, query, undefined),
    post: (path, query, body) => call(path, query, body || {})
  };
})();
