//
//  SeparateReaderWindow.swift
//  SpeedReader
//
//  Floating reader panel – textream-style borderless draggable widget
//

import AppKit
import SwiftUI
import Combine

// MARK: - Dismiss State

class DismissState: ObservableObject {
    @Published var shouldDismiss: Bool = false
}

// MARK: - Glass Effect

struct GlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Keyable Panel

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Separate Reader Window Controller

class SeparateReaderWindowController {
    private var panel: NSPanel?
    private weak var engine: RSVPEngine?
    private let settings = ReaderSettings.shared
    private var keyMonitor: Any?
    private var engineCancellable: AnyCancellable?
    private var settingsCancellables = Set<AnyCancellable>()
    private let dismissState = DismissState()

    func show(engine: RSVPEngine) {
        self.engine = engine

        if let panel = panel {
            panel.orderFrontRegardless()
            return
        }

        dismissState.shouldDismiss = false

        let readerView = SeparateReaderView(
            engine: engine,
            dismissState: dismissState,
            onClose: { [weak self] in self?.dismissWithAnimation() }
        )
        let hostingView = NSHostingView(rootView: readerView)

        let panelWidth: CGFloat = 520
        let panelHeight: CGFloat = 300
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin = NSPoint(
            x: screenFrame.midX - panelWidth / 2,
            y: screenFrame.midY - panelHeight / 2 + 60
        )

        var panelSize = NSSize(width: panelWidth, height: panelHeight)

        if settings.separateWindowRememberPosition,
           let saved = UserDefaults.standard.string(forKey: "separateReaderWindowFrame") {
            let savedFrame = NSRectFromString(saved)
            let isOnScreen = NSScreen.screens.contains { $0.frame.intersects(savedFrame) }
            if savedFrame != .zero && isOnScreen {
                origin = savedFrame.origin
                panelSize = savedFrame.size
            }
        }

        let panel = KeyablePanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: panelSize.width, height: panelSize.height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 620, height: 200)
        panel.maxSize = NSSize(width: 900, height: 500)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = settings.separateWindowAlwaysOnTop ? .screenSaver : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.alphaValue = settings.separateWindowOpacity
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hostingView

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        installKeyMonitor()
        installSettingsObservers()

        // Auto-close after reading finishes
        engineCancellable = engine.$isFinished
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self?.dismissWithAnimation()
                }
            }
    }

    func bringToFront() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        dismissWithAnimation()
    }

    func updateSettings() {
        guard let panel = panel else { return }
        panel.level = settings.separateWindowAlwaysOnTop ? .screenSaver : .floating
        panel.alphaValue = settings.separateWindowOpacity
    }

    // MARK: - Private

    private func installSettingsObservers() {
        settingsCancellables.removeAll()

        settings.$separateWindowOpacity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] opacity in
                self?.panel?.alphaValue = opacity
            }
            .store(in: &settingsCancellables)

        settings.$separateWindowAlwaysOnTop
            .receive(on: DispatchQueue.main)
            .sink { [weak self] alwaysOnTop in
                self?.panel?.level = alwaysOnTop ? .screenSaver : .floating
            }
            .store(in: &settingsCancellables)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let engine = self.engine,
                  !AppDelegate.shared.isSettingsPreviewActive else { return event }
            switch event.keyCode {
            case 53: // Esc
                self.dismissWithAnimation()
                return nil
            case 49: // Space
                engine.togglePlayPause()
                return nil
            case 15: // R
                engine.restart()
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
            case 126: // Up arrow
                engine.setWPM(engine.getWPM() + 50)
                return nil
            case 125: // Down arrow
                engine.setWPM(engine.getWPM() - 50)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    func dismissWithAnimation() {
        guard panel != nil else { return }
        dismissState.shouldDismiss = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.cleanup()
        }
    }

    private func cleanup() {
        guard let panel = panel else { return }

        if settings.separateWindowRememberPosition {
            UserDefaults.standard.set(panel.frameDescriptor, forKey: "separateReaderWindowFrame")
        }
        removeKeyMonitor()
        engineCancellable = nil
        settingsCancellables.removeAll()
        engine?.pause()

        // Ensure the panel stops intercepting any mouse events immediately
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.contentView = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
        dismissState.shouldDismiss = false
        NotificationCenter.default.post(name: .externalReaderDidClose, object: nil)
    }
}

// MARK: - Separate Reader View

