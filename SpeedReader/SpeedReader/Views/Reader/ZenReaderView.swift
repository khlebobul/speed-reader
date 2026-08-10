import SwiftUI
import AppKit

struct ZenReaderView: View {
    @ObservedObject var engine: RSVPEngine
    @ObservedObject private var settings = ReaderSettings.shared
    var onClose: () -> Void

    @State private var appeared = false
    @State private var uiHidden = false
    @State private var uiHideTimer: Timer?
    @State private var activityMonitor: Any?
    /// Block shown in the fullscreen lightbox overlay (nil = hidden). Local to Zen
    /// because the Zen window is its own NSWindow on its own Space.
    @State private var lightboxBlock: PauseableBlock?

    private let uiHideDelay: TimeInterval = 2.0

    private var isDark: Bool {
        switch settings.themeMode {
        case .dark: return true
        case .light: return false
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    private var background: Color {
        isDark ? Color(red: 0.10, green: 0.10, blue: 0.10) : .white
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .opacity(uiHidden ? 0 : 1)
                    .allowsHitTesting(!uiHidden)

                if showPauseSettings {
                    ZenPauseSettingsPanel(engine: engine)
                        .opacity(uiHidden ? 0 : 1)
                        .allowsHitTesting(!uiHidden)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 10)
                }

                readingArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                infoBar
                    .opacity(uiHidden ? 0 : 1)

                ZenBottomBar(engine: engine)
                    .opacity(uiHidden ? 0 : 1)
                    .allowsHitTesting(!uiHidden)
            }

            // Lightbox overlay — covers the full Zen fullscreen window so the
            // image fills the user's display. Esc closes it via its own monitor
            // (LIFO ordering ensures Zen's outer Esc handler doesn't fire).
            if let block = lightboxBlock {
                BlockLightboxOverlay(block: block, onDismiss: closeLightbox)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: lightboxBlock != nil)
        .preferredColorScheme(settings.themeMode.colorScheme)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: appeared)
        .animation(.easeInOut(duration: 0.4), value: uiHidden)
        .onAppear {
            appeared = true
            installActivityMonitor()
            engine.loopEnabled = settings.zenLoop
            engine.setWordsPerChunk(settings.zenWordsPerChunk)
        }
        .onDisappear {
            removeActivityMonitor()
            uiHideTimer?.invalidate()
            uiHideTimer = nil
            // Reset so other reading modes don't inherit Zen-only flags.
            engine.loopEnabled = false
            engine.setWordsPerChunk(1)
        }
        .onChange(of: settings.zenLoop) { _, enabled in
            engine.loopEnabled = enabled
        }
        .onChange(of: settings.zenWordsPerChunk) { _, n in
            engine.setWordsPerChunk(n)
        }
        .onChange(of: engine.isPlaying) { _, playing in
            if playing {
                resetHideTimer()
            } else {
                uiHideTimer?.invalidate()
                showUI()
            }
        }
        .onChange(of: settings.zenAutoHideUI) { _, enabled in
            if !enabled { showUI() } else { resetHideTimer() }
        }
    }

    // MARK: - Subviews

    private var readingArea: some View {
        VStack(spacing: 32) {
            Spacer(minLength: 0)

            if engine.isFinished {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("Finish!")
                            .font(.system(size: 56, weight: .bold))
                        if let stats = engine.readingStats {
                            TimeSavedText(stats: stats, isDark: isDark)
                        }
                    }

                    Button(action: onClose) {
                        Text("Done")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 28)
                            .padding(.vertical, 10)
                            .overlay(
                                Capsule().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
                .frame(maxWidth: .infinity)
            } else if let block = engine.currentPauseableBlock {
                RSVPBlockPreviewView(
                    block: block,
                    style: settings.showImagePreviewInReader ? .full : .compact,
                    dark: isDark,
                    maxWidth: 700,
                    maxHeight: 420,
                    compactWordSize: settings.zenFontSize,
                    autoContinueDeadline: engine.autoContinueDeadline,
                    onContinue: engine.togglePlayPause,
                    onOpen: settings.showImagePreviewInReader ? { openLightbox(for: block) } : nil
                )
                .frame(maxWidth: 900, minHeight: 140)
            } else {
                VStack(spacing: 8) {
                    if settings.zenShowPreviousContext {
                        PreviousContextLine(engine: engine, dark: isDark)
                            .frame(maxWidth: 800)
                    }
                    ChunkedORPView(
                        words: engine.currentChunkWords,
                        baseSize: settings.zenFontSize,
                        fontFamily: settings.fontFamilyPreset,
                        highlightColor: settings.orpColor,
                        maxWidth: 900,
                        showIndicators: settings.showORPIndicators,
                        indicatorColor: settings.orpColor
                    )
                }
                .frame(height: orpClusterHeight)
                .frame(maxWidth: 900)
            }

            if settings.zenShowContext {
                ZenContextParagraph(
                    words: contextWords,
                    startIndex: 0
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 64)
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Close Zen (Esc)")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var infoBar: some View {
        HStack(spacing: 48) {
            Text(engine.remainingTime == "0:00" ? "< 1 min" : engine.remainingTime)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("\(max(0, engine.totalWords - engine.currentIndex))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("WORDS REMAINING")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if !engine.isPlaying && !engine.isFinished && engine.totalWords > 0 {
                TimeSavingsEstimateView(
                    totalWords: engine.totalWords,
                    wpm: settings.wpm,
                    isDark: isDark
                )
            }
        }
        .padding(.vertical, 8)
    }

    private var showPauseSettings: Bool {
        !engine.isPlaying && !engine.isFinished && engine.totalWords > 0
    }

    private var orpClusterHeight: CGFloat {
        max(140, settings.zenFontSize + (settings.zenShowPreviousContext ? 84 : 44))
    }

    // MARK: - Context

    private var contextWords: [String] {
        // Start after the current chunk so we don't repeat words already shown in the ORP block.
        let after = engine.currentChunkRange.upperBound - 1
        return engine.upcomingWords(after: after, limit: 60)
    }

    // MARK: - Lightbox

    /// Opens the fullscreen lightbox and cancels any pending auto-continue countdown
    /// so the engine doesn't fire mid-inspection. The user resumes explicitly with
    /// Space after dismissing.
    private func openLightbox(for block: PauseableBlock) {
        engine.cancelAutoContinueTimer()
        lightboxBlock = block
    }

    private func closeLightbox() {
        lightboxBlock = nil
    }

    // MARK: - Auto-hide UI

    private func installActivityMonitor() {
        guard activityMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            DispatchQueue.main.async { resetHideTimer() }
            return event
        }
        if engine.isPlaying { resetHideTimer() }
    }

    private func removeActivityMonitor() {
        if let m = activityMonitor {
            NSEvent.removeMonitor(m)
            activityMonitor = nil
        }
    }

    private func showUI() {
        uiHidden = false
    }

    private func hideUI() {
        guard settings.zenAutoHideUI, engine.isPlaying else { return }
        uiHidden = true
    }

    private func resetHideTimer() {
        showUI()
        uiHideTimer?.invalidate()
        guard settings.zenAutoHideUI, engine.isPlaying else { return }
        uiHideTimer = Timer.scheduledTimer(withTimeInterval: uiHideDelay, repeats: false) { _ in
            DispatchQueue.main.async { hideUI() }
        }
    }
}

