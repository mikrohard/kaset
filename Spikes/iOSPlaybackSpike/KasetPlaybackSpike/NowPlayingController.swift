import MediaPlayer
import Observation
import UIKit

/// App-owned lock-screen / Control Center integration.
///
/// The toggle exists because WebKit publishes its own Now Playing entry from the
/// page's Media Session. The spike needs to show which one wins on the lock
/// screen, and whether remote commands reach the app at all when it owns them.
@MainActor
@Observable
final class NowPlayingController {
    static let shared = NowPlayingController()

    var isEnabled = true {
        didSet {
            guard oldValue != self.isEnabled else { return }
            log("app-owned Now Playing \(self.isEnabled ? "ENABLED" : "DISABLED")")
            if self.isEnabled {
                self.registerCommands()
                self.publish(WebPlaybackEngine.shared.state)
            } else {
                self.unregisterCommands()
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        }
    }

    private(set) var commandCount = 0

    @ObservationIgnored private var lastPublished: WebPlaybackEngine.State?
    @ObservationIgnored private var artworkURL: String?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var registered = false

    private init() {}

    func start() {
        if self.isEnabled {
            self.registerCommands()
        }
    }

    func update(from state: WebPlaybackEngine.State) {
        guard self.isEnabled else { return }
        if let artworkURL = state.artworkURL, artworkURL != self.artworkURL {
            self.artworkURL = artworkURL
            self.artwork = nil
            Task { await self.loadArtwork(from: artworkURL) }
        }
        // Republish only on meaningful changes; the system extrapolates elapsed time.
        if let last = self.lastPublished,
           last.title == state.title,
           last.isPaused == state.isPaused,
           last.duration == state.duration,
           abs(last.currentTime - state.currentTime) < 2.5
        {
            return
        }
        self.publish(state)
    }

    private func publish(_ state: WebPlaybackEngine.State) {
        self.lastPublished = state
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title.isEmpty ? "Kaset Spike" : state.title,
            MPMediaItemPropertyArtist: state.artist,
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPaused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork = self.artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state.isPaused ? .paused : .playing
    }

    private func loadArtwork(from urlString: String) async {
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              urlString == self.artworkURL
        else { return }
        self.artwork = Self.makeArtwork(image)
        self.lastPublished = nil
        self.publish(WebPlaybackEngine.shared.state)
    }

    /// Nonisolated so the request handler doesn't inherit main-actor isolation:
    /// MediaPlayer calls it off the main thread.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Remote commands

    private func registerCommands() {
        guard !self.registered else { return }
        self.registered = true
        let center = MPRemoteCommandCenter.shared()
        let engine = WebPlaybackEngine.shared

        self.add(center.playCommand, "play") { _ in engine.play(reason: "remote play") }
        self.add(center.pauseCommand, "pause") { _ in engine.pause(reason: "remote pause") }
        self.add(center.togglePlayPauseCommand, "toggle") { _ in engine.togglePlayPause(reason: "remote toggle") }
        self.add(center.nextTrackCommand, "next") { _ in engine.next(reason: "remote next") }
        self.add(center.previousTrackCommand, "previous") { _ in engine.previous(reason: "remote previous") }
        self.add(center.changePlaybackPositionCommand, "scrub") { event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                engine.seek(to: event.positionTime, reason: "remote scrub")
            }
        }
    }

    private func unregisterCommands() {
        guard self.registered else { return }
        self.registered = false
        let center = MPRemoteCommandCenter.shared()
        for command in [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand,
        ] {
            command.removeTarget(nil)
        }
    }

    private func add(
        _ command: MPRemoteCommand,
        _ name: String,
        action: @escaping @MainActor (MPRemoteCommandEvent) -> Void
    ) {
        command.isEnabled = true
        command.addTarget { event in
            MainActor.assumeIsolated {
                self.commandCount += 1
                log("🎛 remote command: \(name)")
                action(event)
            }
            return .success
        }
    }
}
