import Foundation
import SwiftUI

/// FOS-3 (SPEC §12) — Settings is an app-level SHEET reached from the Fleet
/// root's leading gearshape and Command Center. First item is useful
/// configuration, not a brand block. No invented preferences: Security
/// (App Lock), Appearance (System/Light/Dark — FOS-3), and the always-
/// reachable Agent Setup Prompt (C2) plus app version. Appearance owns both
/// the System/Light/Dark choice and the V1 environment-backed theme editor.
public struct FleetSettingsView: View {
    private let controller: AppLockController
    private let environment: AppEnvironment?
    private let appearanceController: FleetAppearanceController
    private let themeController: FleetThemeController

    /// C2: presents the always-reachable agent setup prompt sheet.
    @State private var showingSetupPrompt = false
    @State private var showingThemeEditor = false
    @State private var showingCacheClearConfirmation = false
    @State private var cacheClearFailed = false
    @State private var cacheClearError = ""
    @State private var clearingCache = false
    @Environment(\.fleetTheme) private var theme

    public init(controller: AppLockController,
                environment: AppEnvironment? = nil,
                appearanceController: FleetAppearanceController = FleetAppearanceController.shared,
                themeController: FleetThemeController = FleetThemeController.shared) {
        self.controller = controller
        self.environment = environment
        self.appearanceController = appearanceController
        self.themeController = themeController
    }

