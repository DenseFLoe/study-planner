/* Framework-agnostic sniffer: records the page's own same-origin JSON responses.
   It never issues requests of its own, never reads cookies or tokens, and keeps everything in memory. */
(() => {
  if (window.studyGenericCrawler) return;
  const MAX_BODY = 1200000;
  const MAX_RECORDS = 240;
  const MAX_TOTAL = 6000000;
  const records = [];
  let revision = 0;
  let totalBytes = 0;
  let pendingRequests = 0;
  let completedRequests = 0;
  let failedRequests = 0;

  // Only activity counters are exposed; no credentials or request headers are read.
  function beginRequest(url) {
    if (!sameOrigin(url)) return () => {};
    pendingRequests++;
    let finished = false;
    return success => {
      if (finished) return;
      finished = true;
      pendingRequests--;
      completedRequests++;
      if (!success) failedRequests++;
    };
  }

  function sameOrigin(value) {
    try { return new URL(value, location.href).origin === location.origin; } catch { return false; }
  }
  function looksLikeJSON(text) {
    if (typeof text !== 'string' || text.length < 2 || text.length > MAX_BODY) return false;
    const head = text.slice(0, 200).trimStart();
    return head.startsWith('{') || head.startsWith('[');
  }
  function remember(url, method, text) {
    if (!sameOrigin(url) || !looksLikeJSON(text)) return;
    try {
      records.push({url: String(url), method: String(method || 'GET'), text});
      totalBytes += text.length;
      while (records.length > MAX_RECORDS || (totalBytes > MAX_TOTAL && records.length > 1)) {
        totalBytes -= records.shift().text.length;
      }
      revision++;
    } catch {}
  }
  function contentType(response) {
    try { return (response.headers && response.headers.get && response.headers.get('content-type')) || ''; } catch { return ''; }
  }

  try {
    const originalFetch = window.fetch;
    if (typeof originalFetch === 'function') {
      window.fetch = function (...args) {
        const pending = originalFetch.apply(this, args);
        try {
          const request = args[0];
          const url = typeof request === 'string' ? request : (request && request.url) || '';
          const method = (args[1] && args[1].method) || (request && request.method) || 'GET';
          const finish = beginRequest(url);
          pending.then(async response => {
            if (!response) { finish(false); return; }
            const kind = contentType(response);
            if (kind && !/json|text|javascript/i.test(kind)) { finish(response.ok); return; }
            try {
              remember(response.url || url, method, await response.clone().text());
              finish(response.ok);
            } catch { finish(false); }
          }).catch(() => finish(false));
        } catch {}
        return pending;
      };
    }
  } catch {}

  try {
    const Original = window.XMLHttpRequest;
    if (typeof Original === 'function' && Original.prototype) {
      const open = Original.prototype.open;
      const send = Original.prototype.send;
      Original.prototype.open = function (method, url, ...rest) {
        try { this.__studyURL = String(url); this.__studyMethod = String(method || 'GET'); } catch {}
        return open.call(this, method, url, ...rest);
      };
      Original.prototype.send = function (...args) {
        const finish = beginRequest(this.__studyURL || '');
        try {
          this.addEventListener('load', () => {
            try {
              const kind = this.responseType;
              if (kind && kind !== 'text' && kind !== 'json') return;
              const text = kind === 'json' ? JSON.stringify(this.response) : this.responseText;
              remember(this.responseURL || this.__studyURL || '', this.__studyMethod || 'GET', text || '');
            } catch {}
          }, {once: true});
          this.addEventListener('loadend', () => finish(this.status >= 200 && this.status < 400), {once: true});
        } catch {}
        try { return send.apply(this, args); }
        catch (error) { finish(false); throw error; }
      };
    }
  } catch {}

  window.studyGenericCrawler = {
    revision: () => revision,
    count: () => records.length,
    activity: () => ({pending: pendingRequests, completed: completedRequests, failed: failedRequests}),
    snapshot: () => records.map(record => ({url: record.url, method: record.method, body: record.text})),
    clear: () => { records.length = 0; totalBytes = 0; revision++; }
  };
})();
