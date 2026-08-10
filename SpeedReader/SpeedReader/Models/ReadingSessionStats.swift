import Foundation

struct ReadingSessionStats {
    let totalWords: Int
    let readingTimeSeconds: TimeInterval
    let configuredWPM: Int
    let actualWPM: Int
    let timeSavedSeconds: TimeInterval
    let traditionalTimeSeconds: TimeInterval
    let startedAt: Date
    let finishedAt: Date

    /// Average traditional reading speed (WPM)
    static let traditionalWPM = 250

    init(totalWords: Int, readingTimeSeconds: TimeInterval, configuredWPM: Int, startedAt: Date, finishedAt: Date) {
        self.totalWords = totalWords
        self.readingTimeSeconds = readingTimeSeconds
        self.configuredWPM = configuredWPM
        self.startedAt = startedAt
        self.finishedAt = finishedAt

        let minutes = readingTimeSeconds / 60.0
        self.actualWPM = minutes > 0 ? min(configuredWPM, Int(Double(totalWords) / minutes)) : configuredWPM
        self.traditionalTimeSeconds = Double(totalWords) / Double(Self.traditionalWPM) * 60.0
        self.timeSavedSeconds = traditionalTimeSeconds - readingTimeSeconds
    }

    var formattedReadingTime: String {
        Self.formatTime(readingTimeSeconds)
    }

    var formattedTimeSaved: String {
        let absTime = abs(timeSavedSeconds)
        let prefix = timeSavedSeconds >= 0 ? "" : "+"
        return prefix + Self.formatTime(absTime)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins > 0 {
            return "\(mins) min \(secs) sec"
        }
        return "\(secs) sec"
    }
}
