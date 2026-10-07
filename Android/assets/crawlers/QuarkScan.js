/* Android traversal adapter. Share credentials remain inside this page, never in the result. */
window.studyQuarkScan = async (passcode, maxFolders, maxFiles) => {
  const match = location.pathname.match(/^\/s\/([A-Za-z0-9]+)/);
  if (location.hostname !== 'pan.quark.cn' || !match) throw Error('请打开有效的夸克分享链接。');
  const pwdID = match[1], fragment = location.hash?.match(/(?:^#|\/)share\/([A-Za-z0-9]{4,64})(?:\/|$)/), entries = [], visited = new Set(), queue = [{fid: fragment?.[1] || '0', path: '', depth: 0}];
  passcode = passcode || new URLSearchParams(location.search || '').get('pwd') || new URLSearchParams(location.search || '').get('passcode') || '';
  async function read(path, query, body) {
    const response = body === undefined ? await studyQuarkCrawler.get(path, query) : await studyQuarkCrawler.post(path, query, body);
    if (!response.ok || response.status < 200 || response.status >= 300) throw Error('分享读取失败，请检查网络或重新登录。');
    let data; try { data = JSON.parse(response.text); } catch { throw Error('网盘返回格式异常。'); }
    if (Number(data.code || 0) !== 0 || Number(data.status || 200) < 200 || Number(data.status || 200) >= 300) {
      const code = Number(data.code);
      if ([41008, 41011, 41013, 41014, 41015].includes(code)) throw Error('分享需要提取码或提取码不正确，请重新填写。');
      throw Error('分享不可读取，可能已失效、受限或需要登录。');
    }
    return data;
  }
  const token = (await read('/1/clouddrive/share/sharepage/token', {}, {pwd_id: pwdID, passcode, support_visit_limit_private_share: true})).data;
  if (!token?.stoken) throw Error('未取得分享访问权限。');
  if (['1', 'true'].includes(String(token.passcode)) && !passcode) throw Error('该分享需要提取码，请填写后重新读取。');
  while (queue.length) {
    const folder = queue.shift();
    if (visited.has(folder.fid)) throw Error('目录重复或循环，请重新读取。');
    if (visited.size >= maxFolders || folder.depth > 18) throw Error('分享超过目录读取上限，请提高上限后重新读取。');
    visited.add(folder.fid);
    const seen = new Set(); let total = null, page = 1;
    while (true) {
      window.__studyStatus = `正在读取 ${folder.path || '分享根目录'} · 第 ${page} 页 · ${entries.length} 个条目`;
      const response = await read('/1/clouddrive/share/sharepage/detail', {pwd_id: pwdID, stoken: token.stoken, pdir_fid: folder.fid, passcode, ver: 2, _page: page, _size: 100, _fetch_banner: 0, _fetch_share: 0, fetch_relate_conversation: 0, _fetch_total: 1, _sort: '', force: 0});
      const list = response.data?.list;
      if (!Array.isArray(list)) throw Error('目录列表缺失，请重试。');
      const meta = response.metadata || response.data?.metadata || {};
      const count = Number(meta._count ?? meta._total ?? response.data?.total);
      if (Number.isFinite(count) && count >= 0) { if (total !== null && total !== count) throw Error('读取期间目录发生变化，请重试。'); total = count; }
      let added = 0;
      for (const raw of list) {
        const fid = String(raw.fid || ''), name = String(raw.file_name || '');
        if (!fid || !name || name.includes('/') || name === '.' || name === '..') throw Error('目录条目信息不完整。');
        if (seen.has(fid)) continue; seen.add(fid); added++;
        if (entries.length >= maxFiles) throw Error('分享超过条目读取上限，请提高上限后重新读取。');
        const path = [folder.path, name].filter(Boolean).join('/'), isDirectory = raw.dir === true || raw.file === false;
        const info = raw.video_info || raw.videoInfo || {};
        const item = {fid, name, relativePath: path, parentPath: folder.path, isDirectory, size: Number(raw.size || 0), category: Number(raw.category || 0), formatType: String(raw.format_type || ''), status: Number(raw.status ?? 1), banned: !!raw.ban, badContent: !!raw.bad_content, riskType: Number(raw.risk_type || 0)};
        const seconds = Number(raw.duration ?? info.duration);
        if (Number.isFinite(seconds) && seconds > 0) item.durationSeconds = seconds;
        for (const key of ['width', 'height']) { const value = Number(raw['video_' + key] ?? info[key]); if (Number.isFinite(value) && value > 0) item[key] = value; }
        entries.push(item);
        if (isDirectory) queue.push({fid, path, depth: folder.depth + 1});
      }
      if (total !== null && seen.size === total) break;
      if (total !== null && (seen.size > total || !list.length)) throw Error('目录分页不完整，请重试。');
      if (!added && list.length) throw Error('目录分页重复，请重试。');
      if (total === null && list.length < 100) break;
      if (++page > 500) throw Error('目录页数超过上限。');
    }
  }
  return {pwdID, shareTitle: String(token.title || document.title || '网盘课程'), sourceURL: 'https://pan.quark.cn/s/' + pwdID, fetchedAt: Date.now()/1000 - 978307200, entries};
};
