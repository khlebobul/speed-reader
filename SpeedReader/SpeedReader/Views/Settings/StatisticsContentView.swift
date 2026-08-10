import SwiftUI

// MARK: - Constants

enum StatisticsConstants {
    static let width: CGFloat = 500
    static let height: CGFloat = 550
}

// MARK: - Overlay

struct StatisticsOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }

            StatisticsContentView(onDismiss: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPresented = false
                }
            })
            .frame(width: StatisticsConstants.width, height: StatisticsConstants.height)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 40, x: 0, y: 15)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

// MARK: - Content

struct StatisticsContentView: View {
    @ObservedObject private var history = ReadingHistoryManager.shared
    @State private var showClearConfirmation = false
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Statistics")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Streak + heatmap
                    StreakHeaderView()
                        .padding(.vertical, 2)

                    ReadingActivityHeatmap(weeks: 20)

                    Divider()

                    // Summary cards
                    summaryGrid
                        .padding(.bottom, 4)

                    Divider()

                    // History
                    if history.sessions.isEmpty {
                        emptyState
                    } else {
                        historySection
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !history.sessions.isEmpty {
                Divider()

                // Footer
                HStack {
                    Button("Clear History") {
                        showClearConfirmation = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Done") {
                        onDismiss?()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(12)
            }
        }
        .alert("Clear Reading History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    history.clearAll()
                }
            }
        } message: {
            Text("This will remove all recorded reading sessions and reset statistics.")
        }
    }

    // MARK: - Summary Grid

    private var summaryGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            statCard(
                title: "Sessions",
                value: "\(history.totalSessions)",
                icon: "book.closed"
            )
            statCard(
                title: "Words Read",
                value: formatNumber(history.totalWordsRead),
                icon: "text.word.spacing"
            )
            statCard(
                title: "Time Saved",
                value: history.formattedTotalTimeSaved,
                icon: "clock.arrow.circlepath",
                valueColor: history.totalTimeSavedSeconds > 0 ? .green : nil
            )
            statCard(
                title: "Avg Speed",
                value: history.averageWPM > 0 ? "\(history.averageWPM) WPM" : "—",
                icon: "gauge.with.needle"
            )
        }
    }

    private func statCard(title: String, value: String, icon: String, valueColor: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(valueColor ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No reading sessions yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Complete a reading to see your statistics here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Sessions")
                .font(.system(size: 13, weight: .medium))

            ForEach(history.sessions) { session in
                sessionRow(session)
            }
        }
    }

    private func sessionRow(_ session: ReadingSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.sourceIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.formattedDate)
                    .font(.system(size: 12, weight: .medium))
                Text("\(session.totalWords) words")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(session.actualWPM) WPM")
                    .font(.system(size: 12, weight: .medium))
                if session.timeSavedSeconds > 0 {
                    Text("−\(session.formattedTimeSaved)")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.02))
        )
    }

    // MARK: - Helpers

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }
}

#Preview {
    StatisticsContentView(onDismiss: {})
        .frame(width: StatisticsConstants.width, height: StatisticsConstants.height)
}
