//
//  SettingsWindowController.swift
//  SpeedReader
//
//  Created on 20.02.2026.
//

import AppKit
import SwiftUI

class SettingsWindowController {
    private var window: NSWindow?
    private var windowObserver: NSObjectProtocol?

    func show() {
        // If window already exists, bring it to front
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create new window
        let settingsView = SettingsView()
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsConstants.width, height: SettingsConstants.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        // Handle window close - store observer to remove later
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowClose()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        handleWindowClose()
        window?.close()
    }

    private func handleWindowClose() {
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }
        window = nil
    }
}
