import SwiftUI
import FleetCore
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Add / edit gateway form sheet (U2 registry management).
///
/// P0-2: the form's field state is bound DIRECTLY to a
/// `GatewayFormDraftStore` owned by `AppEnvironment` (composition root), not
/// to ephemeral `@State`. When the H1 biometric lock engages (app
/// backgrounded), `FleetTabView` swaps the whole tab shell — and with
/// it this sheet and any `@State` — for `AppLockView`. Because the field
/// values live in the root-owned draft store, the sheet is re-presented after
/// unlock with the user's typed data intact ("return exactly where you were").
///
/// On Save it builds a `GatewayRegistration` plus an optional
/// `GatewayCredential` and hands both to the `onSave` seam callback, which
/// routes them straight to the registry + Keychain store. A credential, when
/// entered, is passed by value to the seam and never held, logged, or stored
/// in the view layer (spec §16/§29). The draft store holds the typed secret
/// text ONLY while the sheet is open; it is cleared on Cancel and on
/// successful Save.
struct GatewayFormSheet: View {
    @Environment(\.fleetTheme) private var theme
    private let title: String
    private let saveButton: String
    /// Non-nil when editing an existing gateway (prefill / registration id).
    private let existing: FleetGateway?
    /// P2-6: the save seam now THROWS on failure so the form can distinguish a
    /// successful save (dismiss + clear secrets) from a failure (keep the
    /// sheet open, preserve non-secret fields for retry, surface the error).
    private let onSave: (GatewayRegistration, GatewayCredential?, Bool) async throws -> Void

    /// The root-owned draft store this form binds to (P0-2).
    @Bindable private var draftStore: GatewayFormDraftStore

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    /// F2: camera pairing-scanner presentation (fills the draft on success).
    @State private var isShowingScanner = false

