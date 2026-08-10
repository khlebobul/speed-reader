import Foundation

/// Tracks daily reading activity and streaks for a Duolingo-style streak display
/// and a GitHub-style contribution heatmap.
final class ReadingStreakTracker: ObservableObject {
    static let shared = ReadingStreakTracker()

    private let dailyMinutesKey = "readingStreakDailyMinutes"
    private let dailySessionsKey = "readingStreakDailySessions"
    private let longestStreakKey = "readingStreakLongest"
    private let historyBackfillKey = "readingStreakHistoryBackfilled"

    /// Minimum minutes in a day to count as an active reading day.
    /// Matches `ReadingHistoryManager.minValidDurationSeconds` (5 s ≈ 0.1 min).
    static let minActiveMinutes: Double = 0.1

    /// Daily minutes read, keyed by "yyyy-MM-dd".
    @Published private(set) var dailyMinutes: [String: Double] = [:]

    /// Daily reading session count, keyed by "yyyy-MM-dd".
    @Published private(set) var dailySessions: [String: Int] = [:]

    /// Cached longest streak ever recorded.
    @Published private(set) var longestStreak: Int = 0

    init() {
        load()
        backfillFromHistoryIfNeeded()
    }

    // MARK: - Recording

    /// Record reading minutes for a given day. Adds to any existing minutes for that day.
    func record(minutes: Double, on date: Date = Date()) {
        guard minutes > 0 else { return }
        let key = Self.dayKey(date)
        let existing = dailyMinutes[key] ?? 0
        dailyMinutes[key] = existing + minutes
        dailySessions[key] = (dailySessions[key] ?? 0) + 1
        save()
        updateLongestStreakIfNeeded()
    }

    /// Record seconds and convert to minutes.
    func record(seconds: TimeInterval, on date: Date = Date()) {
        record(minutes: seconds / 60.0, on: date)
    }

    // MARK: - Queries

    /// Minutes read on a specific day.
    func minutes(on date: Date) -> Double {
        dailyMinutes[Self.dayKey(date)] ?? 0
    }

    /// Whether the day had any qualifying reading activity.
    func isActiveDay(_ date: Date) -> Bool {
        minutes(on: date) >= Self.minActiveMinutes
    }

    /// Current streak — consecutive active days ending today or yesterday.
    /// (Duolingo-style: if you read yesterday, your streak is still alive today even
    /// if you haven't read yet.)
    var currentStreak: Int {
        guard !dailyMinutes.isEmpty else { return 0 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var streak = 0
        var date = today

        // If today is active, count it; otherwise start from yesterday
        if isActiveDay(date) {
            streak = 1
            date = calendar.date(byAdding: .day, value: -1, to: date)!
        } else {
            date = calendar.date(byAdding: .day, value: -1, to: date)!
            if !isActiveDay(date) {
                return 0
            }
            streak = 1
            date = calendar.date(byAdding: .day, value: -1, to: date)!
        }

        while isActiveDay(date) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        }

        return streak
    }

    /// Total number of active days ever recorded.
    var totalActiveDays: Int {
        dailyMinutes.values.filter { $0 >= Self.minActiveMinutes }.count
    }

    /// Total minutes read across all recorded days.
    var totalMinutes: Double {
        dailyMinutes.values.reduce(0, +)
    }

    /// Activity data for the last `days` days, newest first.
    func activityForLastDays(_ days: Int) -> [(date: Date, minutes: Double, sessions: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var result: [(Date, Double, Int)] = []
        for offset in (0..<days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            result.append((date, minutes(on: date), dailySessions[Self.dayKey(date)] ?? 0))
        }
        return result
    }

    // MARK: - Private

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static func dayKey(_ date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: dailyMinutesKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            dailyMinutes = decoded
        }
        if let data = UserDefaults.standard.data(forKey: dailySessionsKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            dailySessions = decoded
        }
        longestStreak = UserDefaults.standard.integer(forKey: longestStreakKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(dailyMinutes) {
            UserDefaults.standard.set(data, forKey: dailyMinutesKey)
        }
        if let data = try? JSONEncoder().encode(dailySessions) {
            UserDefaults.standard.set(data, forKey: dailySessionsKey)
        }
    }

    private func updateLongestStreakIfNeeded() {
        let current = currentStreak
        if current > longestStreak {
            longestStreak = current
            UserDefaults.standard.set(longestStreak, forKey: longestStreakKey)
        }
    }

    /// One-time import of sessions recorded before the streak tracker existed.
    private func backfillFromHistoryIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: historyBackfillKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: historyBackfillKey) }

        let history = ReadingHistoryManager.shared.sessions
        guard !history.isEmpty else { return }

        var minutes: [String: Double] = [:]
        var sessionCounts: [String: Int] = [:]
        for session in history {
            let key = Self.dayKey(session.date)
            minutes[key, default: 0] += session.readingTimeSeconds / 60.0
            sessionCounts[key, default: 0] += 1
        }

        dailyMinutes = minutes
        dailySessions = sessionCounts
        save()
        recalculateLongestStreak()
    }

    private func recalculateLongestStreak() {
        let calendar = Calendar.current
        let formatter = Self.dayKeyFormatter

        let activeDates = dailyMinutes.compactMap { key, minutes -> Date? in
            guard minutes >= Self.minActiveMinutes,
                  let date = formatter.date(from: key) else { return nil }
            return calendar.startOfDay(for: date)
        }.sorted()

        guard !activeDates.isEmpty else {
            longestStreak = 0
            UserDefaults.standard.set(0, forKey: longestStreakKey)
            return
        }

        var maxStreak = 1
        var running = 1
        for index in 1..<activeDates.count {
            let previous = activeDates[index - 1]
            let current = activeDates[index]
            if let nextDay = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(nextDay, inSameDayAs: current) {
                running += 1
                maxStreak = max(maxStreak, running)
            } else if !calendar.isDate(previous, inSameDayAs: current) {
                running = 1
            }
        }

        longestStreak = maxStreak
        UserDefaults.standard.set(longestStreak, forKey: longestStreakKey)
    }
}
