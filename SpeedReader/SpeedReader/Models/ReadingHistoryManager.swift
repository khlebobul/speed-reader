import Foundation

struct ReadingSession: Codable, Identifiable {
    let id: UUID
    let totalWords: Int
    let readingTimeSeconds: TimeInterval
    let configuredWPM: Int
    let actualWPM: Int
    let timeSavedSeconds: TimeInterval
    let source: String
    let date: Date

    var formattedDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return "Today, \(formatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
            return "Yesterday, \(formatter.string(from: date))"
        } else {
            formatter.dateFormat = "d MMM, HH:mm"
            return formatter.string(from: date)
        }
    }

    var sourceIcon: String {
        switch source {
        case "Text": return "textbox"
        case "URL": return "link"
        case "File": return "doc.richtext"
        case "Area": return "viewfinder"
        default: return "book"
        }
    }

    var formattedTimeSaved: String {
        let absTime = abs(timeSavedSeconds)
        let totalSeconds = Int(absTime)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins > 0 {
            return "\(mins) min \(secs) sec"
        }
        return "\(secs) sec"
    }
}

final class ReadingHistoryManager: ObservableObject {
    static let shared = ReadingHistoryManager()

    private let key = "readingHistory"
    private let maxCount = 200

    /// Sessions shorter than this aren't real reading — usually the "jumped to
    /// the end with arrows, hit play, timer fired once" path. Filtering them
    /// out at write time keeps the history list and aggregates honest.
    private static let minValidDurationSeconds: TimeInterval = 5
    private static let minValidWords = 10

    @Published private(set) var sessions: [ReadingSession] = []

    init() {
        load()
    }

    func add(_ stats: ReadingSessionStats, source: String) {
        guard stats.readingTimeSeconds >= Self.minValidDurationSeconds,
              stats.totalWords >= Self.minValidWords else { return }
        let session = ReadingSession(
            id: UUID(),
            totalWords: stats.totalWords,
            readingTimeSeconds: stats.readingTimeSeconds,
            configuredWPM: stats.configuredWPM,
            actualWPM: stats.actualWPM,
            timeSavedSeconds: stats.timeSavedSeconds,
            source: source,
            date: stats.finishedAt
        )
        sessions.insert(session, at: 0)
        if sessions.count > maxCount {
            sessions = Array(sessions.prefix(maxCount))
        }
        save()
    }

    func clearAll() {
        sessions = []
        save()
    }

    // MARK: - Aggregates

    var totalWordsRead: Int {
        sessions.reduce(0) { $0 + $1.totalWords }
    }

    var totalTimeSavedSeconds: TimeInterval {
        sessions.reduce(0) { $0 + max(0, $1.timeSavedSeconds) }
    }

    var totalSessions: Int {
        sessions.count
    }

    var averageWPM: Int {
        // Weighted average of per-session `actualWPM`, weighted by reading time.
        // Each session's actualWPM is already clamped to configuredWPM in
        // `ReadingSessionStats.init`, so the aggregate inherits that bound.
        // The previous formula re-divided raw totalWords by raw time, which let
        // a single short/jumped session (e.g. 1000 words "read" in 0.2s) push
        // the average into the thousands.
        guard !sessions.isEmpty else { return 0 }
        let totalSeconds = sessions.reduce(0.0) { $0 + $1.readingTimeSeconds }
        guard totalSeconds > 0 else { return 0 }
        let weighted = sessions.reduce(0.0) { $0 + Double($1.actualWPM) * $1.readingTimeSeconds }
        return Int(weighted / totalSeconds)
    }

    var formattedTotalTimeSaved: String {
        let totalSeconds = Int(totalTimeSavedSeconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) h \(mins) min"
        }
        return "\(mins) min"
    }

    // MARK: - Private

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ReadingSession].self, from: data) else {
            return
        }
        sessions = decoded
    }
}