    init(
        title: String,
        saveButton: String,
        initial: FleetGateway?,
        draftStore: GatewayFormDraftStore,
        onSave: @escaping (GatewayRegistration, GatewayCredential?, Bool) async throws -> Void
    ) {
        self.title = title
        self.saveButton = saveButton
        self.existing = initial
        self.draftStore = draftStore
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display Name", text: $draftStore.displayName)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityIdentifier("fleet.gateways.form.name")
                    // P0-2: paste button next to the URL field.
                    HStack(spacing: 8) {
                        TextField("Endpoint (http://host:port)", text: $draftStore.endpointText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("fleet.gateways.form.endpoint")
                        pasteButton("fleet.gateways.form.paste.endpoint", into: $draftStore.endpointText)
                    }
                } header: {
                    Text("Gateway")
                        .foregroundStyle(theme.textSecondary)
                }

                Section {
                    Picker("Network", selection: $draftStore.transport) {
                        Text("Direct / System Network").tag(GatewayTransport.system)
                        Text("Embedded Tailscale").tag(GatewayTransport.embeddedTailscale)
                    }
                    .accessibilityIdentifier("fleet.gateways.form.transport")
                } header: { Text("Transport") } footer: {
                    Text("Embedded Tailscale uses Fleet's own device identity, not the system VPN. Start and sign in from Settings first. Use an HTTPS MagicDNS (*.ts.net) address. Hermes credentials are still required separately.")
                }

                // C1 IA re-order (design): manual entry / URL is the tier-1
                // primary path; the scanner is DEMOTED to a clearly-labeled
                // secondary action — no server-side pairing-code generator
                // exists yet, so the scanner cannot receive a code today.
                Section {
                    Button {
                        isShowingScanner = true
                    } label: {
                        Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                            .foregroundStyle(theme.textSecondary)
                    }
                    .accessibilityIdentifier("fleet.gateways.form.scan")
                } header: {
                    Text("Pairing Code (Optional)")
                        .foregroundStyle(theme.textSecondary)
                } footer: {
                    Text("Requires gateway pairing support. Enter the address and credentials above instead.")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.gateways.form.scan.support-note")
                }

                if cleartextRisk {
                    // B2: prominent cleartext warning when the endpoint is
                    // http:// to a NON-private/loopback host — credentials
                    // would travel unencrypted to a public address. Saving is
                    // gated on explicit confirmation below.
                    Section {
                        Label {
                            Text("Password will be sent unencrypted to a public address.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(FleetTheme.statusDestructive)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(FleetTheme.statusDestructive)
                        }
                        .accessibilityIdentifier("fleet.gateways.form.cleartext-warning")

                        Toggle("I understand — connect anyway", isOn: $draftStore.confirmsCleartextSend)
                            .accessibilityIdentifier("fleet.gateways.form.cleartext-confirm")
                    } header: {
                        Text("Security Warning")
                            .foregroundStyle(FleetTheme.statusDestructive)
                    }
                }

                if secureEndpoint {
                    Section {
                        Label {
                            Text("Verify this address and certificate with the gateway operator before pairing. Hermes Fleet will store the certificate's public-key fingerprint and block unexpected changes.")
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(theme.highlight)
                        }
                        .accessibilityIdentifier("fleet.gateways.form.tls-first-use-warning")

                        Toggle("I trust this gateway's first certificate", isOn: $draftStore.confirmsTLSFirstUse)
                            .accessibilityIdentifier("fleet.gateways.form.tls-first-use-confirm")
                    } header: {
                        Text("Secure Pairing")
                            .foregroundStyle(theme.textSecondary)
                    }
                }

                Section {
                    Picker("Strategy", selection: $draftStore.strategy) {
                        Text("None").tag(GatewayAuthConfiguration.Strategy.none)
                        Text("Session Token").tag(GatewayAuthConfiguration.Strategy.sessionToken)
                        Text("Bearer Token").tag(GatewayAuthConfiguration.Strategy.bearerToken)
                        Text("Loopback Token").tag(GatewayAuthConfiguration.Strategy.loopbackToken)
                        Text("Username & Password").tag(GatewayAuthConfiguration.Strategy.usernamePassword)
                    }
                    .accessibilityIdentifier("fleet.gateways.form.strategy")
                    if needsTokenEntry {
                        HStack(spacing: 8) {
                            SecureField("Token (optional now, editable later)", text: $draftStore.tokenText)
                                .textContentType(.password)
                                .accessibilityIdentifier("fleet.gateways.form.token")
                            pasteButton("fleet.gateways.form.paste.token", into: $draftStore.tokenText)
                        }
                    }
                    if needsUsernamePasswordEntry {
                        HStack(spacing: 8) {
                            TextField("Username", text: $draftStore.usernameText)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("fleet.gateways.form.username")
                            pasteButton("fleet.gateways.form.paste.username", into: $draftStore.usernameText)
                        }
                        HStack(spacing: 8) {
                            SecureField("Password", text: $draftStore.passwordText)
                                .textContentType(.password)
                                .accessibilityIdentifier("fleet.gateways.form.password")
                            pasteButton("fleet.gateways.form.paste.password", into: $draftStore.passwordText)
                        }
                    }
                } header: {
                    Text("Authentication")
                        .foregroundStyle(theme.textSecondary)
                }

                // P2-6: inline, non-secret save-failure message. The sheet stays
                // open and the non-secret fields are preserved so the user can
                // retry without re-entering endpoint/auth strategy.
                if let saveError = draftStore.saveError {
                    Section {
                        Label {
                            Text(saveError)
                                .font(.caption)
                                .foregroundStyle(FleetTheme.statusDestructive)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(FleetTheme.statusDestructive)
                        }
                        .accessibilityIdentifier("fleet.gateways.form.error")
                    } header: {
                        Text("Save Failed")
                            .foregroundStyle(FleetTheme.statusDestructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // P0-2 / P2-6: intentional dismissal — wipe the draft
                        // (including secret material) so it never lingers.
                        draftStore.clear()
                        dismiss()
                    }
                    .accessibilityIdentifier("fleet.gateways.form.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButton) { save() }
                        .disabled(!isValid || isSaving)
                        .foregroundStyle(theme.highlight)
                        .accessibilityIdentifier("fleet.gateways.form.save")
                }
            }
        }
        .tint(theme.highlight)
        // F2: camera pairing scanner — successful scan fills the draft and
        // returns here for Save.
        .sheet(isPresented: $isShowingScanner) {
            GatewayPairingScannerView(draftStore: draftStore)
        }
        // P0-2: the form is deliberate — prevent accidental swipe-dismiss so
        // the user is never silently thrown out of an in-progress credential
        // entry. Dismissal is explicit (Cancel / Save).
        .interactiveDismissDisabled()
    }

    /// P0-2: explicit "Paste" affordance next to a credential / URL field —
    /// reads the system pasteboard into the bound field. Standard long-press
    /// paste with the keyboard visible remains available (never disabled).
    private func pasteButton(_ id: String, into binding: Binding<String>) -> some View {
        Button {
            #if canImport(UIKit)
            if let text = testPasteValue(for: id) ?? UIPasteboard.general.string {
                binding.wrappedValue = text
            }
            #endif
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
                .font(.caption)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(id)
    }

    private func testPasteValue(for identifier: String) -> String? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["HERMES_FLEET_UI_TEST_PASTE_FIXTURES"] == "1" else { return nil }
        switch identifier {
        case "fleet.gateways.form.paste.endpoint": return "https://gateway.example.invalid:8642"
        case "fleet.gateways.form.paste.username": return "fleet-operator"
        case "fleet.gateways.form.paste.password": return "NOT-A-CREDENTIAL"
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Token strategies need a secure entry field. `.none` does not.
    private var needsTokenEntry: Bool {
        switch draftStore.strategy {
        case .none: return false
        case .sessionToken, .bearerToken, .loopbackToken: return true
        case .usernamePassword: return false
        }
    }

    /// The username/password strategy needs username + password fields.
    private var needsUsernamePasswordEntry: Bool {
        draftStore.strategy == .usernamePassword
    }

    private var trimmedName: String {
        draftStore.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var endpointURL: URL? {
        guard let url = URL(string: draftStore.endpointText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        // P1-6: treat the endpoint as an ORIGIN — reject user-info
        // (user:pass@host) and strip query/fragment at the form boundary too,
        // so credential material never leaves the text field.
        return try? GatewayEndpoint.normalizedOrigin(from: url)
    }

    /// B2 cleartext risk: the endpoint is `http://` AND its host is NOT a
    /// private or loopback address — credentials would travel unencrypted to
    /// a public address. `https://` is never at risk. `PrivateNetwork` does
    /// the network-free classification (RFC1918/127./::1/.local/localhost).
    private var cleartextRisk: Bool {
        guard let url = endpointURL,
              url.scheme?.lowercased() == "http",
              let host = url.host,
              !host.isEmpty else { return false }
        return !PrivateNetwork.isPrivateOrLoopbackHost(host)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && endpointURL != nil
            && (draftStore.transport == .system || endpointURL.map { (try? EmbeddedTailnetPolicy.validateEndpoint($0)) != nil } == true)
            && (!cleartextRisk || draftStore.confirmsCleartextSend)
            && (!secureEndpoint || draftStore.confirmsTLSFirstUse)
    }

    private var secureEndpoint: Bool {
        endpointURL?.scheme?.lowercased() == "https"
    }

    private func save() {
        guard isValid, let endpoint = endpointURL else { return }
        isSaving = true
        let registration = GatewayRegistration(
            id: existing?.id,
            displayName: trimmedName,
            endpoint: endpoint,
            authConfiguration: GatewayAuthConfiguration(
                strategy: draftStore.strategy,
                credentialStored: existing?.authConfiguration.credentialStored ?? false
            ),
            transport: draftStore.transport
        )
        // The credential for token strategies is the token itself; for the
        // username/password strategy it is the password with the username
        // attached (stored as one Keychain item — the authenticator reads
        // both halves). Never echoed by the view layer.
        let credential: GatewayCredential? = {
            if draftStore.strategy == .usernamePassword {
                guard !draftStore.usernameText.isEmpty, !draftStore.passwordText.isEmpty else { return nil }
                return GatewayCredential(rawValue: draftStore.passwordText, username: draftStore.usernameText)
            }
            guard needsTokenEntry, !draftStore.tokenText.isEmpty else { return nil }
            return GatewayCredential(rawValue: draftStore.tokenText)
        }()

        Task {
            do {
                // P2-6: only dismiss on SUCCESS. On failure the sheet stays
                // open with the non-secret fields preserved for retry and the
                // (non-secret) error surfaced inline — no discarded input.
                try await onSave(registration, credential, draftStore.confirmsTLSFirstUse)
                isSaving = false
                // P0-2: successful save wipes the draft (secret material
                // included) so nothing lingers after the sheet closes.
                draftStore.clear()
                dismiss()
            } catch {
                isSaving = false
                draftStore.saveError = Self.nonSecret(error)
            }
        }
    }

    /// Non-secret error description for inline display (mirrors GatewaysView).
    static func nonSecret(_ error: any Error) -> String {
        Redaction.safeErrorDescription(error)
    }
}
