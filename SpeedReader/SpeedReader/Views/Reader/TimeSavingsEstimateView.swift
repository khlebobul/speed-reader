import SwiftUI

// MARK: - Time Savings Estimate

/// Pre-reading time-savings estimate shown before the user starts playing.
/// Format: "Normal: X min · App: Y min · Save W min (N×)"
struct TimeSavingsEstimateView: View {
    let totalWords: Int
    let wpm: Int
    let isDark: Bool

    private var estimate: TimeSavingsEstimate {
        TimeSavingsEstimate(totalWords: totalWords, wpm: wpm)
    }

    var body: some View {
        if estimate.isValid {
            Text(estimate.formattedString)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isDark ? .white.opacity(0.55) : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isDark ? Color.white.opacity(0.08) : Color.primary.opacity(0.05))
                )
        }
    }
}

// MARK: - Estimate Model

struct TimeSavingsEstimate {
    let totalWords: Int
    let wpm: Int

    /// Average traditional reading speed (WPM)
    static let traditionalWPM = ReadingSessionStats.traditionalWPM

    var isValid: Bool {
        totalWords > 0 && wpm > 0
    }

    var traditionalTimeSeconds: TimeInterval {
        Double(totalWords) / Double(Self.traditionalWPM) * 60.0
    }

    var appTimeSeconds: TimeInterval {
        Double(totalWords) / Double(wpm) * 60.0
    }

    var timeSavedSeconds: TimeInterval {
        traditionalTimeSeconds - appTimeSeconds
    }

    var speedMultiplier: Double {
        Double(wpm) / Double(Self.traditionalWPM)
    }

    var formattedString: String {
        let normal = formatDuration(traditionalTimeSeconds)
        let app = formatDuration(appTimeSeconds)
        let saved = formatDuration(abs(timeSavedSeconds))
        let multiplier = String(format: "%.1f×", speedMultiplier)

        if timeSavedSeconds > 0 {
            return "Normal: \(normal) · App: \(app) · Save \(saved) (\(multiplier))"
        } else {
            return "Normal: \(normal) · App: \(app)"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(ceil(seconds))
        let mins = total / 60
        let secs = total % 60
        if mins > 0 && secs > 0 {
            return "\(mins) min \(secs) sec"
        } else if mins > 0 {
            return "\(mins) min"
        } else {
            return "\(secs) sec"
        }
    }
}
