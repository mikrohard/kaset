import SwiftUI
import WebKit

/// Google sign-in in a visible web view that shares the default data store
/// with the playback engine, mirroring Kaset's `LoginSheet`.
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWebView()
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Task {
                                await WebPlaybackEngine.shared.refreshSignInState()
                                self.dismiss()
                            }
                        }
                    }
                }
        }
    }
}

private struct LoginWebView: UIViewRepresentable {
    /// Same URL as Kaset's `WebKitManager` login flow: sign in to YouTube, land on YouTube Music.
    static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F")

    func makeUIView(context _: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Mobile UA here on purpose: Google's sign-in page is touch-friendly on it,
        // and the cookies it sets are the same.
        if let url = Self.loginURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}
}