private struct ZenPauseSettingsPanel: View {
    @ObservedObject var engine: RSVPEngine
    @ObservedObject private var settings = ReaderSettings.shared

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                pauseControls
                    .frame(minWidth: geometry.size.width, alignment: .center)
                    .padding(.horizontal, 2)
            }
        }
        .frame(height: 42)
        .frame(maxWidth: 1400)
    }

    private var pauseControls: some View {
        HStack(spacing: 12) {
            ZenPauseStepper(
                title: "WPM",
                value: "\(settings.wpm)",
                decrement: { engine.setWPM(settings.wpm - 50) },
                increment: { engine.setWPM(settings.wpm + 50) },
                canDecrement: settings.wpm > 100,
                canIncrement: settings.wpm < 1000
            )

            ZenPauseStepper(
                title: "Words at a Time",
                value: "\(settings.zenWordsPerChunk)",
                decrement: { settings.zenWordsPerChunk -= 1 },
                increment: { settings.zenWordsPerChunk += 1 },
                canDecrement: settings.zenWordsPerChunk > 1,
                canIncrement: settings.zenWordsPerChunk < 7
            )

            ZenPauseStepper(
                title: "Font Size",
                value: "\(Int(settings.zenFontSize))",
                decrement: {
                    settings.zenFontSize = max(
                        ReaderSettings.zenMinFontSize,
                        settings.zenFontSize - 2
                    )
                },
                increment: {
                    settings.zenFontSize = min(
                        ReaderSettings.zenMaxFontSize,
                        settings.zenFontSize + 2
                    )
                },
                canDecrement: settings.zenFontSize > ReaderSettings.zenMinFontSize,
                canIncrement: settings.zenFontSize < ReaderSettings.zenMaxFontSize
            )

            ZenPauseCheckbox(
                title: "Show upcoming words",
                isOn: $settings.zenShowContext
            )

            ZenPauseCheckbox(
                title: "Show previous words",
                isOn: $settings.zenShowPreviousContext
            )

            ZenPauseCheckbox(
                title: "Auto-hide UI",
                isOn: $settings.zenAutoHideUI
            )

            ZenPauseCheckbox(
                title: "Loop",
                isOn: $settings.zenLoop
            )
        }
    }
}

private struct ZenPauseStepper: View {
    let title: String
    let value: String
    let decrement: () -> Void
    let increment: () -> Void
    var canDecrement = true
    var canIncrement = true

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(action: decrement) {
                Text("-")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 18, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canDecrement ? Color.secondary : Color.secondary.opacity(0.35))
            .disabled(!canDecrement)

            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: 28)

            Button(action: increment) {
                Text("+")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 18, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canIncrement ? Color.secondary : Color.secondary.opacity(0.35))
            .disabled(!canIncrement)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(Color.primary.opacity(0.025))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1.2)
        )
    }
}

private struct ZenPauseCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(Color.primary.opacity(0.025))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }
}
