import AppKit
import Sparkle

/// Custom Sparkle user driver that delegates most UI to SPUStandardUserDriver
/// but replaces simple alert dialogs with custom windows that have a centered app icon.
final class SparkleUserDriver: NSObject, SPUUserDriver {

    private let standardDriver: SPUStandardUserDriver

    init(hostBundle: Bundle, delegate: SPUStandardUserDriverDelegate?) {
        self.standardDriver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: delegate)
    }

    // MARK: - Custom alert dialogs (centered icon)

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        SparkleAlert.show(
            title: "Unable to Check For Updates",
            message: error.localizedDescription,
            acknowledgement: acknowledgement
        )
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let message = (error as NSError).localizedRecoverySuggestion
            ?? (error as NSError).localizedDescription
        SparkleAlert.show(
            title: "You're Up to Date",
            message: message,
            acknowledgement: acknowledgement
        )
    }

    // MARK: - Forwarded to standard driver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standardDriver.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standardDriver.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standardDriver.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        standardDriver.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        standardDriver.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        standardDriver.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standardDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standardDriver.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        standardDriver.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standardDriver.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standardDriver.showReady(toInstallAndRelaunch: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standardDriver.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standardDriver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        standardDriver.showUpdateInFocus()
    }

    func dismissUpdateInstallation() {
        standardDriver.dismissUpdateInstallation()
    }
}

// MARK: - Custom Alert Window

/// Presents a modal alert window with a centered app icon.
enum SparkleAlert {

    static func show(title: String, message: String, acknowledgement: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 0),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        // App icon
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        contentView.addSubview(iconView)

        // Title
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        // Message
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(messageLabel)

        // OK button — system default styling (accent color + proper contrast)
        let button = NSButton(title: "OK", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)

        let padding: CGFloat = 24

        NSLayoutConstraint.activate([
            // Icon
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding + 12),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            // Title
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            // Message
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            messageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            // Button
            button.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 20),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            button.heightAnchor.constraint(equalToConstant: 32),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
        ])

        window.contentView = contentView
        window.center()

        // Button action — close window and acknowledge
        button.target = window
        button.action = #selector(NSWindow.close)

        // Call acknowledgement when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { notification in
            NotificationCenter.default.removeObserver(notification, name: NSWindow.willCloseNotification, object: window)
            acknowledgement()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
