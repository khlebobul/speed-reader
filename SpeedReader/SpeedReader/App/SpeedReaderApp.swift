import SwiftUI

@main
struct SpeedReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1050, idealWidth: 1050, minHeight: 650, idealHeight: 650)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }

            // About in app menu (Speed Reader → About Speed Reader)
            CommandGroup(replacing: .appInfo) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    AppDelegate.shared.showAboutWindow()
                } label: {
                    Label("About Speed Reader", systemImage: "info.circle")
                }

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                } label: {
                    Label("Speed Reader Guide", systemImage: "book")
                }

                Divider()

                Button {
                    UpdateManager.shared.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!UpdateManager.shared.canCheckForUpdates)
            }

            // Settings in app menu (Speed Reader → Settings)
            CommandGroup(replacing: .appSettings) {
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Settings...", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
