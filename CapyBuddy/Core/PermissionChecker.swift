import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

enum PermissionChecker {

    // MARK: - Accessibility (Pro-only)
    //
    // The MAS build of CapyBuddy uses Carbon `RegisterEventHotKey` for its
    // global hotkey (no permission needed) and does not call any AX APIs.
    // Accessibility is only requested in the Pro target — for SpaceShortcut's
    // CGEventTap-based chord listener and for the snap-to-element overlay in
    // Screenshot — both of which the App Store reviewer would reject under
    // guideline 2.4.5. Gating these helpers behind `CAPYBUDDY_DIRECT` keeps the
    // MAS binary from referencing AX entirely.

    #if CAPYBUDDY_DIRECT
    static func isAccessibilityGranted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    #endif

    // MARK: - Screen Recording

    static func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Microphone

    /// True if the user has granted microphone access to this app. This is
    /// queried via AVCaptureDevice, which does NOT cache across the
    /// process lifetime — it re-reads TCC each call (unlike
    /// CGPreflightScreenCaptureAccess which infamously caches).
    static func isMicrophoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Request microphone access. If status is `.notDetermined`, this
    /// triggers the system prompt. Completion fires on whatever queue the
    /// AV machinery feels like — caller is responsible for hopping back to
    /// MainActor.
    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Permission model
//
// A single source of truth for the macOS privacy permissions CapyBuddy
// features depend on. Before this existed, every feature reached into
// `PermissionChecker` directly and hand-rolled its own banner copy, grant
// button, and re-check logic — three slightly different spellings of the
// same idea. `Permission` centralizes the user-facing title, the "why we
// need it" rationale, the live grant check, and the action that takes the
// user somewhere they can grant it. Onboarding and the Settings
// "Permissions" section are both driven off this enum.

/// A macOS privacy permission one or more features can require.
enum Permission: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility
    case microphone

    var id: String { rawValue }

    /// Short human title, e.g. shown as the row heading.
    var title: String {
        switch self {
        case .screenRecording: return String(localized: "Screen Recording")
        case .accessibility:    return String(localized: "Accessibility")
        case .microphone:       return String(localized: "Microphone")
        }
    }

    /// One-sentence "why CapyBuddy asks for this" rationale.
    var rationale: String {
        switch self {
        case .screenRecording:
            return String(localized: "Lets CapyBuddy capture screen pixels for screenshots and screen recording.")
        case .accessibility:
            return String(localized: "Lets CapyBuddy read global keyboard shortcuts (Space Shortcut, recording hotkey) and snap selections to on-screen UI elements.")
        case .microphone:
            return String(localized: "Lets CapyBuddy record your voice alongside the screen when microphone capture is turned on.")
        }
    }

    var systemSymbol: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility:    return "accessibility"
        case .microphone:       return "mic"
        }
    }

    /// Live grant status, re-queried each call (do not cache long-term —
    /// the user can flip these in System Settings at any time).
    var isGranted: Bool {
        switch self {
        case .screenRecording:
            return PermissionChecker.isScreenRecordingGranted()
        case .microphone:
            return PermissionChecker.isMicrophoneGranted()
        case .accessibility:
            #if CAPYBUDDY_DIRECT
            return PermissionChecker.isAccessibilityGranted()
            #else
            // Accessibility is never used in the App Store build.
            return true
            #endif
        }
    }

    /// Open the relevant System Settings privacy pane so the user can
    /// grant the permission themselves.
    func openSystemSettings() {
        switch self {
        case .screenRecording: PermissionChecker.openScreenRecordingSettings()
        case .microphone:       PermissionChecker.openMicrophoneSettings()
        case .accessibility:
            #if CAPYBUDDY_DIRECT
            PermissionChecker.openAccessibilitySettings()
            #endif
        }
    }

    /// Kick off the most useful "grant" action for this permission.
    ///
    /// Screen Recording and Microphone have native request APIs that, on
    /// first call, register the app in the privacy list and surface the
    /// system's own consent sheet — so we call those. Accessibility has no
    /// silent request path (the system only ever points users at the
    /// pane), so we open System Settings directly. After any of these the
    /// caller should re-read `isGranted` to refresh its UI.
    @MainActor
    func request(completion: (@MainActor (Bool) -> Void)? = nil) {
        switch self {
        case .screenRecording:
            PermissionChecker.requestScreenRecording()
            // The preflight cache lies until next launch; surface the pane
            // too so the user has a reliable place to flip the toggle.
            openSystemSettings()
            completion?(isGranted)
        case .microphone:
            PermissionChecker.requestMicrophone { granted in
                Task { @MainActor in
                    if !granted { self.openSystemSettings() }
                    completion?(granted)
                }
            }
        case .accessibility:
            openSystemSettings()
            completion?(isGranted)
        }
    }
}
