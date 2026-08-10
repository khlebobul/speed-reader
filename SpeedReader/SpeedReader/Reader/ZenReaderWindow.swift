//
//  ZenReaderWindow.swift
//  SpeedReader
//
//  Distraction-free reader window. Standard resizable NSWindow; F toggles native fullscreen.
//

import AppKit
import SwiftUI

class ZenReaderWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingView: NSHostingView<ZenReaderView>?
    private weak var engine: RSVPEngine?
    private var keyMonitor: Any?

    private let defaultSize = NSSize(width: 900, height: 700)
    private let minSize = NSSize(width: 700, height: 500)

    func show(engine: RSVPEngine, title: String? = nil) {
        self.engine = engine

        if let window = window {
            if let title { window.title = title }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = ZenReaderView(
            engine: engine,
            onClose: { [weak self] in self?.dismissWithAnimation() }
        )
        let hosting = NSHostingView(rootView: view)
        self.hostingView = hosting

        let initialFrame = NSRect(origin: .zero, size: defaultSize)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.title = title ?? "Zen Mode"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = minSize
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.appearance = ReaderSettings.shared.themeMode.nsAppearance
        // Zen is fullscreen-only — exiting fullscreen produces a 900×700 windowed
        // layout that breaks the article-screen frame. Hide the green/zoom button
        // and the miniaturize button so users can't toggle out by accident.
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.center()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window

        installKeyMonitor()

        // Open Zen straight into native fullscreen on its own Space.
        // Defer one runloop tick so AppKit finishes initial layout before transitioning.
        DispatchQueue.main.async {
            window.toggleFullScreen(nil)
        }
    }

    func close() {
        dismissWithAnimation()
    }

    func bringToFront() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismissWithAnimation() {
        guard let window = window else { return }
        engine?.pause()
        cleanup(window: window)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        engine?.pause()
        // Drop our reference; the window has already been ordered out by the close button.
        guard let window = window else { return }
        cleanup(window: window, alreadyClosed: true)
    }

    // Zen is fullscreen-only. The F shortcut is stripped and the zoom/miniaturize
    // buttons are hidden, but a system shortcut (e.g. Cmd+Ctrl+F) can still drop the
    // user out of fullscreen. Bounce them straight back so a resizable windowed state
    // is never reachable — Zen has no usable layout outside fullscreen.
    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = self.window else { return }
        DispatchQueue.main.async { [weak window] in
            window?.toggleFullScreen(nil)
        }
    }

    // MARK: - Cleanup

    private func cleanup(window: NSWindow, alreadyClosed: Bool = false) {
        removeKeyMonitor()
        window.delegate = nil
        window.contentView = nil
        if !alreadyClosed {
            window.orderOut(nil)
            window.close()
        }
        hostingView = nil
        self.window = nil
        NotificationCenter.default.post(name: .externalReaderDidClose, object: nil)
    }

    // MARK: - Key Monitor

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let engine = self.engine,
                  let window = self.window,
                  event.window === window else { return event }

            let shift = event.modifierFlags.contains(.shift)

            switch event.keyCode {
            case 53: // Esc
                self.dismissWithAnimation()
                return nil
            case 49: // Space
                engine.togglePlayPause()
                return nil
            case 123: // Left arrow
                if shift {
                    engine.seekByWords(-10)
                } else {
                    engine.previousWord()
                }
                return nil
            case 124: // Right arrow
                if shift {
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
            case 115: // Home
                engine.seekTo(0)
                return nil
            case 119: // End
                engine.seekTo(engine.totalWords - 1)
                return nil
            case 15: // R
                engine.restart()
                return nil
            case 37: // L
                ReaderSettings.shared.zenLoop.toggle()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

}
