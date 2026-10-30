import Foundation

/// Explicit media states take precedence over unreadable frames/tabs. A failed
/// read alone never proves that a player is paused.
struct BrowserPlaybackScan {
    private(set) var isPlaying = false
    private var mediaStopped = false
    private var incomplete = false
    private var failure: PlaybackObservation?

    mutating func record(_ state: String?) {
        switch state {
        case "playing": isPlaying = true
        case "stopped": mediaStopped = true
        case "empty": break
        default: recordFailure()
        }
    }

    mutating func recordFailure(_ detail: PlaybackObservation? = nil) {
        incomplete = true
        if failure == nil { failure = detail }
    }

    var observation: PlaybackObservation {
        if isPlaying { return .playing("浏览器中有音视频正在播放") }
        if mediaStopped { return .stopped("浏览器中已读取到的音视频已暂停") }
        if let failure { return failure }
        if incomplete {
            return .unavailable("部分标签页无法读取，可能包含跨域播放器或受限页面；暂时无法判断播放状态。")
        }
        return .stopped("浏览器没有正在播放的音视频")
    }

    // Returns only a state. No URLs, page titles, course names, or media content
    // leave the browser. An unrelated cross-origin frame must not hide a pause.
    static let mediaScript = #"""
    (() => {
      let found = false, playing = false, inaccessible = false;
      const visit = (doc) => {
        for (const media of doc.querySelectorAll('video,audio')) {
          found = true;
          if (!media.paused && !media.ended && !media.seeking && media.readyState >= 2 && media.playbackRate > 0) playing = true;
        }
        for (const frame of doc.querySelectorAll('iframe,frame')) {
          try { if (frame.contentDocument) visit(frame.contentDocument); else inaccessible = true; }
          catch (_) { inaccessible = true; }
        }
      };
      visit(document);
      return playing ? 'playing' : (found ? 'stopped' : (inaccessible ? 'unknown' : 'empty'));
    })()
    """#
}
