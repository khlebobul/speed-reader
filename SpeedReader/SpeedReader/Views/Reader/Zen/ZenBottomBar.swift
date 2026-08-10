import SwiftUI

struct ZenBottomBar: View {
    @ObservedObject var engine: RSVPEngine
    @ObservedObject private var settings = ReaderSettings.shared

    @State private var wasPlayingBeforeSeek = false

    var body: some View {
        VStack(spacing: 8) {
            ZenProgressBar(
                progress: engine.progress,
                totalWords: engine.totalWords,
                currentIndex: engine.currentIndex,
                wpm: engine.getWPM(),
                onSeekStart: {
                    wasPlayingBeforeSeek = engine.isPlaying
                    if engine.isPlaying { engine.pause() }
                },
                onSeek: { ratio in
                    let target = Int(ratio * Double(max(0, engine.totalWords - 1)))
                    engine.seekTo(target)
                },
                onSeekEnd: {
                    if wasPlayingBeforeSeek { engine.play() }
                    wasPlayingBeforeSeek = false
                }
            )

            HStack(spacing: 24) {
                ZenIconButton(systemName: "arrow.counterclockwise", size: 22) {
                    engine.restart()
                }
                .help("Restart (R)")

                ZenIconButton(
                    systemName: "repeat",
                    size: 22,
                    tint: settings.zenLoop ? .accentColor : .primary
                ) {
                    settings.zenLoop.toggle()
                }
                .help(settings.zenLoop ? "Loop on (L) — restart from start when finished" : "Loop off (L)")

                HStack(spacing: 8) {
                    ZenIconButton(systemName: "gobackward.10", size: 22) {
                        engine.seekByWords(-10)
                    }
                    .help("Back 10 words (Shift+←)")

                    ZenIconButton(systemName: "backward.fill", size: 22) {
                        engine.previousWord()
                    }
                    .help("Previous word (←)")

                    ZenIconButton(
                        systemName: engine.isPlaying ? "pause.fill" : "play.fill",
                        size: 28,
                        tint: .accentColor
                    ) {
                        engine.togglePlayPause()
                    }
                    .help("Play/Pause (Space)")
                    .padding(.horizontal, 8)

                    ZenIconButton(systemName: "forward.fill", size: 22) {
                        engine.nextWord()
                    }
                    .help("Next word (→)")

                    ZenIconButton(systemName: "goforward.10", size: 22) {
                        engine.seekByWords(10)
                    }
                    .help("Forward 10 words (Shift+→)")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1.5)
                )
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}

private struct ZenIconButton: View {
    let systemName: String
    var size: CGFloat
    var tint: Color = .primary
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(tint.opacity(isHovered ? 1.0 : 0.85))
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
