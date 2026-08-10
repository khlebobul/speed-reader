import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let notchWidgetDidHide = Notification.Name("notchWidgetDidHide")
    static let openSettings = Notification.Name("openSettings")
    static let externalReaderDidClose = Notification.Name("externalReaderDidClose")
    static let switchToTab = Notification.Name("switchToTab")
    static let openFilePicker = Notification.Name("openFilePicker")
    static let startReading = Notification.Name("startReading")
    static let captureScreenArea = Notification.Name("captureScreenArea")
    static let highlightCloseButton = Notification.Name("highlightCloseButton")
    static let showOnboarding = Notification.Name("showOnboarding")
    static let openStatistics = Notification.Name("openStatistics")
    static let openFileFromFinder = Notification.Name("openFileFromFinder")
    static let dismissDocument = Notification.Name("dismissDocument")
    static let openSearch = Notification.Name("openSearch")
    static let toggleTOC = Notification.Name("toggleTOC")
    static let loadBrowserURL = Notification.Name("loadBrowserURL")
}

// MARK: - Observable State for Notch

final class NotchState: ObservableObject {
    @Published var isExpanded: Bool = false
    @Published var countdown: Int? = nil
}

// MARK: - Keyable Panel

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Notch Window Controller

class NotchWindowController: NSWindowController, NSWindowDelegate {

    private let notchState = NotchState()
    private var engine: RSVPEngine

    // Mouse monitors for hover detection and click-through
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    // Keyboard monitors for reader controls (local + global)
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    // Countdown cancellation token
    private var countdownGeneration = 0
    // Closure scheduled to fire when the 3-2-1 countdown completes; held so the
    // play button / Space can short-circuit the countdown and start playback now.
    private var pendingPlay: (() -> Void)?

    // Settings observation for live resize
    private var settingsCancellables = Set<AnyCancellable>()