    public var body: some View {
        Form {
            if let service = environment?.embeddedTailnet {
                EmbeddedTailnetSettingsSection(service: service)
            }
            Section {
                Toggle(isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                )) {
                    Label("App Lock", systemImage: "faceid")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.settings.app-lock.toggle")
            } header: {
                Text("Security")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Require Face ID (or your device passcode) to unlock "
                     + "Hermes Fleet when the app opens. Stored gateway "
                     + "credentials stay protected by the Keychain.")
                    .foregroundStyle(theme.textSecondary)
            }

            Section {
                if environment != nil {
                    Button("Delete Local Cache", role: .destructive) {
                        showingCacheClearConfirmation = true
                    }
                    .disabled(clearingCache)
                    .accessibilityIdentifier("fleet.settings.delete-local-cache")
                }
            } header: {
                Text("Local Data")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Deletes cached conversations, roster snapshots, health history, and recent destinations. Saved gateways and Keychain credentials are kept.")
                    .foregroundStyle(theme.textSecondary)
            }

            // FOS-3 (§12 Appearance): System / Light / Dark, default System.
            Section {
                Picker("Appearance", selection: Binding(
                    get: { appearanceController.selection },
                    set: { appearanceController.selection = $0 }
                )) {
                    ForEach(FleetAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("fleet.settings.appearance")
            } header: {
                Text("Appearance")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Choose Light or Dark, or follow your device's system setting. Theme colors are edited separately and applied across Fleet together.")
                    .foregroundStyle(theme.textSecondary)
            }

            Section {
                Button {
                    showingThemeEditor = true
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet.settings.theme")
            } header: {
                Text("Theme")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Choose an opaque Highlight, Text, and Background color. Changes stay in a preview until you apply them.")
                    .foregroundStyle(theme.textSecondary)
            }

            // C2: the ALWAYS-REACHABLE door to the agent setup prompt. With
            // one or more gateways configured this is the add-another-server
            // path; the sheet itself carries the copy. The row stays
            // available with 1, 2, or 20 gateways.
            Section {
                Button {
                    showingSetupPrompt = true
                } label: {
                    Label("Set Up Another Server", systemImage: "text.badge.star")
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet.settings.setup-prompt")
            } header: {
                Text("Agent")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Copy or share the setup prompt to add another Hermes server to Fleet.")
                    .foregroundStyle(theme.textSecondary)
            }

            Section {
                LabeledContent("Version", value: Self.appVersion)
                    .accessibilityIdentifier("fleet.settings.version")
            } footer: {
                Text("Hermes Fleet — a pocket operations console for your agents.")
                    .foregroundStyle(theme.textSecondary)
            }

            Section {
                Link(destination: Self.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.settings.privacy-policy")
                Link(destination: Self.supportURL) {
                    Label("Support", systemImage: "questionmark.circle")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.settings.support")
            } header: {
                Text("Help & Privacy")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Hermes Fleet connects directly to gateways you choose. Review the policy before pairing a gateway.")
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .tint(theme.highlight)
        // C2: the setup-prompt door — standard sheet presentation.
        .sheet(isPresented: $showingSetupPrompt) {
            SetupPromptSheet()
        }
        .sheet(isPresented: $showingThemeEditor) {
            NavigationStack {
                FleetThemeEditorView(controller: themeController)
            }
        }
        .confirmationDialog("Delete local cache?", isPresented: $showingCacheClearConfirmation, titleVisibility: .visible) {
            Button("Delete Cache", role: .destructive) {
                guard let environment else { return }
                clearingCache = true
                Task {
                    do {
                        try await environment.clearLocalCache()
                    } catch {
                        cacheClearError = "The local cache could not be deleted. Try again after closing any active gateway operation."
                        cacheClearFailed = true
                    }
                    clearingCache = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes cached fleet and conversation data from this device. Saved gateways and credentials are not removed.")
        }
        .alert("Unable to Delete Cache", isPresented: $cacheClearFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cacheClearError)
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("fleet.settings")
    }

    /// Marketing/build version from the main bundle (no invented values).
    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let short, let build { return "\(short) (\(build))" }
        if let short { return short }
        return "Unknown"
    }

    // These are repository-backed, stable URLs rather than placeholders. The
    // release owner must still verify that the public policy and support
    // channel are reachable before submitting to App Store Connect.
    private static let privacyPolicyURL = URL(string: "https://github.com/AIowa-LLC/hermes-fleet/blob/main/PRIVACY.md")!
    private static let supportURL = URL(string: "https://github.com/AIowa-LLC/hermes-fleet/issues")!
}

/// Local-draft editor for the applied V1 palette. ColorPicker changes only
/// `draft`; the rest of the app observes `FleetThemeController.activePalette`
/// and therefore does not change until Apply (or the explicit Reset action).
public struct FleetThemeEditorView: View {
    private let controller: FleetThemeController
    @State private var draft: FleetThemePalette
    @State private var colorConversionFailed = false
    @State private var applyFailed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(controller: FleetThemeController = FleetThemeController.shared) {
        self.controller = controller
        #if DEBUG
        let debugPalette: FleetThemePalette? = if ProcessInfo.processInfo.arguments.contains("-issue6-low-contrast") {
            .lowContrastFixture
        } else if ProcessInfo.processInfo.arguments.contains("-issue6-arbitrary-theme") {
            .arbitraryFixture
        } else {
            nil
        }
        _draft = State(initialValue: debugPalette ?? controller.activePalette)
        #else
        _draft = State(initialValue: controller.activePalette)
        #endif
    }

    public var body: some View {
        Form {
            Section {
                ColorPicker("Highlight", selection: highlightBinding, supportsOpacity: false)
                    .accessibilityValue(draft.highlight.hexString)
                    .accessibilityIdentifier("fleet.theme.highlight")
                ColorPicker("Text", selection: textBinding, supportsOpacity: false)
                    .accessibilityValue(draft.text.hexString)
                    .accessibilityIdentifier("fleet.theme.text")
                ColorPicker("Background", selection: backgroundBinding, supportsOpacity: false)
                    .accessibilityValue(draft.background.hexString)
                    .accessibilityIdentifier("fleet.theme.background")
            } header: {
                Text("Palette")
            } footer: {
                Text("Fleet stores one opaque sRGB palette. Any color is allowed; contrast warnings are advisory in normal appearance.")
            }

            if colorConversionFailed {
                Label(
                    "That color could not be stored as an opaque sRGB value. Try another color.",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    .accessibilityIdentifier("fleet.theme.color-conversion-error")
            }

            Section("Preview") {
                preview
                    .accessibilityIdentifier("fleet.theme.preview")
            }

            Section("Contrast") {
                contrastSummary
            }

            Section {
                Button("Reset to Fleet Default") {
                    // Reset is a draft change like any other editor change;
                    // the app and persisted value remain untouched until the
                    // explicit Apply action.
                    draft = controller.defaultPalette
                    colorConversionFailed = false
                    applyFailed = false
                }
                .accessibilityIdentifier("fleet.theme.reset")
            }

            if applyFailed {
                Label(
                    "The theme could not be applied. Your current theme is unchanged.",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(FleetTheme.statusDestructive)
                    .accessibilityIdentifier("fleet.theme.apply-error")
            }
        }
        .navigationTitle("Theme")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("fleet.theme.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    if controller.apply(draft) {
                        applyFailed = false
                        dismiss()
                    } else {
                        applyFailed = true
                    }
                }
                .accessibilityIdentifier("fleet.theme.apply")
            }
        }
        .tint(previewTheme.highlight)
    }

    private var previewTheme: FleetThemeValues {
        FleetThemeValues(
            palette: draft,
            isDarkAppearance: colorScheme == .dark,
            isIncreasedContrast: colorSchemeContrast == .increased)
    }

    private var report: FleetThemeContrastReport {
        FleetThemeContrastReport(palette: draft, isDark: colorScheme == .dark)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text("Assistant response")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(previewTheme.textPrimary)
            Text("The same palette styles prose, links, code, and controls throughout Fleet.")
                .font(.body)
                .foregroundStyle(previewTheme.textPrimary)
            Link("Open documentation", destination: URL(string: "https://github.com/AIowa-LLC/hermes-fleet/blob/main/docs/features.md")!)
                .foregroundStyle(previewTheme.highlight)
            Text("inline code")
                .font(FleetTheme.monoFont)
                .foregroundStyle(previewTheme.textPrimary)
                .padding(.horizontal, FleetTheme.spacingSm)
                .padding(.vertical, FleetTheme.spacingXs)
                .background(previewTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
            Button("Primary action") {}
                .buttonStyle(.borderedProminent)
                .tint(previewTheme.highlight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FleetTheme.spacingMd)
        .background(previewTheme.background)
        .overlay {
            RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
                .stroke(previewTheme.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: FleetTheme.radiusCard))
    }

    @ViewBuilder
    private var contrastSummary: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Text("Text contrast: \(formatted(report.textToBackground))")
                .accessibilityIdentifier("fleet.theme.contrast.text")
            Text("Highlight contrast: \(formatted(report.highlightToBackground))")
                .accessibilityIdentifier("fleet.theme.contrast.highlight")
            Text("Highlight control text: \(formatted(report.highlightControlText))")
                .accessibilityIdentifier("fleet.theme.contrast.control")
            if report.hasWarning {
                Label("Low contrast — this combination may be difficult to read.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    .accessibilityIdentifier("fleet.theme.contrast.warning")
            } else {
                Label("Contrast meets the Fleet preview thresholds.", systemImage: "checkmark.circle")
                    .foregroundStyle(FleetTheme.statusOnline)
            }
        }
        .font(FleetTheme.secondaryFont)
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.1f:1", value)
    }

    private var highlightBinding: Binding<Color> {
        Binding(
            get: { draft.highlight.swiftUIColor },
            set: {
                guard let color = FleetStoredColor(color: $0) else {
                    colorConversionFailed = true
                    return
                }
                colorConversionFailed = false
                draft.highlight = color
                if draft.appearance == .adaptiveFleetDefault {
                    draft.appearance = .adaptiveCustomHighlight
                }
            })
    }

    private var textBinding: Binding<Color> {
        Binding(
            get: { draft.text.swiftUIColor },
            set: {
                guard let color = FleetStoredColor(color: $0) else {
                    colorConversionFailed = true
                    return
                }
                colorConversionFailed = false
                draft.text = color
                draft.appearance = .fixed
            })
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { draft.background.swiftUIColor },
            set: {
                guard let color = FleetStoredColor(color: $0) else {
                    colorConversionFailed = true
                    return
                }
                colorConversionFailed = false
                draft.background = color
                draft.appearance = .fixed
            })
    }
}

#if DEBUG
#Preview("Settings") {
    NavigationStack {
        FleetSettingsView(controller: .init(auth: AlwaysSuccessSettingsAuth()))
    }
    .preferredColorScheme(.dark)
}

private struct AlwaysSuccessSettingsAuth: AppLockBiometricAuth {
    func canEvaluateBiometrics() -> Bool { true }
    func evaluateBiometrics(reason: String) async -> AppLockAuthResult { .success }
    func evaluateDevicePasscode(reason: String) async -> Bool { true }
}
#endif
