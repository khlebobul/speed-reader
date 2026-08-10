import SwiftUI

struct InlineReaderView: View {
    @ObservedObject var engine: RSVPEngine
    @Binding var wpm: Double
    var onClose: () -> Void
    /// Hoists the lightbox to the host window so it can cover the full content
    /// (sidebar + reader area), not just the reader card's bounds.
    var onOpenLightbox: ((PauseableBlock) -> Void)? = nil

    private let settings = ReaderSettings.shared
    @State private var closeButtonScale: CGFloat = 1.0
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(closeButtonScale != 1.0 ? .accentColor : .secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(closeButtonScale != 1.0 ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                        )
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .scaleEffect(closeButtonScale)
                .help("Stop reading (Esc)")
                .onReceive(NotificationCenter.default.publisher(for: .highlightCloseButton)) { _ in
                    animateCloseButton()
                }
            }

            // ORP Word Display
            Group {
                if engine.isFinished {
                    VStack(spacing: 6) {
                        Text("Finish!")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.primary)
                        if let stats = engine.readingStats {
                            TimeSavedText(stats: stats, isDark: false)
                        }
                    }
                } else if let block = engine.currentPauseableBlock {
                    RSVPBlockPreviewView(
                        block: block,
                        style: settings.showImagePreviewInReader ? .full : .compact,
                        maxWidth: 380,
                        maxHeight: 200,
                        compactWordSize: settings.fontSizePreset.pointSize,
                        autoContinueDeadline: engine.autoContinueDeadline,
                        onContinue: engine.togglePlayPause,
                        onOpen: (settings.showImagePreviewInReader && onOpenLightbox != nil)
                            ? { onOpenLightbox?(block) }
                            : nil
                    )
                } else {
                    ORPWordView(word: engine.currentWord, settings: settings, maxWidth: 380)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: engine.currentPauseableBlock != nil && settings.showImagePreviewInReader ? 260 : 110)
            .animation(.easeInOut(duration: 0.2), value: engine.currentPauseableBlock != nil)

            // Progress
            VStack(spacing: 6) {
                ProgressView(value: engine.progress, total: 100)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)

                HStack {
                    Text("\(engine.currentIndex + 1) / \(engine.totalWords)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(engine.remainingTime)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 8)

            // Pre-reading time estimate
            if !engine.isPlaying && !engine.isFinished && engine.totalWords > 0 {
                TimeSavingsEstimateView(
                    totalWords: engine.totalWords,
                    wpm: Int(wpm),
                    isDark: false
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Playback Controls
            HStack(spacing: 0) {
                HStack(spacing: 22) {
                    Button(action: engine.restart) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: [])

                    Button(action: { engine.seekByWords(-10) }) {
                        Image(systemName: "gobackward.10")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Back 10 words (Shift+←)")

                    Button(action: engine.previousWord) {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                Button(action: engine.togglePlayPause) {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .padding(.horizontal, 22)

                HStack(spacing: 22) {
                    Button(action: engine.nextWord) {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.rightArrow, modifiers: [])

                    Button(action: { engine.seekByWords(10) }) {
                        Image(systemName: "goforward.10")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Forward 10 words (Shift+→)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 14)

            // Speed Slider
            HStack(spacing: 8) {
                Text("Speed:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Slider(value: $wpm, in: 100...1000, step: 50) { _ in
                    engine.setWPM(Int(wpm))
                }
                .frame(width: 160)

                Text("\(Int(wpm)) WPM")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .leading)
            }
            .padding(.top, 12)

        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 49: // Space — play/pause
                    engine.togglePlayPause()
                    return nil
                case 123: // Left arrow — word step, or 10 words back with Shift
                    if event.modifierFlags.contains(.shift) {
                        engine.seekByWords(-10)
                    } else {
                        engine.previousWord()
                    }
                    return nil
                case 124: // Right arrow — word step, or 10 words forward with Shift
                    if event.modifierFlags.contains(.shift) {
                        engine.seekByWords(10)
                    } else {
                        engine.nextWord()
                    }
                    return nil
                case 126: // Up arrow — speed up
                    wpm = min(1000, wpm + 50)
                    engine.setWPM(Int(wpm))
                    return nil
                case 125: // Down arrow — speed down
                    wpm = max(100, wpm - 50)
                    engine.setWPM(Int(wpm))
                    return nil
                case 15: // R — restart
                    engine.restart()
                    return nil
                case 53: // Escape — close
                    onClose()
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    private func animateCloseButton() {
        withAnimation(.easeInOut(duration: 0.15)) {
            closeButtonScale = 1.35
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.15)) {
                closeButtonScale = 0.9
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.15)) {
                closeButtonScale = 1.15
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeInOut(duration: 0.15)) {
                closeButtonScale = 1.0
            }
        }
    }
}
