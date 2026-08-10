import SwiftUI

/// Compact "time saved" line shown after reading finishes
struct TimeSavedText: View {
    let stats: ReadingSessionStats
    let isDark: Bool

    var body: some View {
        if stats.timeSavedSeconds > 0 {
            Text("Saved ~\(stats.formattedTimeSaved)")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.green)
        }
    }
}
