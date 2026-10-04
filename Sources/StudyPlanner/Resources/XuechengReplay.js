/* Runs inside the site's embedded replay frame. Reports only course metadata,
   never the frame URL, playback token, cookies, media URL, or chat content. */
(() => {
  if (location.hostname !== 'view.csslcloud.net') return;
  let last = '';
  function report() {
    const lines = (document.body?.innerText || '').split('\n').map(line => line.trim()).filter(Boolean);
    const title = lines.find(line => line && !line.startsWith('直播时间') && line.length <= 200) || '';
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
    if (video && Number.isFinite(video.duration) && video.duration > 0 && video.duration <= 36000) durationSeconds = video.duration;
    if (!title || durationSeconds === null) return;
    const metadata = {title, durationSeconds, watchedPercent: null};
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
