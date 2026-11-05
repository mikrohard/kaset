import AVFoundation
import UIKit

/// Owns the app's `AVAudioSession` and logs every system event that can stop
/// background playback: interruptions, route changes, media-server resets,
/// memory warnings, and device lock/unlock.
@MainActor
final class AudioSessionMonitor {
    static let shared = AudioSessionMonitor()

    private var tokens: [NSObjectProtocol] = []

    private init() {}

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            log("audio session: category=\(session.category.rawValue) active")
        } catch {
            log("audio session setup failed: \(error.localizedDescription)")
        }

        self.observe(AVAudioSession.interruptionNotification) { info in
            let rawType = info?[AVAudioSessionInterruptionTypeKey]
            let type = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            switch type {
            case .began:
                let reason = info?[AVAudioSessionInterruptionReasonKey] ?? 0
                log("⚠️ interruption BEGAN (reason=\(reason))")
            case .ended:
                let rawOptions = info?[AVAudioSessionInterruptionOptionKey] ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                log("interruption ENDED shouldResume=\(shouldResume)")
                if shouldResume {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    WebPlaybackEngine.shared.play(reason: "interruption ended")
                }
            default:
                log("interruption (unknown type)")
            }
        }

        self.observe(AVAudioSession.routeChangeNotification) { info in
            let rawReason = info?[AVAudioSessionRouteChangeReasonKey] ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { "\($0.portType.rawValue)" }
                .joined(separator: ",")
            log("route change reason=\(Self.describe(reason)) outputs=[\(outputs)]")
            if reason == .oldDeviceUnavailable {
                // Apple's guideline: pause when headphones are unplugged.
                WebPlaybackEngine.shared.pause(reason: "old route unavailable")
            }
        }

        self.observe(AVAudioSession.mediaServicesWereResetNotification) { _ in
            log("⚠️ media services were RESET")
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
        }

        self.observe(AVAudioSession.silenceSecondaryAudioHintNotification) { info in
            let raw = info?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] ?? 0
            log("silence secondary audio hint=\(raw)")
        }

        self.observe(UIApplication.didReceiveMemoryWarningNotification) { _ in
            log("⚠️ memory warning")
        }
        self.observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { _ in
            log("🔒 device locking")
        }
        self.observe(UIApplication.protectedDataDidBecomeAvailableNotification) { _ in
            log("🔓 device unlocked")
        }
        self.observe(UIApplication.didEnterBackgroundNotification) { _ in
            log("app did enter background (session category=\(AVAudioSession.sharedInstance().category.rawValue))")
        }
        self.observe(UIApplication.willEnterForegroundNotification) { _ in
            log("app will enter foreground")
        }
    }

    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor @Sendable ([String: UInt]?) -> Void
    ) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            // userInfo isn't Sendable; every key the handlers read is a String with a UInt value.
            let info = note.userInfo.map { userInfo in
                userInfo.reduce(into: [String: UInt]()) { result, pair in
                    if let key = pair.key as? String, let value = pair.value as? UInt {
                        result[key] = value
                    }
                }
            }
            MainActor.assumeIsolated { handler(info) }
        }
        self.tokens.append(token)
    }

    private static func describe(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRoute"
        case .routeConfigurationChange: "routeConfigurationChange"
        case .unknown, .none: "unknown"
        @unknown default: "other"
        }
    }
}
