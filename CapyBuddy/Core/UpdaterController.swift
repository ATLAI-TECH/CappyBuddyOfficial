#if CAPYBUDDY_DIRECT

import AppKit
#if canImport(Sparkle)
import Sparkle

extension Notification.Name {
    /// Posted whenever a silent background check changes whether an update is
    /// available. MenuBarManager listens to redraw the green badge and the
    /// "new version" row.
    static let capyBuddyUpdateAvailabilityChanged =
        Notification.Name("capyBuddyUpdateAvailabilityChanged")
}

@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate {

    static let shared = UpdaterController()

    private var controller: SPUStandardUpdaterController!
    private var dailyTimer: Timer?

    /// Last time our silent check ran, so a relaunch within 24h doesn't
    /// re-check immediately and we resume the daily cadence where it left off.
    private let lastCheckKey = "app.lastSilentUpdateCheck"
    private let checkInterval: TimeInterval = 86_400  // once per day

    /// True when the most recent silent check found a newer version. Read by
    /// MenuBarManager to draw the green badge and the "new version" menu row.
    private(set) var updateAvailable = false
    /// Marketing version of the available update (e.g. "2.0.1"), if any.
    private(set) var availableVersion: String?

    private override init() {
        super.init()
        // `startingUpdater: true` boots Sparkle's machinery. We pass ourselves
        // as the updater delegate so silent checks report back via
        // `didFindValidUpdate` / `updaterDidNotFindUpdate`.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // We drive the cadence ourselves with a silent daily check (see
        // `scheduleDailyChecks`) so a found update shows a passive badge rather
        // than Sparkle's automatic interrupting dialog. Turn off Sparkle's own
        // scheduler to avoid a second, popup-driven cadence. (SUEnableAutomatic-
        // Checks=true in Info.plist still suppresses the first-run permission
        // prompt — the user is treated as having opted in.)
        controller.updater.automaticallyChecksForUpdates = false
        scheduleDailyChecks()
    }

    /// User-initiated check — shows Sparkle's standard update UI immediately
    /// (the "A new version is available" dialog, progress, install & relaunch).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: - Silent daily cadence

    private func scheduleDailyChecks() {
        // Catch up right after launch if a day (or more) has passed since the
        // last silent check; otherwise wait out the remainder of the day.
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        let elapsed = last.map { Date().timeIntervalSince($0) } ?? checkInterval
        let firstDelay = elapsed >= checkInterval ? 10 : (checkInterval - elapsed)

        DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay) { [weak self] in
            self?.silentCheck()
        }

        // Repeat daily thereafter. Added to `.common` so it keeps firing even
        // while menus/other tracking run loops are active.
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.silentCheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    /// Checks the appcast without showing any UI. Results arrive via the
    /// delegate callbacks below.
    private func silentCheck() {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        controller.updater.checkForUpdateInformation()
    }

    private func setAvailability(_ available: Bool, version: String?) {
        updateAvailable = available
        availableVersion = version
        NotificationCenter.default.post(
            name: .capyBuddyUpdateAvailabilityChanged, object: nil
        )
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.setAvailability(true, version: version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.setAvailability(false, version: nil) }
    }
}

#else

// Sparkle SwiftPM package not linked — keep call sites compiling. Mirrors the
// real controller's surface so MenuBarManager (gated on CAPYBUDDY_DIRECT) builds
// regardless of whether Sparkle is present.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()
    private init() {}
    private(set) var updateAvailable = false
    private(set) var availableVersion: String?
    func checkForUpdates() {
        NSLog("[CapyBuddy] UpdaterController: Sparkle package not linked; skipping update check.")
    }
}

#endif

#endif
