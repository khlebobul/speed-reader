import SwiftUI

struct ExternalReaderBar: View {
    @ObservedObject var engine: RSVPEngine
    let mode: ReadingMode
    var onShow: () -> Void
    var onStop: () -> Void

    private var modeName: String {
        switch mode {
        case .notch: return "Notch"
        case .separateWindow: return "Separate Window"
        case .zen: return "Zen Mode"
        case .mainWindow: return ""
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: mode.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Reading in \(modeName)")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(engine.currentIndex + 1) / \(engine.totalWords) · \(engine.remainingTime)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            HStack(spacing: 14) {
                Button(action: { engine.seekByWords(-10) }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Back 10 words")

                Button(action: engine.previousWord) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Previous word")

                Button(action: engine.togglePlayPause) {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help(engine.isPlaying ? "Pause" : "Play")

                Button(action: engine.nextWord) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Next word")

                Button(action: { engine.seekByWords(10) }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Forward 10 words")
            }

            Divider().frame(height: 24)

            if mode != .notch {
                Button(action: onShow) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Show")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(
                        Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Bring \(modeName) to front")
            }

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Stop reading")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
