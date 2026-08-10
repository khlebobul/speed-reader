import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {

    static private(set) var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var notchController: NotchWindowController?
    private let settingsController = SettingsWindowController()
    private let separateReaderController = SeparateReaderWindowController()
    private let zenReaderController = ZenReaderWindowController()
    private var aboutWindow: NSWindow?
    let engine = RSVPEngine()
    let updateManager = UpdateManager.shared

    private var cancellables = Set<AnyCancellable>()
    private var displaySleepActivity: NSObjectProtocol?
    private(set) var isSettingsPreviewActive = false

    /// Last observed browser app (captured before Speed Reader becomes active).
    private var lastBrowserApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Track the last active browser for "Read URL from Browser".
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Bounded shared cache so article images (AsyncImage) are reused across
        // view rebuilds instead of being re-downloaded, while capping how much
        // memory/disk image data can occupy for a large illustrated article.
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,    // 32 MB in-memory
            diskCapacity: 256 * 1024 * 1024,     // 256 MB on-disk
            directory: nil
        )

        setupMenuBar()

        // Observe notch widget hide notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(notchWidgetDidHide),
            name: .notchWidgetDidHide,
            object: nil
        )

        // Hide notch when switching away from notch mode (skip during settings preview)
        ReaderSettings.shared.$readingMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard !(self?.isSettingsPreviewActive ?? false) else { return }
                if mode != .notch {
                    self?.notchController?.hideWithAnimation()
                }
            }
            .store(in: &cancellables)

        // Auto-hide notch after reading finishes
        engine.$isFinished
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard ReaderSettings.shared.readingMode == .notch else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self?.notchController?.hideWithAnimation()
                }
            }
            .store(in: &cancellables)

        engine.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                if isPlaying {
                    guard self?.displaySleepActivity == nil else { return }
                    self?.displaySleepActivity = ProcessInfo.processInfo.beginActivity(
                        options: .idleDisplaySleepDisabled,
                        reason: "RSVP reading playback"
                    )
                } else if let activity = self?.displaySleepActivity {
                    ProcessInfo.processInfo.endActivity(activity)
                    self?.displaySleepActivity = nil
                }
            }
            .store(in: &cancellables)

        // Start automatic update checks after a short launch delay.
        // Uses a direct checkForUpdates() call instead of Sparkle's silent
        // background check so the update window appears without user action.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateManager.shared.startAutomaticChecks()
        }
    }

    @objc private func notchWidgetDidHide() {
        // Notch widget was hidden (notification from NotchWindowController)
    }

    // MARK: - Open With (Finder)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }

        // Only handle supported document types
        guard DocumentReaderFactory.isSupported(url: url) else { return }

        activateMainWindow()

        // Switch to File tab and pass the file URL
        NotificationCenter.default.post(name: .switchToTab, object: SidebarItem.file)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .openFileFromFinder, object: url)
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let icon = NSImage(named: "MenuBarIcon") {
                icon.isTemplate = true
                button.image = icon
            }
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Input tabs
        let textItem = NSMenuItem(title: "Enter Text", action: #selector(switchToText), keyEquivalent: "")
        textItem.image = NSImage(systemSymbolName: "textbox", accessibilityDescription: nil)
        menu.addItem(textItem)

        let urlItem = NSMenuItem(title: "Enter URL", action: #selector(switchToURL), keyEquivalent: "")
        urlItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        menu.addItem(urlItem)

        let fileItem = NSMenuItem(title: "Open File...", action: #selector(openFile), keyEquivalent: "o")
        fileItem.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        menu.addItem(fileItem)

        let areaItem = NSMenuItem(title: "Capture Screen Area", action: #selector(captureScreenArea), keyEquivalent: "a")
        areaItem.keyEquivalentModifierMask = [.command, .shift]
        areaItem.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        menu.addItem(areaItem)

        menu.addItem(NSMenuItem.separator())

        let browserItem = NSMenuItem(title: "Read URL from Browser", action: #selector(readFromBrowser), keyEquivalent: "u")
        browserItem.keyEquivalentModifierMask = [.command, .shift]
        browserItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        menu.addItem(browserItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login
        let loginItem = NSMenuItem(title: "Launch at Startup", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Speed Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { }
        updateLaunchAtLoginMenuItem()
    }

    private func updateLaunchAtLoginMenuItem() {
        if let menu = statusItem.menu,
           let item = menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) }) {
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc func readFromClipboard() {
        guard let clipboardString = NSPasteboard.general.string(forType: .string),
              !clipboardString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        engine.loadText(clipboardString)
        switch ReaderSettings.shared.readingMode {
        case .notch:
            if notchController == nil {
                notchController = NotchWindowController(engine: engine)
            }
            notchController?.startWithCountdown { [weak self] in
                self?.engine.play()
            }
        case .separateWindow:
            separateReaderController.show(engine: engine)
            engine.play()
        case .zen:
            // Same as startInZen: open paused, let the user start playback explicitly.
            zenReaderController.show(engine: engine)
        case .mainWindow:
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.title == "Speed Reader" }) {
                window.makeKeyAndOrderFront(nil)
            }
            engine.play()
        }
    }

    @objc func switchToText() {
        activateMainWindow()
        NotificationCenter.default.post(name: .switchToTab, object: SidebarItem.text)
    }

    @objc func switchToURL() {
        activateMainWindow()
        NotificationCenter.default.post(name: .switchToTab, object: SidebarItem.url)
    }

    @objc func openFile() {
        activateMainWindow()
        NotificationCenter.default.post(name: .switchToTab, object: SidebarItem.file)
        // Small delay so the tab switch lands before the picker opens
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .openFilePicker, object: nil)
        }
    }

    @objc func captureScreenArea() {
        activateMainWindow()
        NotificationCenter.default.post(name: .switchToTab, object: SidebarItem.area)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .captureScreenArea, object: nil)
        }
    }

    @objc func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              BrowserURLReader.isSupported(bundleID: bundleID)
        else { return }
        lastBrowserApp = app
    }

    @objc func readFromBrowser() {
        // Use the last activated browser, or find any running browser as fallback.
        let browserApp = lastBrowserApp ?? NSWorkspace.shared.runningApplications.first(where: {
            guard let id = $0.bundleIdentifier else { return false }
            return BrowserURLReader.isSupported(bundleID: id)
        })
        let result = BrowserURLReader.detect(app: browserApp)

        switch result {
        case .success(let detected):
            activateMainWindow()
            NotificationCenter.default.post(name: .switchToTab, object: SidebarItem.url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: .loadBrowserURL, object: detected.url)
            }

        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "Could not detect browser URL"
            alert.informativeText = error.message
            alert.runModal()
        }
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Speed Reader" || $0.contentView is NSHostingView<ContentView> }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func openSettings() {
        activateMainWindow()
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    // Start reading in the notch widget with optional 3-2-1 countdown
    func startInWidget(text: String, wpm: Int, resumeIndex: Int? = nil, autoPlay: Bool = true, pauseableBlocks: [Int: PauseableBlock] = [:], markdownSource: String? = nil) {
        isSettingsPreviewActive = false
        engine.loadText(text, pauseableBlocks: pauseableBlocks, markdownSource: markdownSource)
        if let resumeIndex { engine.seekTo(resumeIndex) }
        engine.setWPM(wpm)

        if notchController == nil {
            notchController = NotchWindowController(engine: engine)
        }


        if autoPlay {
            notchController?.startWithCountdown { [weak self] in
                self?.engine.play()
            }
        } else {
            notchController?.showPreview()
        }
    }

    // Show notch in preview mode (for settings editing)
    func showNotchPreview() {
        isSettingsPreviewActive = true
        if notchController == nil {
            notchController = NotchWindowController(engine: engine)
        }
        // Load sample text so settings changes (font, color, size) are visible in realtime
        if engine.totalWords == 0 {
            engine.loadText("Speed Reader shows one word at a time using RSVP for faster reading")
        }
        notchController?.showPreview()

    }

    func hideNotchPreview() {
        isSettingsPreviewActive = false
        notchController?.hideWithAnimation()
    }

    // Show separate window in preview mode (for settings editing)
    func showSeparateWindowPreview() {
        if engine.totalWords == 0 {
            engine.loadText("Speed Reader shows one word at a time using RSVP for faster reading")
        }
        separateReaderController.show(engine: engine)
    }

    func hideSeparateWindowPreview() {
        separateReaderController.close()
    }

    // Start reading in separate window
    func startInSeparateWindow(text: String, wpm: Int, resumeIndex: Int? = nil, autoPlay: Bool = true, pauseableBlocks: [Int: PauseableBlock] = [:], markdownSource: String? = nil) {
        engine.loadText(text, pauseableBlocks: pauseableBlocks, markdownSource: markdownSource)
        if let resumeIndex { engine.seekTo(resumeIndex) }
        engine.setWPM(wpm)
        separateReaderController.show(engine: engine)
        if autoPlay {
            engine.play()
        }
    }

    func closeSeparateWindow() {
        separateReaderController.close()
    }

    // Start reading in Zen mode (full-screen distraction-free).
    // Zen always opens paused — user kicks off playback via the Play button (or Space) once the
    // window is in front. `autoPlay` is intentionally ignored here.
    func startInZen(text: String, wpm: Int, title: String? = nil, resumeIndex: Int? = nil, autoPlay: Bool = true, pauseableBlocks: [Int: PauseableBlock] = [:], markdownSource: String? = nil) {
        engine.loadText(text, pauseableBlocks: pauseableBlocks, markdownSource: markdownSource)
        if let resumeIndex { engine.seekTo(resumeIndex) }
        engine.setWPM(wpm)
        zenReaderController.show(engine: engine, title: title)
    }

    func closeZen() {
        zenReaderController.close()
    }

    /// Bring whichever external reader is currently active to front. Notch is always visible
    /// so it's a no-op there.
    func bringExternalReaderToFront() {
        switch ReaderSettings.shared.readingMode {
        case .separateWindow:
            separateReaderController.bringToFront()
        case .zen:
            zenReaderController.bringToFront()
        case .notch, .mainWindow:
            break
        }
    }

    func stopExternalReader() {
        switch ReaderSettings.shared.readingMode {
        case .separateWindow:
            separateReaderController.close()
        case .zen:
            zenReaderController.close()
        case .notch:
            notchController?.hideWithAnimation()
        case .mainWindow:
            break
        }
    }

    func showAboutWindow() {
        if let aboutWindow, aboutWindow.isVisible {
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }

        let aboutView = AboutView()
        let hostingView = NSHostingView(rootView: aboutView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "About Speed Reader"
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.aboutWindow = window
    }
}

// MARK: - NSMenuDelegate
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let reading = engine.isPlaying
        let disabledActions: [Selector] = [
            #selector(switchToText),
            #selector(switchToURL),
            #selector(openFile),
            #selector(captureScreenArea),
            #selector(openSettings)
        ]
        for item in menu.items {
            if let action = item.action, disabledActions.contains(action) {
                item.isEnabled = !reading
            }
        }
    }
}
