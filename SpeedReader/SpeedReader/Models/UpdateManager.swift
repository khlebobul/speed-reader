import Foundation
import Sparkle
import Combine

/// Manages Sparkle auto-updates.
/// Uses a custom timer instead of Sparkle's built-in silent checks so that
/// automatic checks show the update window just like a manual "Check for Updates…".
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    private(set) var updater: SPUUpdater!

    @Published var canCheckForUpdates = false

    private let userDriver: SparkleUserDriver
    private var timerCancellable: AnyCancellable?
    private var launchCheckDone = false

    private override init() {
        userDriver = SparkleUserDriver(hostBundle: .main, delegate: nil)
        super.init()

        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: nil
        )

        try? updater.start()

        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    // MARK: - Public API

    /// User-initiated check (menu / settings).
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Performs the first check after launch and sets up a repeating timer.
    func startAutomaticChecks() {
        guard updater.automaticallyChecksForUpdates else { return }

        let interval = max(updater.updateCheckInterval, 3600)

        // First check runs immediately; the caller already delays before calling us
        runBackgroundCheck()

        // Repeating timer for subsequent checks
        timerCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.runBackgroundCheck()
            }
    }

    // MARK: - Private

    /// Performs a silent background check. The Sparkle user driver will
    /// automatically show the update window if a new version is found,
    /// without displaying a "Checking for Updates…" or "You're Up to Date" UI.
    private func runBackgroundCheck() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }
}
