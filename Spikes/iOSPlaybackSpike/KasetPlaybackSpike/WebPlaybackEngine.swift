import Observation
import UIKit
import WebKit

/// Hidden `WKWebView` that plays `music.youtube.com/watch?v=…`, configured like
/// Kaset's `SingletonPlayerWebView` (`WebKitManager.createWebViewConfiguration`
/// plus the desktop Safari user agent) with the iOS-only inline-playback flags.
@MainActor
@Observable
final class WebPlaybackEngine: NSObject {
    static let shared = WebPlaybackEngine()

    /// Same value as `WebKitManager.userAgent`. A mobile UA would get the
    /// mobile site, whose DOM Kaset's injected scripts don't target.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    struct State: Equatable {
        var isPaused = true
        var currentTime: Double = 0
        var duration: Double = 0
        var readyState = 0
        var videoWidth = 0
        var videoHeight = 0
        var visibility = "?"
        var title = ""
        var artist = ""
        var artworkURL: String?
    }

    private(set) var state = State()
    private(set) var currentVideoID: String?
    private(set) var lastReportAt: Date?
    private(set) var isSignedIn: Bool?
    private(set) var webProcessTerminations = 0

    /// Video IDs the user queued; next/previous walk this list when it isn't empty,
    /// otherwise they press YouTube Music's own player-bar buttons.
    var queue: [String] = []
    private(set) var queueIndex = 0
    var autoAdvance = true
    /// Mitigation under test: WebKit pauses <video> when the app backgrounds even with
    /// the audio background mode; call play() again right after that pause.
    var resumeAfterBackgroundPause = true
    /// The open question: block YouTube Music's seekforward/seekbackward Media
    /// Session handlers (as Kaset does on macOS) so the lock screen shows
    /// previous/next instead of skip buttons, with next/previous handled natively.
    var trackButtons = true {
        didSet {
            guard oldValue != self.trackButtons else { return }
            log("lock-screen track buttons \(self.trackButtons ? "ON" : "OFF")")
            self.installUserScripts()
            self.evaluate("window.__spikeSetTrackButtons && window.__spikeSetTrackButtons(\(self.trackButtons))")
        }
    }

    let webView: WKWebView

    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var consentCookieTask: Task<Void, Never>?

    override private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true
        // iOS-only: without these the iPhone hands <video> to the fullscreen player.
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true

        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        self.webView.customUserAgent = Self.userAgent
        self.webView.isInspectable = true
        super.init()

        self.installUserScripts()
        self.webView.configuration.userContentController.add(self, name: "spike")
        self.webView.navigationDelegate = self
        self.consentCookieTask = Task { await Self.installConsentCookie() }
        self.startHeartbeat()
    }

    /// Pre-accepted EU consent preference, the same value `YTMusicClient` sends.
    /// Without it, guest loads in the EU land on consent.youtube.com instead of the player.
    private static func installConsentCookie() async {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".youtube.com",
            .path: "/",
            .name: "SOCS",
            .value: "CAI",
            .secure: true,
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 365),
        ]
        guard let cookie = HTTPCookie(properties: properties) else { return }
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
    }

    // MARK: - Commands

    func load(videoID: String, startAt: Double? = nil, reason: String) {
        guard var components = URLComponents(string: "https://music.youtube.com/watch") else { return }
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        guard let url = components.url else { return }
        self.currentVideoID = videoID
        self.wantsPlayback = true
        self.pendingSeek = startAt
        log("▶︎ load \(videoID) (\(reason))\(startAt.map { String(format: " seek→%.0fs", $0) } ?? "")")
        Task {
            await self.consentCookieTask?.value
            self.webView.load(URLRequest(url: url))
        }
    }

    func play(reason: String) {
        self.wantsPlayback = true
        log("cmd play (\(reason))")
        self.evaluate("window.__spike && window.__spike.play()")
    }

    func pause(reason: String) {
        self.wantsPlayback = false
        log("cmd pause (\(reason))")
        self.evaluate("window.__spike && window.__spike.pause()")
    }

    func togglePlayPause(reason: String) {
        if self.state.isPaused {
            self.play(reason: reason)
        } else {
            self.pause(reason: reason)
        }
    }

    func seek(to seconds: Double, reason: String) {
        let target = max(0, seconds)
        log(String(format: "cmd seek %.1fs (%@)", target, reason))
        self.evaluate("window.__spike && window.__spike.seek(\(target))")
    }

    func next(reason: String) {
        if !self.queue.isEmpty {
            self.queueIndex = (self.queueIndex + 1) % self.queue.count
            self.load(videoID: self.queue[self.queueIndex], reason: "next: \(reason)")
        } else {
            log("cmd next → YTM player bar (\(reason))")
            self.evaluate("window.__spike && window.__spike.click('ytmusic-player-bar .next-button')")
        }
    }

    func previous(reason: String) {
        if !self.queue.isEmpty {
            self.queueIndex = (self.queueIndex - 1 + self.queue.count) % self.queue.count
            self.load(videoID: self.queue[self.queueIndex], reason: "previous: \(reason)")
        } else {
            log("cmd previous → YTM player bar (\(reason))")
            self.evaluate("window.__spike && window.__spike.click('ytmusic-player-bar .previous-button')")
        }
    }

    func playQueue(from index: Int) {
        guard self.queue.indices.contains(index) else { return }
        self.queueIndex = index
        self.load(videoID: self.queue[index], reason: "queue item \(index)")
    }

    func reloadCurrent(reason: String) {
        guard let videoID = self.currentVideoID else { return }
        self.load(videoID: videoID, startAt: self.state.currentTime, reason: reason)
    }

    func refreshSignInState() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        // Presence only; cookie values are never logged.
        let signedIn = cookies.contains {
            ($0.name == "__Secure-3PAPISID" || $0.name == "SAPISID") && $0.domain.hasSuffix("youtube.com")
        }
        if signedIn != self.isSignedIn {
            log("sign-in state: \(signedIn ? "signed in (auth cookie present)" : "guest")")
        }
        self.isSignedIn = signedIn
    }

    private func evaluate(_ javaScript: String) {
        self.webView.evaluateJavaScript(javaScript) { _, error in
            if let error {
                MainActor.assumeIsolated {
                    log("JS error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The bootstrap script carries the current mode, so it's reinstalled on change.
    private func installUserScripts() {
        let controller = self.webView.configuration.userContentController
        controller.removeAllUserScripts()
        for source in [ObserverScript.bootstrap(trackButtons: self.trackButtons), ObserverScript.source] {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    // MARK: - Heartbeat

    /// Native 10 s tick. Gaps mean the app process was suspended; a growing
    /// "last JS report" age while the app runs means WebKit throttled the page.
    private func startHeartbeat() {
        self.heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                let age = self.lastReportAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "never"
                log(String(
                    format: "tick paused=%@ t=%.0f/%.0f vis=%@ lastJSReport=%@",
                    self.state.isPaused ? "yes" : "no",
                    self.state.currentTime,
                    self.state.duration,
                    self.state.visibility,
                    age
                ))
            }
        }
    }

    // MARK: - Bridge

    private func apply(state newState: State) {
        let old = self.state
        self.state = newState
        self.lastReportAt = Date()

        if old.isPaused != newState.isPaused {
            let unexpected = newState.isPaused && self.wantsPlayback
            log("state paused=\(newState.isPaused)\(unexpected ? " ⚠️ NOT requested by app" : "") vis=\(newState.visibility)")
        }
        if old.title != newState.title, !newState.title.isEmpty {
            log("now playing: \(newState.title) — \(newState.artist)")
        }
        if (old.videoWidth, old.videoHeight) != (newState.videoWidth, newState.videoHeight) {
            let kind = newState.videoWidth == 0 ? "audio-only stream" : "video stream"
            log("media size \(newState.videoWidth)×\(newState.videoHeight) (\(kind))")
        }
        NowPlayingController.shared.update(from: newState)
    }

    /// A lock-screen / Control Center command that WebKit delivered to the page.
    /// Record the user's intent before the resulting `pause` event arrives, so
    /// the background-resume mitigation doesn't undo a deliberate pause.
    private func handleRemoteAction(_ action: String) {
        log("🎛 web media session action: \(action)")
        switch action {
        case "pause", "stop":
            self.wantsPlayback = false
        case "play":
            self.wantsPlayback = true
        case "nexttrack", "previoustrack":
            self.wantsPlayback = true
            // In track-buttons mode the page doesn't act on these; native owns them, as in Kaset.
            if self.trackButtons {
                if action == "nexttrack" {
                    self.next(reason: "lock-screen next")
                } else {
                    self.previous(reason: "lock-screen previous")
                }
            }
        default:
            break
        }
    }

    private func handleEvent(name: String, time: Double, paused: Bool, visibility: String, errorCode: Int?) {
        var line = String(format: "media event %@ t=%.1f paused=%@ vis=%@", name, time, paused ? "yes" : "no", visibility)
        if let errorCode {
            line += " error=\(errorCode)"
        }
        log(line)

        switch name {
        case "loadedmetadata", "canplay":
            if let pendingSeek {
                self.pendingSeek = nil
                self.seek(to: pendingSeek, reason: "restore position")
            }
            if self.wantsPlayback, paused {
                self.play(reason: "autoplay after \(name)")
            }
        case "pause":
            if self.resumeAfterBackgroundPause, self.wantsPlayback,
               UIApplication.shared.applicationState != .active
            {
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard self.wantsPlayback, self.state.isPaused else { return }
                    self.play(reason: "resume after WebKit background pause")
                }
            }
        case "ended":
            if self.autoAdvance, !self.queue.isEmpty {
                self.next(reason: "track ended")
            }
        default:
            break
        }
    }
}

// MARK: - WKScriptMessageHandler

extension WebPlaybackEngine: WKScriptMessageHandler {
    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }

        switch type {
        case "state":
            self.apply(state: State(
                isPaused: body["paused"] as? Bool ?? true,
                currentTime: body["currentTime"] as? Double ?? 0,
                duration: body["duration"] as? Double ?? 0,
                readyState: body["readyState"] as? Int ?? 0,
                videoWidth: body["videoWidth"] as? Int ?? 0,
                videoHeight: body["videoHeight"] as? Int ?? 0,
                visibility: body["visibility"] as? String ?? "?",
                title: body["title"] as? String ?? "",
                artist: body["artist"] as? String ?? "",
                artworkURL: body["artwork"] as? String
            ))
        case "event":
            self.handleEvent(
                name: body["name"] as? String ?? "?",
                time: body["t"] as? Double ?? 0,
                paused: body["paused"] as? Bool ?? true,
                visibility: body["visibility"] as? String ?? "?",
                errorCode: body["error"] as? Int
            )
        case "remoteAction":
            self.handleRemoteAction(body["action"] as? String ?? "?")
        case "log":
            log("js: \(body["message"] as? String ?? "")")
        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebPlaybackEngine: WKNavigationDelegate {
    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        log("page loaded: \(self.webView.url?.host() ?? "?")\(self.webView.url?.path() ?? "")")
        Task { await self.refreshSignInState() }
    }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError error: any Error) {
        log("⚠️ navigation failed: \(error.localizedDescription)")
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: any Error) {
        log("⚠️ provisional navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        self.webProcessTerminations += 1
        let resumeAt = self.state.currentTime
        log("💥 WEB CONTENT PROCESS TERMINATED (#\(self.webProcessTerminations)) at t=\(Int(resumeAt))s")
        if self.wantsPlayback, let videoID = self.currentVideoID {
            self.load(videoID: videoID, startAt: resumeAt, reason: "recover after web process termination")
        }
    }
}
