import AppKit
import SwiftUI

// MARK: - Onboarding window controller
//
// Shown once, on the very first launch (driven by `AppDelegate.firstLaunchKey`).
// Replaces the old behaviour of dumping the user straight into the Settings
// window. The goal is a calm, non-coercive welcome:
//   • introduce what CapyBuddy is,
//   • show — but never force — the privacy permissions some tools need,
//   • let the user grant only what they want, right from here.
//
// Nothing on this screen requests a permission automatically. Every grant is
// an explicit click, matching macOS's own "ask in context" guidance and the
// product goal of "no permission prompts at install / first launch".

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// Opens (or re-uses) the Settings window, optionally pre-selecting a
    /// feature's tab (e.g. Space Shortcut's "Configure apps…"). Wired from
    /// AppDelegate so OnboardingView never reaches into app globals.
    private let openSettings: (String?) -> Void

    init(openSettings: @escaping (String?) -> Void) {
        self.openSettings = openSettings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to CapyBuddy"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let root = OnboardingView(
            openSettings: { [weak self] id in self?.openSettings(id) },
            done: { [weak self] in self?.close() }
        )
        window.contentViewController = NSHostingController(rootView: root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        // A menu-bar (accessory / LSUIElement) app can't make a window key
        // while it has no Dock icon — macOS won't let a window of a Dock-less
        // app become selected — so the welcome window opens hidden behind
        // other apps. The reliable fix is to temporarily promote to a regular
        // app (which shows a Dock icon), bring the window front, and drop back
        // to accessory once it closes. See `windowWillClose`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        // Let the policy change settle one runloop tick before ordering the
        // window front, otherwise the activation can still land behind the
        // frontmost app.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Welcome window dismissed — return to menu-bar-only mode (no Dock
        // icon). Existing windows like Settings stay visible; the app just
        // leaves the Dock and Cmd-Tab again.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Onboarding tour
//
// A short, paged walkthrough rather than one static screen. Each step is a
// `TourPage`; the steps are computed once from what this build actually
// compiles (the App Store build drops the Accessibility / Recording tools,
// so their category pages simply don't appear). Animation is all native
// SwiftUI — `symbolEffect`, `PhaseAnimator`, staggered `.onAppear` entrances,
// and `matchedGeometryEffect` for the progress dots — so there are no extra
// dependencies and nothing to maintain beyond this file.

private struct OnboardingView: View {
    let openSettings: (String?) -> Void
    let done: () -> Void

    /// The ordered steps for this build. Hero/other features not compiled in
    /// are filtered out below, so we never show an empty page or advertise a
    /// tool the user can't actually use.
    private let pages: [TourPage]

    @State private var index = 0
    /// +1 when moving forward, -1 when moving back. Drives the asymmetric
    /// slide transition so pages slide in from the side you're heading toward.
    @State private var direction = 1

    init(openSettings: @escaping (String?) -> Void, done: @escaping () -> Void) {
        self.openSettings = openSettings
        self.done = done

        let compiled = Set(FeatureRegistry.shared.features.map(\.id))
        let heroes = HeroFeature.all.filter { compiled.contains($0.id) }
        let others = TourFeature.others.filter { compiled.contains($0.id) }

        var pages: [TourPage] = [.welcome]
        pages += heroes.map(TourPage.hero)
        if !others.isEmpty { pages.append(.others(others)) }
        pages.append(.done)
        self.pages = pages
    }

    private var page: TourPage { pages[index] }
    private var isLast: Bool { index == pages.count - 1 }

    var body: some View {
        ZStack {
            // Soft accent wash that cross-fades to each page's colour — the
            // background carries the "mood" of the step you're on.
            page.accent.opacity(0.10)
                .background(.background)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.45), value: index)

            VStack(spacing: 0) {
                topBar

                // Keyed by index so SwiftUI tears down + rebuilds the page on
                // every step: that re-fires each page's `.onAppear` entrance
                // animation and the slide transition.
                pageContent
                    .id(index)
                    .transition(.asymmetric(
                        insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity)
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
            }
        }
        .frame(width: 580, height: 640)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Spacer()
            if !isLast {
                Button("Skip", action: done)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .frame(height: 40)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .welcome:
            WelcomePage()
        case .hero(let hero):
            HeroFeaturePage(hero: hero, openSettings: openSettings)
        case .others(let features):
            OthersPage(features: features)
        case .done:
            DonePage()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            // Progress dots — the active one stretches into a pill and the
            // accent colour slides between them via matchedGeometryEffect.
            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? page.accent : Color.secondary.opacity(0.25))
                        .frame(width: i == index ? 22 : 7, height: 7)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: index)
                }
            }

            HStack {
                Button("Back") { go(-1) }
                    .controlSize(.large)
                    .opacity(index == 0 ? 0 : 1)
                    .disabled(index == 0)

                Spacer()

                Button(isLast ? "Get Started" : "Next") {
                    isLast ? done() : go(1)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(page.accent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard pages.indices.contains(next) else { return }
        direction = delta
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            index = next
        }
    }
}

