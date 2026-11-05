import Foundation
import Observation
import UIKit

/// Timestamped event log shown in the UI and appended to `Documents/spike-log.txt`.
///
/// The file is visible in Finder (device → Files) and can be pulled with
/// `xcrun devicectl device copy from --domain-type appDataContainer`.
@MainActor
@Observable
final class SpikeLog {
    static let shared = SpikeLog()

    struct Entry: Identifiable {
        let id: Int
        let text: String
    }

    private(set) var entries: [Entry] = []
    private var nextID = 0

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let handle: FileHandle?
    @ObservationIgnored private let formatter: DateFormatter

    private init() {
        let documents = URL.documentsDirectory
        self.fileURL = documents.appendingPathComponent("spike-log.txt")
        if !FileManager.default.fileExists(atPath: self.fileURL.path) {
            FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
        }
        self.handle = try? FileHandle(forWritingTo: self.fileURL)
        _ = try? self.handle?.seekToEnd()
        self.formatter = DateFormatter()
        self.formatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ message: String) {
        let line = "\(self.formatter.string(from: Date())) [\(AppState.current)] \(message)"
        self.entries.append(Entry(id: self.nextID, text: line))
        self.nextID += 1
        if self.entries.count > 500 {
            self.entries.removeFirst(self.entries.count - 500)
        }
        if let data = (line + "\n").data(using: .utf8) {
            self.handle?.write(data)
            try? self.handle?.synchronize()
        }
    }

    func clear() {
        self.entries.removeAll()
        try? self.handle?.truncate(atOffset: 0)
    }
}

@MainActor
enum AppState {
    static var current: String {
        switch UIApplication.shared.applicationState {
        case .active: "fg"
        case .inactive: "inactive"
        case .background: "BG"
        @unknown default: "?"
        }
    }
}

@MainActor
func log(_ message: String) {
    SpikeLog.shared.log(message)
}
