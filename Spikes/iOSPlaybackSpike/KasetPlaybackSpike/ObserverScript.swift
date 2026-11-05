/// Minimal stand-in for Kaset's `SingletonPlayerWebView` observer scripts.
///
/// It only reports what the spike needs to measure: media element events,
/// a 1 s state heartbeat (whose gaps reveal JS throttling or suspension),
/// `document.visibilityState`, video dimensions (0×0 means an audio-only
/// stream), and the page's own Media Session metadata.
enum ObserverScript {
    static let source = #"""
    (() => {
      if (window.__spike) return;
      const post = (msg) => {
        try { window.webkit.messageHandlers.spike.postMessage(msg); } catch (e) {}
      };
      let video = null;
      const events = ['play', 'playing', 'pause', 'waiting', 'stalled', 'ended',
                      'error', 'emptied', 'loadedmetadata', 'canplay', 'seeked', 'suspend'];

      function meta() {
        const m = navigator.mediaSession && navigator.mediaSession.metadata;
        if (!m) return {};
        const artwork = (m.artwork || []).slice(-1)[0];
        return { title: m.title || '', artist: m.artist || '', artwork: artwork ? artwork.src : null };
      }

      function report() {
        const v = video;
        const m = meta();
        post({
          type: 'state',
          paused: v ? v.paused : true,
          currentTime: v ? (v.currentTime || 0) : 0,
          duration: v && isFinite(v.duration) ? v.duration : 0,
          readyState: v ? v.readyState : 0,
          videoWidth: v ? v.videoWidth : 0,
          videoHeight: v ? v.videoHeight : 0,
          visibility: document.visibilityState,
          title: m.title || '',
          artist: m.artist || '',
          artwork: m.artwork || null,
          url: location.pathname + location.search
        });
      }

      function onEvent(e) {
        const v = e.target;
        post({
          type: 'event',
          name: e.type,
          t: v.currentTime || 0,
          paused: v.paused,
          visibility: document.visibilityState,
          error: v.error ? v.error.code : null
        });
        report();
      }

      function attach(v) {
        if (v === video) return;
        video = v;
        events.forEach((name) => v.addEventListener(name, onEvent));
        post({ type: 'log', message: 'video element attached' });
        report();
      }

      function findVideo() {
        if (video && video.isConnected) return;
        const v = document.querySelector('video');
        if (v) attach(v);
      }

      window.__spike = {
        play() {
          findVideo();
          if (!video) { post({ type: 'log', message: 'play(): no video element' }); return; }
          const p = video.play();
          if (p && p.catch) p.catch((e) => post({ type: 'log', message: 'play() rejected: ' + e.name + ' ' + e.message }));
        },
        pause() { if (video) video.pause(); },
        seek(t) { if (video) video.currentTime = t; },
        click(selector) {
          const b = document.querySelector(selector);
          if (b) { b.click(); return true; }
          return false;
        },
        report
      };

      document.addEventListener('visibilitychange', () => {
        post({
          type: 'event',
          name: 'visibilitychange',
          t: video ? video.currentTime : 0,
          paused: video ? video.paused : true,
          visibility: document.visibilityState,
          error: null
        });
      });

      // On iOS, WebKit routes lock-screen / Control Center commands to the page's
      // Media Session, not to the app's MPRemoteCommandCenter targets. Wrap
      // setActionHandler so every remote action is reported to native first, then
      // handed to YouTube Music's own handler (or a default when it has none).
      const ms = navigator.mediaSession;
      if (ms && ms.setActionHandler) {
        const original = ms.setActionHandler.bind(ms);
        const pageHandlers = {};
        const actions = ['play', 'pause', 'stop', 'nexttrack', 'previoustrack', 'seekto'];
        const install = (action) => {
          try {
            original(action, (details) => {
              post({ type: 'remoteAction', action, seekTime: details && details.seekTime });
              const handler = pageHandlers[action];
              if (handler) { handler(details); return; }
              findVideo();
              if (!video) return;
              if (action === 'play') video.play();
              else if (action === 'pause' || action === 'stop') video.pause();
              else if (action === 'seekto' && details && details.seekTime != null) video.currentTime = details.seekTime;
            });
          } catch (e) {}
        };
        ms.setActionHandler = (action, handler) => {
          post({ type: 'log', message: 'page ' + (handler ? 'set' : 'cleared') + ' media session handler: ' + action });
          if (actions.includes(action)) {
            pageHandlers[action] = handler;
            install(action);
          } else {
            original(action, handler);
          }
        };
        actions.forEach(install);
      }

      new MutationObserver(findVideo).observe(document.documentElement, { childList: true, subtree: true });
      setInterval(() => { findVideo(); report(); }, 1000);
    })();
    """#
}