// MARK: - Pages

/// One step of the tour. `hero` is a single flagship tool with its own
/// animation, hotkey, and permission; `others` is the catch-all grid.
private enum TourPage {
    case welcome
    case hero(HeroFeature)
    case others([TourFeature])
    case done

    var accent: Color {
        switch self {
        case .welcome:        return Color.accentColor
        case .hero(let h):    return h.accent
        case .others:         return .blue
        case .done:           return Color.accentColor
        }
    }
}

/// Welcome — the app icon breathes/floats and the tagline fades up.
private struct WelcomePage: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            PhaseAnimator([-6.0, 6.0]) { offset in
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .offset(y: offset)
            } animation: { _ in .easeInOut(duration: 1.9) }
            .scaleEffect(appeared ? 1 : 0.7)
            .opacity(appeared ? 1 : 0)

            VStack(spacing: 10) {
                Text("Welcome to CapyBuddy")
                    .font(.system(size: 30, weight: .bold))
                Text("Your friendly Mac companion — a menu-bar toolbox of small, handy utilities, all in one place.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)

            Spacer()
        }
        .padding(.horizontal, 40)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.05)) {
                appeared = true
            }
        }
    }
}

/// A flagship feature — a bespoke animation up top, the default hotkey shown
/// as keycaps, a few "here's what you can do" bullets, an optional config
/// button, and a live permission grant card.
private struct HeroFeaturePage: View {
    let hero: HeroFeature
    let openSettings: (String?) -> Void
    @State private var appeared = false

    /// Read live from the relevant hotkey store so the keycaps reflect the
    /// user's actual binding (defaults: Screenshot ⌃1, Recording ⌃2).
    private var hotkeyText: String? {
        switch hero.hotkey {
        case .screenshot:
            return HotkeyConfigStore.shared.current.displayString
        case .recording:
            #if CAPYBUDDY_DIRECT
            return RecordingHotkeyStore.shared.current.displayString
            #else
            return nil
            #endif
        case .none:
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HeroAnimationView(kind: hero.animation, accent: hero.accent)
                    .frame(height: 132)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.85)

                VStack(spacing: 6) {
                    Text(hero.title)
                        .font(.system(size: 26, weight: .bold))
                    Text(hero.tagline)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)

                if let combo = hotkeyText {
                    HotkeyHint(combo: combo)
                        .opacity(appeared ? 1 : 0)
                }

                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(hero.bullets.enumerated()), id: \.offset) { i, bullet in
                        HStack(spacing: 12) {
                            Image(systemName: bullet.icon)
                                .font(.body)
                                .foregroundStyle(hero.accent)
                                .frame(width: 24)
                            Text(bullet.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(x: appeared ? 0 : 24)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8)
                            .delay(0.15 + Double(i) * 0.08), value: appeared)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)

                if let config = hero.configButton {
                    Button { openSettings(config.featureID) } label: {
                        Label(config.label, systemImage: "slider.horizontal.3")
                    }
                    .controlSize(.large)
                }

