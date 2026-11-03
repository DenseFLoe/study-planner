/* Classify explicit website status labels, never arbitrary lesson titles or
   missing player metadata. Only this small state leaves the page. */
(() => {
  if (window.studyXuechengAvailability) return;
  const clean = value => String(value || '').replace(/\s+/g, '').replace(/[：:，,。.!！]/g, '');
  const pending = /^(?:抱歉|温馨提示|提示)?(?:本节|本课|该|此)?(?:课程|课节|直播回放|回放视频|回放|视频|直播)?(?:尚未更新|暂未更新|未更新|待更新|尚未发布|暂未发布|未发布|尚未上传|暂未上传|未上传|尚未生成|暂未生成|未生成|生成中|正在生成|正在生成中|转码中|正在转码|正在转码中|尚未开始|暂未开始|未开始|未开播|尚未开播|即将开始|即将开播|敬请期待)(?:请耐心等待|请稍后再试|请稍后观看|敬请期待)?$/;
  const absent = /^(?:暂时|暂)?(?:没有|暂无)(?:直播回放|回放视频|回放|视频)(?:请耐心等待|请稍后再试|敬请期待)?$/;
  const blocked = /请(?:先|重新)?登[录陆]|需要登[录陆]|(?:尚未|未|重新)登[录陆]|登[录陆](?:已)?(?:失效|过期|失败)|登[录陆]后(?:查看|观看)|^登[录陆]$|验证码|无权限|没有权限|无权|权限不足|未购买|购买后|课程已过期|课程不存在|课程已下架|视频不存在|视频已删除|回放已删除|网络异常|网络错误|网络连接失败|加载失败|请求失败|获取失败|播放失败/;
  function classify(labels, scheduled = false) {
    const values = labels.map(clean).filter(Boolean);
    if (values.some(value => blocked.test(value))) return 'blocked';
    if (values.some(value => pending.test(value) || absent.test(value))) return 'pending';
    if (scheduled && labels.some(value => {
      const match = String(value || '').trim().match(/^直播时间\s*[:：]?\s*(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?\s+(\d{1,2})[:：](\d{2})(?:\s*[-–—].*)?$/);
      if (!match) return false;
      const [, year, month, day, hour, minute] = match;
      const date = Date.parse(`${year}-${month.padStart(2, '0')}-${day.padStart(2, '0')}T${hour.padStart(2, '0')}:${minute}:00+08:00`);
      return Number.isFinite(date) && date > Date.now();
    })) return 'pending';
    return null;
  }
  const visible = element => element.getClientRects().length > 0 &&
    getComputedStyle(element).visibility !== 'hidden';
  function labels(scope) {
    return [...scope.querySelectorAll('*')].filter(element => !element.children.length && visible(element) &&
      !element.closest('script, style, nav, header, footer, [class*=chat], [id*=chat], [class*=comment], [id*=comment]'))
      .map(element => element.textContent.trim()).filter(Boolean);
  }
  window.studyXuechengAvailability = {classify, labels, visible};
})();
