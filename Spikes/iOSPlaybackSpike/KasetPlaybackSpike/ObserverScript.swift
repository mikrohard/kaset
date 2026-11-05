/// Minimal stand-in for Kaset's `SingletonPlayerWebView` observer scripts.
///
/// It only reports what the spike needs to measure: media element events,
/// a 1 s state heartbeat (whose gaps reveal JS throttling or suspension),
/// `document.visibilityState`, video dimensions (0×0 means an audio-only
/// stream), and the page's own Media Session metadata.
enum ObserverScript {
    /// Runs before `source` on every page load, so the Media Session wrapper
    /// knows the mode before YouTube Music registers any handler.
    static func bootstrap(trackButtons: Bool) -> String {
        "window.__spikeTrackButtons = \(trackButtons ? "true" : "false");"
    }

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
      //
      // Track-buttons mode (window.__spikeTrackButtons, set by a document-start
      // bootstrap script from native) ports Kaset's macOS media-control override
      // (SingletonPlayerWebView+PlaybackPreferences.swift): YouTube Music's
      // seekforward/seekbackward handlers are blocked, since while they're
      // registered the lock screen shows skip buttons instead of previous/next,
      // and nexttrack/previoustrack are routed to native.
      const ms = navigator.mediaSession;
      if (ms && ms.setActionHandler) {
        const original = ms.setActionHandler.bind(ms);
        const pageHandlers = {};
        const actions = ['play', 'pause', 'stop', 'nexttrack', 'previoustrack', 'seekto'];
        const seekSkipActions = ['seekforward', 'seekbackward'];
        const nativeOwned = (action) =>
          window.__spikeTrackButtons === true && (action === 'nexttrack' || action === 'previoustrack');
        const install = (action) => {
          try {
            original(action, (details) => {
              post({ type: 'remoteAction', action, seekTime: details && details.seekTime });
              if (nativeOwned(action)) return;  // native picks the track
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
        const applySeekSkip = () => {
          seekSkipActions.forEach((action) => {
            const handler = window.__spikeTrackButtons === true ? null : (pageHandlers[action] || null);
            try { original(action, handler); } catch (e) {}
          });
        };
        ms.setActionHandler = (action, handler) => {
          const blocked = seekSkipActions.includes(action) && window.__spikeTrackButtons === true;
          post({
            type: 'log',
            message: 'page ' + (handler ? 'set' : 'cleared') + ' media session handler: ' + action +
              (blocked ? ' (blocked: track-buttons mode)' : '')
          });
          if (actions.includes(action)) {
            pageHandlers[action] = handler;
            install(action);
          } else if (seekSkipActions.includes(action)) {
            pageHandlers[action] = handler;
            applySeekSkip();
          } else {
            original(action, handler);
          }
        };
        actions.forEach(install);
        applySeekSkip();
        // Native calls this when the toggle changes on an already-loaded page.
        window.__spikeSetTrackButtons = (enabled) => {
          window.__spikeTrackButtons = enabled;
          applySeekSkip();
          post({ type: 'log', message: 'track-buttons mode ' + (enabled ? 'ON' : 'OFF') });
        };
      }

      new MutationObserver(findVideo).observe(document.documentElement, { childList: true, subtree: true });
      setInterval(() => { findVideo(); report(); }, 1000);
    })();
    """#
}