                if let permission = hero.permission {
                    PermissionCard(permission: permission)
                        .frame(maxWidth: 420)
                        .opacity(appeared ? 1 : 0)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.top, 2)
            .padding(.bottom, 14)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) { appeared = true }
        }
    }
}

/// "Press [⌃][1]" — splits the combo's display string into individual keycaps.
private struct HotkeyHint: View {
    let combo: String

    var body: some View {
        HStack(spacing: 6) {
            Text("Press")
                .foregroundStyle(.secondary)
            ForEach(Array(combo.enumerated()), id: \.offset) { _, ch in
                Keycap(label: String(ch))
            }
        }
        .font(.callout)
    }
}

/// A little keyboard-key chip used by the hotkey hint and the Space animation.
private struct Keycap: View {
    let label: String
    var wide = false

    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .frame(minWidth: wide ? 130 : 26)
            .padding(.horizontal, wide ? 24 : 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35))
            )
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}

/// Wraps the shared `PermissionStatusRow` (Grant / live status) in a card.
/// Same component Settings uses, so status and behaviour stay identical.
private struct PermissionCard: View {
    let permission: Permission

    var body: some View {
        PermissionStatusRow(permission: permission, usedByFeatures: [])
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )
    }
}

// MARK: Hero animations

private struct HeroAnimationView: View {
    let kind: HeroAnimationKind
    let accent: Color

    var body: some View {
        switch kind {
        case .screenshot:    ScreenshotAnimation(accent: accent)
        case .recording:     RecordingAnimation(accent: accent)
        case .spaceShortcut: SpaceShortcutAnimation(accent: accent)
        }
    }
}

/// Screenshot — a "marching ants" selection rectangle around a viewfinder.
private struct ScreenshotAnimation: View {
    let accent: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accent.opacity(0.08))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [8, 6], dashPhase: phase))
                .foregroundStyle(accent)
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 46))
                .foregroundStyle(accent)
        }
        .frame(width: 210, height: 124)
        .onAppear {
            withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                phase = -28
            }
        }
    }
}

/// Screen recording — a solid red dot with an outward-pulsing ring.
private struct RecordingAnimation: View {
    let accent: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.55), lineWidth: 2)
                .frame(width: 74, height: 74)
                .scaleEffect(pulse ? 1.9 : 1)
                .opacity(pulse ? 0 : 0.7)
            Circle()
                .fill(accent)
                .frame(width: 56, height: 56)
                .shadow(color: accent.opacity(0.5), radius: pulse ? 10 : 4)
        }
        .frame(height: 124)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Space Shortcut — apps spring up while the space bar is held down.
private struct SpaceShortcutAnimation: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 18) {
            PhaseAnimator([false, true]) { shown in
                HStack(spacing: 16) {
                    ForEach(["safari", "envelope.fill", "message.fill"], id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 26))
                            .foregroundStyle(accent)
                            .scaleEffect(shown ? 1 : 0.4)
                            .opacity(shown ? 1 : 0.2)
                            .offset(y: shown ? 0 : 14)
                    }
                }
            } animation: { _ in .spring(response: 0.6, dampingFraction: 0.55) }

            PhaseAnimator([false, true]) { pressed in
                Keycap(label: "space", wide: true)
                    .scaleEffect(pressed ? 0.95 : 1)
                    .brightness(pressed ? -0.04 : 0)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(accent, lineWidth: 2)
                            .opacity(pressed ? 1 : 0)
                    )
            } animation: { _ in .easeInOut(duration: 0.9) }
        }
        .frame(height: 124)
    }
}

/// "And more tools" — the remaining permission-free utilities as a list that
/// slides in row by row.
private struct OthersPage: View {
    let features: [TourFeature]
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.blue)
                    .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                    .frame(height: 48)
                Text("And more tools")
                    .font(.system(size: 24, weight: .bold))
                Text("These all work right away — no permissions needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 4)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)

            ScrollView {
                VStack(spacing: 9) {
                    ForEach(Array(features.enumerated()), id: \.element.id) { i, feature in
                        SimpleFeatureRow(feature: feature)
                            .opacity(appeared ? 1 : 0)
                            .offset(x: appeared ? 0 : 24)
                            .animation(.spring(response: 0.5, dampingFraction: 0.82)
                                .delay(0.1 + Double(i) * 0.06), value: appeared)
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 20)
                .padding(.bottom, 10)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
        }
    }
}

