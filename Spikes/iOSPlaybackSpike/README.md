# iOS playback spike

Throwaway iPhone app that answers one question before any real iOS work starts:
**can a hidden `WKWebView` playing music.youtube.com, configured like Kaset's
`SingletonPlayerWebView`, act as a reliable background music player on iOS?**

Nothing here is meant to ship. It shares no code with Kaset on purpose, so the
answer doesn't depend on any refactor.

## Build and run

Open `KasetPlaybackSpike.xcodeproj`, select your iPhone, and run. Signing uses
automatic provisioning with team `4PZ2UBJ583`; change `DEVELOPMENT_TEAM` for
another account. iOS 26+, iPhone only.

To start playback without typing an ID, add the launch argument
`-autoplay <videoID>` to the scheme.

Simulator build check:

```bash
xcodebuild -project KasetPlaybackSpike.xcodeproj -scheme KasetPlaybackSpike \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## What's in it

| File | Role |
|------|------|
| `WebPlaybackEngine.swift` | Singleton `WKWebView`: Kaset's desktop UA and config plus iOS inline playback, queue, web-process crash recovery, 10 s native heartbeat |
| `ObserverScript.swift` | Injected JS: media events, 1 s state report, visibility, Media Session metadata, `play`/`pause`/`seek`/`click` |
| `AudioSessionMonitor.swift` | `.playback` session; logs interruptions, route changes, media-server resets, lock/unlock, memory warnings |
| `NowPlayingController.swift` | App-owned `MPNowPlayingInfoCenter` and remote commands (toggleable) |
| `LoginView.swift` | Google sign-in sharing the default data store |
| `SpikeLog.swift` | Timestamped log tagged `fg`/`inactive`/`BG`, written to `Documents/spike-log.txt` |

The web view stays in the window hierarchy at 2 pt (outside the `List`, since
a lazy row can leave the window and WebKit would treat the page as hidden).
A guest session gets a pre-accepted `SOCS` consent cookie, the same one
`YTMusicClient` sends, to avoid the EU consent wall.

## Findings so far (simulator, iOS 27, guest)

- Desktop UA page loads and plays inline; autoplay without a user gesture works.
- Guest playback of an official video gets a 640×360 **video** stream.
- **WebKit pauses the `<video>` ~150 ms after the app enters the background**,
  despite the `audio` background mode and an active `.playback` session. JS keeps
  running, and WebKit auto-resumes on return to the foreground.
- **Mitigation:** calling `play()` from the background right after that pause is
  accepted, and playback continues in real time with the page `hidden`
  ("Resume after background pause" toggle, on by default).

The simulator doesn't suspend apps like a device does, so every row below needs
an iPhone.

## Findings on device (first run)

- Background and locked playback work, including auto-advance while locked.
- WebKit's own Now Playing and the app-owned one both work; the app-owned one
  transitions more smoothly between songs.
- **Lock-screen commands never reach the app's `MPRemoteCommandCenter` targets.**
  WebKit delivers them to the page's Media Session (YouTube Music registers
  play, pause, seek, next, and previous handlers). The app-owned controller only
  controls the *displayed* info.
- That made lock-screen pause impossible: WebKit paused the video, and the
  background-resume mitigation, which couldn't tell that pause from WebKit's
  backgrounding pause, resumed it 150 ms later. The observer script now wraps
  `navigator.mediaSession.setActionHandler`, reports every remote action to
  native (`🎛 web media session action: …`) before YouTube Music's handler runs,
  and native records the pause as intentional. Verified on device: lock-screen
  pause, play, and scrub all work while locked.
- **Signed in (Premium), the stream is audio-only** (`videoWidth` stays 0), and
  WebKit does **not** pause on backgrounding; the background-resume mitigation
  never fired in those runs except at track ends. The backgrounding pause seen
  in the simulator applies to video streams (guest playback).
- Starting playback logs `interruption BEGAN (reason=0)` with no matching
  `ENDED`: WebKit's media session takes over the app's audio session. It's
  harmless here, but a real app shouldn't treat that interruption as a pause.

## Device test protocol

Sign in first (Options → Sign in…), then repeat the key tests signed out.
Note the time you start each test; the log lines carry timestamps.

| # | Test | Pass if |
|---|------|---------|
| 1 | Play a song (ATV) and a music video (OMV); check **Stream** | Note whether Premium/songs get `Audio only` |
| 2 | Play, then go to the Home Screen for 5 min | Audio continues; `tick` lines keep coming with `[BG]` and advancing `t=` |
| 3 | Same as 2 with "Resume after background pause" **off** | Tells whether the mitigation is needed on device |
| 4 | Play, lock the phone for 15 min | Audio continues; no gaps between `tick` lines |
| 5 | Lock screen controls: play/pause, next, previous, scrub | `🎛 remote command` lines and the matching effect |
| 6 | Toggle "App-owned Now Playing" off, repeat 5 | Shows whether WebKit's own Media Session entry works by itself, and which wins when both are on |
| 7 | Queue 3 IDs, lock the phone, let it run | Auto-advance loads the next track in the background (`▶︎ load … next: track ended`) |
| 8 | Phone call or Siri while playing | `interruption BEGAN`/`ENDED`; playback resumes |
| 9 | Unplug wired headphones or disconnect AirPods | `route change reason=oldDeviceUnavailable`, playback pauses |
| 10 | AirPlay to a speaker/Apple TV, then lock | Audio keeps playing on the target |
| 11 | Open a few heavy apps (camera, games) while playing in the background | If `💥 WEB CONTENT PROCESS TERMINATED` appears, playback recovers at the same position |
| 12 | Leave it playing for 1 h, locked | No stop; check battery use in Settings |

## Getting the log off the device

`Documents/spike-log.txt` is visible in Finder (iPhone → Files → Kaset Spike),
shareable from the Log section header, or:

```bash
xcrun devicectl device copy from --device <device-id> \
  --domain-type appDataContainer --domain-identifier com.jernejfijacko.KasetPlaybackSpike \
  --source Documents/spike-log.txt --destination ./spike-log.txt
```

The log contains titles and timings only, no cookies or tokens.

## Inspecting the page

`webView.isInspectable` is on: Safari → Develop → *your iPhone* → Kaset Spike.
