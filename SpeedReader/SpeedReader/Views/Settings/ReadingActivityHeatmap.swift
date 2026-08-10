import SwiftUI

// MARK: - Heatmap View

struct ReadingActivityHeatmap: View {
    @ObservedObject private var tracker = ReadingStreakTracker.shared
    @State private var hoveredIndex: Int?

    var weeks: Int = 20

    private let gap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            monthLabels
            hoverDetail
            heatmapGrid
            legend
        }
    }

    // MARK: - Hover Detail

    private var hoverDetail: some View {
        Group {
            if let index = hoveredIndex {
                let data = gridData()
                if index < data.count {
                    let item = data[index]
                    Text("\(formattedDate(item.date)) · \(formattedMinutes(item.minutes)) · \(formattedSessions(item.sessions))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(" ")
                    .font(.system(size: 11))
            }
        }
        .frame(height: 14, alignment: .leading)
    }

    // MARK: - Month Labels

    private var monthLabels: some View {
        let data = gridData()
        let calendar = Calendar.current
        let monthFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM"
            return f
        }()

        var months: [(offset: Int, label: String)] = []
        var lastMonth = -1

        // Walk through the flat data, find month transitions
        for i in 0..<data.count {
            let month = calendar.component(.month, from: data[i].date)
            if month != lastMonth {
                let week = i / 7
                months.append((week, monthFormatter.string(from: data[i].date)))
                lastMonth = month
            }
        }

        return HStack(spacing: gap) {
            ForEach(Array(months.enumerated()), id: \.offset) { _, m in
                Text(m.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 0)
    }

    // MARK: - Grid

    private var heatmapGrid: some View {
        GeometryReader { geometry in
            let data = gridData()
            let totalWidth = geometry.size.width
            let cellPlusGap = totalWidth / CGFloat(weeks)
            let cellSize = max(6, floor(cellPlusGap - gap))
            let effectiveGap = cellPlusGap - cellSize

            HStack(spacing: effectiveGap) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: effectiveGap) {
                        ForEach(0..<7, id: \.self) { day in
                            let idx = week * 7 + day
                            if idx < data.count {
                                let item = data[idx]
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(colorForMinutes(item.minutes))
                                    .frame(width: cellSize, height: cellSize)
                                    .contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active:
                                            hoveredIndex = idx
                                        case .ended:
                                            if hoveredIndex == idx {
                                                hoveredIndex = nil
                                            }
                                        }
                                    }
                            } else {
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 7 * (460 / CGFloat(weeks)))
    }

    // MARK: - Color

    private func colorForMinutes(_ minutes: Double) -> Color {
        if minutes < ReadingStreakTracker.minActiveMinutes {
            return Color.primary.opacity(0.04)
        } else if minutes < 15 {
            return .green.opacity(0.25)
        } else if minutes < 30 {
            return .green.opacity(0.45)
        } else if minutes < 60 {
            return .green.opacity(0.65)
        } else {
            return .green.opacity(0.85)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Less")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            HStack(spacing: 2) {
                ForEach([0.0, 7.0, 20.0, 45.0, 90.0], id: \.self) { m in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(colorForMinutes(m))
                        .frame(width: 10, height: 10)
                }
            }
            Text("More")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Data

    private func gridData() -> [(date: Date, minutes: Double, sessions: Int)] {
        tracker.activityForLastDays(weeks * 7)
    }

    // MARK: - Helpers

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    private func formattedMinutes(_ minutes: Double) -> String {
        if minutes < 1 {
            return "\(Int(minutes * 60)) sec"
        }
        let m = Int(minutes)
        let s = Int((minutes - Double(m)) * 60)
        if s > 0 {
            return "\(m) min \(s) sec"
        }
        return "\(m) min"
    }

    private func formattedSessions(_ count: Int) -> String {
        switch count {
        case 0: return "no readings"
        case 1: return "1 reading"
        default: return "\(count) readings"
        }
    }
}

// MARK: - Minimal Streak Header

struct StreakHeaderView: View {
    @ObservedObject private var tracker = ReadingStreakTracker.shared

    var body: some View {
        HStack(spacing: 16) {
            // Current streak
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                Text("\(tracker.currentStreak)-day streak")
                    .font(.system(size: 13, weight: .medium))
            }

            if tracker.totalActiveDays > 0 {
                Text("·")
                    .foregroundStyle(.tertiary)

                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\(tracker.totalActiveDays) days")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Text("·")
                    .foregroundStyle(.tertiary)

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(formattedTotalMinutes(tracker.totalMinutes))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formattedTotalMinutes(_ minutes: Double) -> String {
        let hrs = Int(minutes) / 60
        let mins = Int(minutes) % 60
        if hrs > 0 {
            return "\(hrs)h \(mins)m"
        }
        return "\(mins)m"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        StreakHeaderView()
        ReadingActivityHeatmap()
    }
    .padding()
    .frame(width: 500)
}