private struct SimpleFeatureRow: View {
    let feature: TourFeature

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: feature.icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.name)
                    .font(.callout.weight(.semibold))
                Text(feature.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }
}

/// Done — an arrow nudges up toward the menu-bar item so the user knows
/// where CapyBuddy lives from now on.
private struct DonePage: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            PhaseAnimator([0.0, -12.0]) { dy in
                Image(systemName: "arrow.up")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .offset(y: dy)
            } animation: { _ in .easeInOut(duration: 0.85) }
            .opacity(appeared ? 1 : 0)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                .scaleEffect(appeared ? 1 : 0.5)

            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.system(size: 28, weight: .bold))
                Text("Find CapyBuddy in your menu bar, up at the top-right. Click its icon any time to reach every tool and open Settings.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            Spacer()
        }
        .padding(.horizontal, 40)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

// MARK: - Curated catalogue
//
// Kept here (rather than derived from the registry) so we control ordering,
// copy, icons, and the bespoke animations. Heroes get a full page each; the
// rest share the "And more tools" page. Both lists are filtered against the
// compiled feature set in `OnboardingView.init`, keyed on the real
// `Feature.id`, so the App Store build never advertises a tool it lacks.

private enum HeroAnimationKind { case screenshot, recording, spaceShortcut }

/// Which hotkey store (if any) a hero page reads its keycaps from.
private enum HotkeyKind { case screenshot, recording, none }

private struct HeroFeature: Identifiable {
    let id: String          // matches `Feature.id`
    let accent: Color
    let title: LocalizedStringKey
    let tagline: LocalizedStringKey
    let animation: HeroAnimationKind
    let hotkey: HotkeyKind
    let bullets: [Bullet]
    let permission: Permission?
    let configButton: ConfigButton?

    struct Bullet { let icon: String; let text: LocalizedStringKey }
    struct ConfigButton { let label: LocalizedStringKey; let featureID: String }

    static let all: [HeroFeature] = {
        var heroes: [HeroFeature] = [
            HeroFeature(
                id: "screenshot",
                accent: .orange,
                title: "Screenshot",
                tagline: "Capture any region of your screen.",
                animation: .screenshot,
                hotkey: .screenshot,
                bullets: [
                    Bullet(icon: "pencil.tip.crop.circle", text: "Annotate — arrows, text, shapes, blur"),
                    Bullet(icon: "pin.fill", text: "Pin it to float on top of every window"),
                    Bullet(icon: "doc.on.doc", text: "Copy or save it in a single keystroke"),
                ],
                permission: .screenRecording,
                configButton: nil
            ),
        ]
        #if CAPYBUDDY_DIRECT
        heroes.append(
            HeroFeature(
                id: "recording",
                accent: .red,
                title: "Screen Recording",
                tagline: "Record your screen straight to a video.",
                animation: .recording,
                hotkey: .recording,
                bullets: [
                    Bullet(icon: "rectangle.dashed", text: "Full screen, a window, or a dragged region"),
                    Bullet(icon: "mic.fill", text: "Optional system audio and microphone"),
                    Bullet(icon: "film", text: "Trim or re-speed it right after with Video Editor"),
                ],
                permission: .screenRecording,
                configButton: nil
            )
        )
        heroes.append(
            HeroFeature(
                id: "spacebuddy",
                accent: .indigo,
                title: "Space Shortcut",
                tagline: "Hold Space, then tap a key.",
                animation: .spaceShortcut,
                hotkey: .none,
                bullets: [
                    Bullet(icon: "bolt.fill", text: "Launch or focus any app instantly — no mouse"),
                    Bullet(icon: "keyboard", text: "Bind any app to a key, e.g. Space + S → Safari"),
                ],
                permission: .accessibility,
                configButton: ConfigButton(label: "Choose apps…", featureID: "spacebuddy")
            )
        )
        #endif
        return heroes
    }()
}

