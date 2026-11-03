/* Runs inside the site's embedded replay frame. Reports only course metadata,
   never the frame URL, playback token, cookies, media URL, or chat content. */
(() => {
  const replayPage = location.hostname === 'view.csslcloud.net';
  if (!replayPage && !(/^(www\.)?ixuecheng\.cn$/.test(location.hostname) && location.pathname === '/backWindow')) return;
  let last = '';
  function report() {
    const lines = (document.body?.innerText || '').split('\n').map(line => line.trim()).filter(Boolean);
    const classifier = window.studyXuechengAvailability;
    const labels = classifier.labels(document.body || document.documentElement);
    const availability = classifier.classify(labels, true);
    const title = lines.find(line => line && !line.startsWith('直播时间') && line.length <= 200 &&
      !classifier.classify([line]) && !/^(提示|温馨提示|确定|关闭|返回|请耐心等待)$/.test(line)) || '';
    const timing = lines.find(line => line.startsWith('直播时间')) || '';
    const match = timing.match(/(\d{4}-\d\d-\d\d)\s+(\d\d):(\d\d)\s*[-–—]\s*(?:(\d{4}-\d\d-\d\d)\s+)?(\d\d):(\d\d)/);
    let durationSeconds = null;
    if (match) {
      const start = Date.parse(`${match[1]}T${match[2]}:${match[3]}:00`);
      let end = Date.parse(`${match[4] || match[1]}T${match[5]}:${match[6]}:00`);
      if (end <= start && !match[4]) end += 86400000;
      const seconds = (end - start) / 1000;
      if (Number.isFinite(seconds) && seconds > 0 && seconds <= 36000) durationSeconds = seconds;
    }
    const video = document.querySelector('video');
    const playable = video && Number.isFinite(video.duration) && video.duration > 0 && video.duration <= 36000;
    if (playable) durationSeconds = video.duration;
    // A scheduled time range is not evidence that the recording exists yet.
    // Wrapper pages can supply a status, but never a verified playback duration.
    let metadata;
    if (availability === 'blocked' || (availability === 'pending' && !playable)) {
      metadata = {title, durationSeconds: null, watchedPercent: null, availability};
    } else if (replayPage && title && durationSeconds !== null) {
      metadata = {title, durationSeconds, watchedPercent: null};
    } else { return; }
    const encoded = JSON.stringify(metadata);
    if (encoded !== last) {
      last = encoded;
      window.webkit?.messageHandlers?.replayMetadata?.postMessage(metadata);
    }
  }
  document.addEventListener('DOMContentLoaded', report);
  document.addEventListener('loadedmetadata', report, true);
  const observer = new MutationObserver(report);
  observer.observe(document.documentElement, {childList: true, subtree: true, characterData: true});
  report();
})();
