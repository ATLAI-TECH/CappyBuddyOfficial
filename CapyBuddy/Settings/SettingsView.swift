import AppKit
import SwiftUI

struct SettingsView: View {

    @StateObject private var registry = FeatureRegistry.shared
    @State private var selectedID: String

    init(initialSelection: String? = nil) {
        _selectedID = State(initialValue: initialSelection ?? "general")
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("App") {
                    Label("General", systemImage: "gearshape")
                        .tag("general")
                    Label("Menu Bar", systemImage: "menubar.rectangle")
                        .tag("menubar")
                }
                Section("Features") {
                    // Direct-action features (Picture Converter, QR Code)
                    // are excluded — they're "open this window" shortcuts
                    // with no per-feature Settings tab. They still appear
                    // in General → Features and Menu Bar so users can turn
                    // them on/off and toggle dropdown visibility.
                    ForEach(registry.features.filter { !$0.isDirectAction }, id: \.id) { feature in
                        Label(feature.displayName, systemImage: feature.iconSystemName)
                            .tag(feature.id)
                    }
                }
                Section {
                    Label("Feedback", systemImage: "exclamationmark.bubble")
                        .tag("feedback")
                    Label("Support", systemImage: "heart.fill")
                        .tag("support")
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180)
        } detail: {
            ScrollView {
                detailView
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .capyBuddySettingsSelect)) { note in
            if let id = note.userInfo?["id"] as? String {
                selectedID = id
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if selectedID == "general" {
            GeneralSettingsView()
        } else if selectedID == "menubar" {
            MenuBarSettingsView()
        } else if selectedID == "feedback" {
            FeedbackView()
        } else if selectedID == "support" {
            SupportView()
        } else if let feature = registry.feature(id: selectedID) {
            FeatureDetailView(feature: feature)
        } else {
            ContentUnavailableView("Select an item", systemImage: "sidebar.left")
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var registry = FeatureRegistry.shared
    @ObservedObject private var appearance = AppearanceManager.shared

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CapyBuddy"
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(appName)
                        .font(.title.bold())
                    Text("Your friendly Mac companion.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(versionString)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        #if CAPYBUDDY_DIRECT
                        Button("Check for Updates…") {
                            UpdaterController.shared.checkForUpdates()
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        #endif
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )

            GroupBox("Appearance") {
                HStack {
                    Text("Theme")
                    Spacer()
                    Picker("", selection: $appearance.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Features") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Turn individual tools on or off. Hover or click the info icon to learn what each tool does.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)

                    ForEach(registry.features, id: \.id) { feature in
                        FeatureRow(feature: feature)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CapyBuddy never asks for these at install. Grant a permission only when a tool needs it — or set it up ahead of time here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    PermissionsOverview()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Welcome") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Take the welcome tour")
                            .font(.callout.weight(.semibold))
                        Text("A quick, animated walkthrough of every tool. Shown once on first launch — replay it any time.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Show Tour…") {
                        (NSApp.delegate as? AppDelegate)?.showOnboarding()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
    }
}

/// One row in the General → Features list. Pulled out so each row owns its
/// own `@State` for the info-button popover — otherwise clicking one row's
/// info icon would toggle every row's popover at once.
private struct FeatureRow: View {
    let feature: any Feature
    @ObservedObject private var registry = FeatureRegistry.shared
    @State private var showSummary = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: feature.iconSystemName)
                .frame(width: 22)
                .foregroundStyle(.primary)
            Text(feature.displayName)
            if !feature.summary.isEmpty {
                Button {
                    showSummary.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(feature.summary)
                .popover(isPresented: $showSummary, arrowEdge: .bottom) {
                    Text(feature.summary)
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { feature.isEnabled },
                set: { registry.setEnabled($0, for: feature.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

private struct MenuBarSettingsView: View {
    @ObservedObject private var registry = FeatureRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Menu Bar")
                        .font(.title2.bold())
                    Text("Choose which tools appear in CapyBuddy's dropdown — and preview the result on the right.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )

            GroupBox("Menu Bar") {
                HStack(alignment: .top, spacing: 18) {
                    // Left: per-feature visibility switches. These are
                    // INDEPENDENT of the Enable toggle on each feature's
                    // own settings tab — hiding a tool from the menu
                    // doesn't stop it running (hotkeys, monitors, etc.
                    // still work).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pick which tools appear in the dropdown. Hidden tools still run in the background.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)

                        ForEach(registry.features, id: \.id) { feature in
                            HStack {
                                Image(systemName: feature.iconSystemName)
                                    .frame(width: 22)
                                    .foregroundStyle(feature.isEnabled ? .primary : .tertiary)
                                Text(feature.displayName)
                                    .foregroundStyle(feature.isEnabled ? .primary : .secondary)
                                if !feature.isEnabled {
                                    Text("(disabled)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { feature.showsInMenuBar },
                                    set: { registry.setMenuVisible($0, for: feature.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!feature.isEnabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Right: live preview of the resulting dropdown.
                    MenuBarDropdownPreview()
                }
                .padding(10)
            }

            Spacer()
        }
    }
}

/// SwiftUI mock of the live menu-bar dropdown — re-renders whenever the
/// FeatureRegistry's enabled set changes so the user sees their toggle
/// changes reflected immediately, without having to click the menu-bar
/// icon to verify.
private struct MenuBarDropdownPreview: View {
    @ObservedObject private var registry = FeatureRegistry.shared

    private var visibleFeatures: [any Feature] {
        registry.features.filter { $0.isEnabled && $0.showsInMenuBar }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleFeatures, id: \.id) { feature in
                row(icon: feature.iconSystemName, title: feature.displayName, hasSubmenu: true)
            }

            if !visibleFeatures.isEmpty {
                Divider().padding(.vertical, 3)
            }

            row(icon: "gearshape", title: "Settings…", hasSubmenu: false)
            row(icon: "power", title: "Quit CapyBuddy", hasSubmenu: false)
        }
        .padding(.vertical, 6)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func row(icon: String, title: String, hasSubmenu: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            if hasSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

private struct FeatureDetailView: View {
    let feature: any Feature
    @ObservedObject private var registry = FeatureRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(feature.displayName, systemImage: feature.iconSystemName)
                    .font(.title2).bold()
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { feature.isEnabled },
                    set: { registry.setEnabled($0, for: feature.id) }
                ))
                .toggleStyle(.switch)
            }
            Divider()
            feature.makeSettingsView()
            Spacer()
        }
    }
}