struct SeparateReaderView: View {
    @ObservedObject var engine: RSVPEngine
    @ObservedObject var dismissState: DismissState
    var onClose: () -> Void = {}
    @ObservedObject private var settings = ReaderSettings.shared

    @State private var appeared = false
    @State private var closeButtonScale: CGFloat = 1.0
    private var isPreview: Bool { AppDelegate.shared.isSettingsPreviewActive }

    var body: some View {
        VStack(spacing: 0) {
            // Word display
            ZStack {
                if engine.isFinished {
                    VStack(spacing: 6) {
                        Text("Finish!")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundColor(.white)
                        if let stats = engine.readingStats {
                            TimeSavedText(stats: stats, isDark: true)
                        }
                    }
                } else if let block = engine.currentPauseableBlock {
                    // Separate Window always uses the compact hint, never the thumbnail.
                    // The window is a small floating panel — the source document preview
                    // stays in the Main window where the user can scroll back to the image.
                    RSVPBlockPreviewView(
                        block: block,
                        style: .compact,
                        dark: true,
                        compactWordSize: settings.fontSizePreset.pointSize,
                        autoContinueDeadline: engine.autoContinueDeadline,
                        onContinue: engine.togglePlayPause
                    )
                    .padding(.horizontal, 24)
                } else {
                    ORPWordView(
                        word: engine.currentWord,
                        settings: settings,
                        maxWidth: 380
                    )
                    .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)

            // Separator
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Bottom bar
            VStack(spacing: 0) {
                if settings.showProgressBar {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.15))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.6))
                                .frame(width: geo.size.width * (engine.progress / 100), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }

                // Pre-reading time estimate
                if !engine.isPlaying && !engine.isFinished && engine.totalWords > 0 {
                    TimeSavingsEstimateView(
                        totalWords: engine.totalWords,
                        wpm: engine.getWPM(),
                        isDark: true
                    )
                    .padding(.top, 4)
                }

                ZStack {
                    // Center: play/pause — absolute center
                    if isPreview {
                        Text("Preview")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    } else {
                        HStack(spacing: 0) {
                            HStack(spacing: 10) {
                                NotchControlButton(icon: "backward.end.fill", size: 26) {
                                    engine.restart()
                                }
                                NotchControlButton(icon: "gobackward.10", size: 26) {
                                    engine.seekByWords(-10)
                                }
                                .help("Back 10 words (Shift+←)")
                                NotchControlButton(icon: "backward.fill", size: 26) {
                                    engine.previousWord()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)

                            NotchControlButton(
                                icon: engine.isPlaying ? "pause.fill" : "play.fill",
                                size: 30
                            ) {
                                engine.togglePlayPause()
                            }
                            .padding(.horizontal, 16)

                            HStack(spacing: 10) {
                                NotchControlButton(icon: "forward.fill", size: 26) {
                                    engine.nextWord()
                                }
                                NotchControlButton(icon: "goforward.10", size: 26) {
                                    engine.seekByWords(10)
                                }
                                .help("Forward 10 words (Shift+→)")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Left + Right pinned elements
                    HStack {
                        Text("\(engine.currentIndex + 1)/\(engine.totalWords)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))

                        Spacer()

                        HStack(spacing: 6) {
                            NotchControlButton(icon: "minus", size: 22) {
                                engine.setWPM(engine.getWPM() - 50)
                            }
                            Text("\(engine.getWPM())")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55))
                                .frame(width: 40, alignment: .center)
                            NotchControlButton(icon: "plus", size: 22) {
                                engine.setWPM(engine.getWPM() + 50)
                            }
                        }

                        NotchControlButton(icon: "xmark", size: 22) {
                            onClose()
                        }
                        .scaleEffect(closeButtonScale)
                        .help("Stop reading (Esc)")
                        .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, settings.showProgressBar ? 0 : 10)
                .padding(.bottom, 12)
            }
        }
        .background(
            ZStack {
                GlassEffectView()
                RoundedRectangle(cornerRadius: 16)
                    .fill(.black.opacity(0.72))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.92)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { appeared = true }
        }
        .onChange(of: dismissState.shouldDismiss) { _, dismiss in
            if dismiss {
                withAnimation(.easeIn(duration: 0.25)) { appeared = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightCloseButton)) { _ in
            animateCloseButton()
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

#Preview {
    SeparateReaderView(engine: RSVPEngine(), dismissState: DismissState(), onClose: {})
        .frame(width: 520, height: 300)
        .background(.black)
}
