import SwiftUI
import WebKit

struct ContentView: View {
    @State private var engine = WebPlaybackEngine.shared
    @State private var nowPlaying = NowPlayingController.shared
    @State private var spikeLog = SpikeLog.shared
    @State private var videoIDText = ""
    @State private var queueText = ""
    @State private var showsWebView = false
    @State private var showsLogin = false

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Account", value: self.accountLabel)
                    LabeledContent("Playback", value: self.engine.state.isPaused ? "Paused" : "Playing")
                    LabeledContent("Track", value: self.trackLabel)
                    LabeledContent("Position", value: self.positionLabel)
                    LabeledContent("Stream", value: self.streamLabel)
                    LabeledContent("Page visibility", value: self.engine.state.visibility)
                    LabeledContent("Remote commands", value: "\(self.nowPlaying.commandCount)")
                    LabeledContent("Web process crashes", value: "\(self.engine.webProcessTerminations)")
                }

                Section("Load") {
                    TextField("Video ID", text: self.$videoIDText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                    Button("Load and play") {
                        let id = self.videoIDText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !id.isEmpty else { return }
                        self.engine.load(videoID: id, reason: "manual")
                    }
                    TextField("Queue: IDs separated by spaces or commas", text: self.$queueText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                    Button("Play queue (\(self.parsedQueue.count))") {
                        self.engine.queue = self.parsedQueue
                        self.engine.playQueue(from: 0)
                    }
                    .disabled(self.parsedQueue.isEmpty)
                }

                Section("Controls") {
                    HStack(spacing: 28) {
                        Button("Previous", systemImage: "backward.fill") {
                            self.engine.previous(reason: "ui")
                        }
                        Button(
                            self.engine.state.isPaused ? "Play" : "Pause",
                            systemImage: self.engine.state.isPaused ? "play.fill" : "pause.fill"
                        ) {
                            self.engine.togglePlayPause(reason: "ui")
                        }
                        Button("Next", systemImage: "forward.fill") {
                            self.engine.next(reason: "ui")
                        }
                        Button("−15 s", systemImage: "gobackward.15") {
                            self.engine.seek(to: self.engine.state.currentTime - 15, reason: "ui")
                        }
                        Button("+30 s", systemImage: "goforward.30") {
                            self.engine.seek(to: self.engine.state.currentTime + 30, reason: "ui")
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title2)
                    .frame(maxWidth: .infinity)

                    Button("Reload at current position") {
                        self.engine.reloadCurrent(reason: "manual reload")
                    }
                }

                Section("Options") {
                    Toggle("App-owned Now Playing", isOn: self.$nowPlaying.isEnabled)
                    Toggle("Auto-advance queue", isOn: self.$engine.autoAdvance)
                    Toggle("Resume after background pause", isOn: self.$engine.resumeAfterBackgroundPause)
                    Toggle("Lock-screen previous/next (block skip)", isOn: self.$engine.trackButtons)
                    Toggle("Show web view", isOn: self.$showsWebView)
                    Button("Sign in…") { self.showsLogin = true }
                }

                Section {
                    ForEach(self.spikeLog.entries.reversed()) { entry in
                        Text(entry.text)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    HStack {
                        Text("Log")
                        Spacer()
                        ShareLink(item: self.spikeLog.fileURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button("Clear", role: .destructive) { self.spikeLog.clear() }
                    }
                    .font(.caption)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Outside the List on purpose: a lazy List row can leave the window,
                // which makes WebKit treat the page as hidden and throttle it.
                PlayerWebViewHost(webView: self.engine.webView)
                    .frame(height: self.showsWebView ? 260 : 2)
                    .opacity(self.showsWebView ? 1 : 0.01)
                    .allowsHitTesting(self.showsWebView)
            }
            .navigationTitle("Kaset Spike")
            .sheet(isPresented: self.$showsLogin) { LoginView() }
            .task { await self.engine.refreshSignInState() }
        }
    }

    private var parsedQueue: [String] {
        self.queueText
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
    }

    private var accountLabel: String {
        switch self.engine.isSignedIn {
        case .some(true): "Signed in"
        case .some(false): "Guest"
        case .none: "Unknown"
        }
    }

    private var trackLabel: String {
        let state = self.engine.state
        guard !state.title.isEmpty else { return "—" }
        return state.artist.isEmpty ? state.title : "\(state.title) — \(state.artist)"
    }

    private var positionLabel: String {
        "\(Self.format(self.engine.state.currentTime)) / \(Self.format(self.engine.state.duration))"
    }

    private var streamLabel: String {
        let state = self.engine.state
        if state.readyState == 0 { return "—" }
        return state.videoWidth == 0 ? "Audio only" : "Video \(state.videoWidth)×\(state.videoHeight)"
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Keeps the singleton web view in the window hierarchy. WebKit throttles or
/// suspends pages whose view isn't in a window, so "hidden" means 2 pt tall and
/// nearly transparent, never removed.
private struct PlayerWebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context _: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        self.webView.removeFromSuperview()
        self.webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self.webView)
        NSLayoutConstraint.activate([
            self.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            self.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            self.webView.topAnchor.constraint(equalTo: container.topAnchor),
            self.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_: UIView, context _: Context) {}
}
