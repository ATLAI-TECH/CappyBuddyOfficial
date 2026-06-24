import AppKit
import Combine
import SwiftUI

@MainActor
final class ScreenshotFeature: Feature {
    let id = "screenshot"
    let displayName = String(localized: "Screenshot")
    let iconSystemName = "camera.viewfinder"
    let summary = String(localized: "Capture a region of the screen with a global hotkey, then annotate, copy, save, or pin it.")
    let requiresScreenRecording = true

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true

    let manager = ScreenshotManager()
    let hotkeyStore = HotkeyConfigStore.shared
    private let hotkeyTap: HotkeyTap
    private var hotkeyObservation: AnyCancellable?

    init() {
        self.hotkeyTap = HotkeyTap(config: HotkeyConfigStore.shared.current)
    }

    var isHotkeyActive: Bool { hotkeyTap.isActive }

    func start() {
        // No permission prompt here. Screen Recording is requested lazily
        // the first time the user actually triggers a capture (see
        // `ScreenshotManager.captureRegion()`), so enabling the feature —
        // or simply launching the app with Screenshot on by default —
        // never surprises the user with a system dialog.
        hotkeyTap.onTrigger = { [weak self] in
            self?.manager.captureRegion()
        }
        if !hotkeyTap.start() {
            NSLog("[CapyBuddy] Screenshot: hotkey registration failed (combo may be in use by the system or another app).")
        }

        hotkeyObservation = hotkeyStore.$current.sink { [weak self] new in
            self?.hotkeyTap.config = new
        }
    }

    func stop() {
        hotkeyObservation?.cancel()
        hotkeyObservation = nil
        hotkeyTap.stop()
    }

    @discardableResult
    func restartHotkeyTap() -> Bool {
        hotkeyTap.stop()
        return hotkeyTap.start()
    }

    func makeSettingsView() -> AnyView {
        AnyView(ScreenshotSettingsView(feature: self))
    }
}