private struct TourFeature: Identifiable {
    let id: String          // matches `Feature.id`
    let icon: String
    let name: LocalizedStringKey
    let blurb: LocalizedStringKey

    /// The non-flagship, permission-free tools shown on the "And more" page.
    static let others: [TourFeature] = [
        TourFeature(id: "clipboard", icon: "doc.on.clipboard",
                    name: "Clipboard",
                    blurb: "A history of recent copies so you can paste anything from earlier."),
        TourFeature(id: "archive", icon: "archivebox",
                    name: "Compressor",
                    blurb: "Compress and extract zip, tar, tar.gz, and gz archives."),
        TourFeature(id: "qrCode", icon: "qrcode",
                    name: "QR Code",
                    blurb: "Generate styled QR codes — colors, shapes, a logo, then save or copy."),
        TourFeature(id: "pictureConvert", icon: "photo.on.rectangle.angled",
                    name: "Picture Converter",
                    blurb: "Convert between PNG, JPEG, HEIC, AVIF, and more by drag-and-drop."),
        TourFeature(id: "videoEditor", icon: "film",
                    name: "Video Editor",
                    blurb: "Trim, crop, mute, or re-speed a video clip and export it."),
        TourFeature(id: "caffeine", icon: "cup.and.saucer",
                    name: "Keep Awake",
                    blurb: "Stop your Mac from sleeping or dimming for a chosen duration."),
        TourFeature(id: "systemMonitor", icon: "cpu",
                    name: "System Monitor",
                    blurb: "A menu-bar readout of live CPU, memory, and more."),
        TourFeature(id: "pictureEdit", icon: "wand.and.stars.inverse",
                    name: "Picture Editor",
                    blurb: "Crop, rotate, resize, recolor, watermark, or remove the background."),
    ]
}

// MARK: - Reusable permission overview
//
// Used both by the onboarding window and the Settings → General
// "Permissions" section, so the two surfaces stay in lockstep.

struct PermissionsOverview: View {
    @ObservedObject private var registry = FeatureRegistry.shared

    /// Permissions that exist in THIS build. The App Store build never
    /// compiles the Accessibility / Recording features, so it only shows
    /// Screen Recording.
    private var permissions: [Permission] {
        #if CAPYBUDDY_DIRECT
        return [.screenRecording, .accessibility, .microphone]
        #else
        return [.screenRecording]
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(permissions.enumerated()), id: \.element.id) { index, permission in
                    PermissionStatusRow(
                        permission: permission,
                        usedByFeatures: featureNames(needing: permission)
                    )
                    if index != permissions.count - 1 {
                        Divider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )
        }
    }

    private func featureNames(needing permission: Permission) -> [String] {
        registry.features
            .filter { $0.requiredPermissions.contains(permission) }
            .map(\.displayName)
    }
}

/// One row: icon + title + rationale + "Used by …" + a live status badge
/// that flips between a "Grant" button and a green check.
struct PermissionStatusRow: View {
    let permission: Permission
    let usedByFeatures: [String]

    @State private var granted: Bool

    init(permission: Permission, usedByFeatures: [String]) {
        self.permission = permission
        self.usedByFeatures = usedByFeatures
        _granted = State(initialValue: permission.isGranted)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.systemSymbol)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(granted ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title)
                    .font(.callout.weight(.semibold))
                Text(permission.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !usedByFeatures.isEmpty {
                    Text("Used by: \(usedByFeatures.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            statusControl
        }
        .padding(12)
        // Re-check when the window regains focus — the user may have
        // toggled the permission in System Settings and tabbed back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = permission.isGranted
        }
    }

    @ViewBuilder
    private var statusControl: some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                Button("Grant…") {
                    permission.request { ok in granted = ok }
                }
                .controlSize(.small)
                Button("Re-check") {
                    granted = permission.isGranted
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
    }
}