    init(engine: RSVPEngine) {
        self.engine = engine

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 260)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)
        configurePanel(panel)
        setupContentView()
        positionPanel()
        observeSizeChanges()

        panel.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configurePanel(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.hidesOnDeactivate = false
        // Start click-through; mouse monitor will enable interaction over the pill
        panel.ignoresMouseEvents = true
    }

    private func setupContentView() {
        guard let panel = window else { return }

        let hostingView = NotchHostingView(
            engine: engine,
            notchState: notchState,
            onPlayPause: { [weak self] in
                self?.handlePlayPause()
            },
            onClose: { [weak self] in
                self?.hideWithAnimation()
            }
        )

        let nsHostingView = NSHostingView(rootView: hostingView)
        nsHostingView.frame = panel.contentView?.bounds ?? .zero
        nsHostingView.autoresizingMask = [.width, .height]

        panel.contentView = nsHostingView
    }

    // MARK: - Live Resize

    private func observeSizeChanges() {
        Publishers.CombineLatest(
            ReaderSettings.shared.$notchExpandedWidth,
            ReaderSettings.shared.$notchExpandedHeight
        )
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _ in
            guard self?.window?.isVisible == true else { return }
            self?.positionPanel()
        }
        .store(in: &settingsCancellables)
    }

    // MARK: - Mouse Tracking

    private func startMouseTracking() {
        guard globalMouseMonitor == nil else { return }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMove()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMove()
            return event
        }
    }

    private func stopMouseTracking() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        window?.ignoresMouseEvents = true
    }

    // MARK: - Key Monitoring

    private func handleKeyEvent(_ keyCode: UInt16, shift: Bool) {
        guard notchState.isExpanded, !AppDelegate.shared.isSettingsPreviewActive else { return }
        switch keyCode {
        case 53: // Esc
            hideWithAnimation()
        case 49: // Space
            handlePlayPause()
        case 15: // R
            engine.restart()
        case 123: // Left arrow — word step, or 10 words back with Shift
            shift ? engine.seekByWords(-10) : engine.previousWord()
        case 124: // Right arrow — word step, or 10 words forward with Shift
            shift ? engine.seekByWords(10) : engine.nextWord()
        case 126: // Up arrow
            engine.setWPM(engine.getWPM() + 50)
        case 125: // Down arrow
            engine.setWPM(engine.getWPM() - 50)
        default:
            break
        }
    }

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        // Local monitor — when app is active
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.notchState.isExpanded else { return event }
            self.handleKeyEvent(event.keyCode, shift: event.modifierFlags.contains(.shift))
            return nil
        }
        // Global monitor — when app is in background (requires accessibility)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event.keyCode, shift: event.modifierFlags.contains(.shift))
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
    }

    private func handleMouseMove() {
        guard let panel = window, panel.isVisible else { return }
        // Expanded widget is always interactive; collapsed/hidden passes through
        panel.ignoresMouseEvents = !notchState.isExpanded
    }

    // MARK: - Position

    private func positionPanel() {
        guard let screen = NSScreen.main, let window = window else { return }

        let settings = ReaderSettings.shared
        let w = settings.notchExpandedWidth
        let h = settings.notchExpandedHeight
        let screenFrame = screen.frame

        window.setFrame(
            NSRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h),
            display: true
        )
    }

    // MARK: - Expand / Collapse

    func expand() {
        guard !notchState.isExpanded else { return }
        notchState.isExpanded = true
        window?.ignoresMouseEvents = false
        window?.makeKey()
    }

    func collapse() {
        guard notchState.isExpanded else { return }
        countdownGeneration += 1  // cancel any running countdown
        notchState.countdown = nil
        pendingPlay = nil
        notchState.isExpanded = false
    }

    /// Play button / Space tap. If the 3-2-1 countdown is running, cancel it and
    /// start playback immediately so the user does not miss the first words to
    /// the overlay; otherwise toggle play/pause as usual.
    func handlePlayPause() {
        if notchState.countdown != nil, let play = pendingPlay {
            countdownGeneration += 1
            notchState.countdown = nil
            pendingPlay = nil
            play()
        } else {
            engine.togglePlayPause()
        }
    }

    /// Shows the notch expanded for settings preview (no countdown, no playback).
    func showPreview() {
        showWindow(nil)
        expand()
    }

    /// Shows the notch, expands it, runs a 3-2-1 countdown, then calls `play`.
    func startWithCountdown(play: @escaping () -> Void) {
        showWindow(nil)
        expand()

        countdownGeneration += 1
        let gen = countdownGeneration
        notchState.countdown = 3
        pendingPlay = play

        for (delay, value) in [(1.0, 2), (2.0, 1)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.countdownGeneration == gen else { return }
                self?.notchState.countdown = value
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard self?.countdownGeneration == gen else { return }
            self?.notchState.countdown = nil
            self?.pendingPlay = nil
            play()
        }
    }

    // MARK: - Show / Hide

    override func showWindow(_ sender: Any?) {
        guard let window = window else { return }

        positionPanel()
        super.showWindow(sender)
        window.orderFrontRegardless()
        startMouseTracking()
        installKeyMonitor()
    }

    func hideWithAnimation() {
        guard let window = window else { return }

        engine.pause()
        stopMouseTracking()
        removeKeyMonitor()

        countdownGeneration += 1  // cancel any running countdown
        notchState.countdown = nil
        pendingPlay = nil
        if notchState.isExpanded {
            notchState.isExpanded = false
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }) {
            window.orderOut(nil)
            window.alphaValue = 1
            NotificationCenter.default.post(name: .notchWidgetDidHide, object: nil)
            NotificationCenter.default.post(name: .externalReaderDidClose, object: nil)
        }
    }

    static func hasNotch() -> Bool {
        guard let screen = NSScreen.main else { return false }
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }
}

// MARK: - Hosting View Wrapper

struct NotchHostingView: View {
    @ObservedObject var engine: RSVPEngine
    @ObservedObject var notchState: NotchState
    let onPlayPause: () -> Void
    let onClose: () -> Void

    var body: some View {
        NotchContentView(
            engine: engine,
            isExpanded: $notchState.isExpanded,
            countdown: $notchState.countdown,
            onPlayPause: onPlayPause,
            onClose: onClose
        )
    }
}
