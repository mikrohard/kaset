import SwiftUI
import UIKit

@main
struct KasetPlaybackSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: self.scenePhase) { oldPhase, newPhase in
            log("scenePhase \(oldPhase) → \(newPhase)")
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        log("──── launch ────")
        AudioSessionMonitor.shared.start()
        NowPlayingController.shared.start()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        // `-autoplay <videoID>` launch argument (Xcode scheme or `simctl launch`) skips typing an ID.
        if let videoID = UserDefaults.standard.string(forKey: "autoplay"), !videoID.isEmpty {
            WebPlaybackEngine.shared.load(videoID: videoID, reason: "launch argument")
        }
        return true
    }
}
