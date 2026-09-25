import SwiftUI
import FleetCore

/// Gateways list — the U2 fleet cockpit root (registry management).
///
/// Reads the registered gateways from `AppEnvironment` (observable) and
/// exposes the full registry-management surface over the FleetCore
/// `GatewayRegistryManaging` seam: add / edit / remove, test connection
/// (reachable/unreachable per spec §13), and per-gateway auth-config entry
/// (M7 credential flow — Keychain-safe, the secret never transits the UI
/// model). Each row also keeps the U1 runtime-owned connect/disconnect/
/// reconnect lifecycle.
///
/// M14 theme: Black/White/Signal Red; status is icon + text (color is
/// reinforcement only), per the semantic status map.
public struct GatewaysView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let connectionGatewayID: GatewayID?

    /// Presentation-only sheet state (no secrets stored here).
    @State private var presentedSheet: PresentedSheet?
    /// Error surfaced to the user from a registry operation (non-secret).
    @State private var operationError: String?
    /// P1-8: the gateway awaiting destructive-removal confirmation.
    @State private var gatewayPendingRemoval: FleetGateway?
    /// P1-8: the most recently removed gateway, for a bounded undo.
    @State private var lastRemovedGateway: FleetGateway?
    /// T3: secure trust reset awaiting explicit re-pair confirmation.
    @State private var gatewayPendingTLSTrustReset: FleetGateway?

    enum PresentedSheet: Identifiable {
        case add
        case edit(FleetGateway)
        case auth(GatewayID)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let gateway): return "edit-\(gateway.id.rawValue)"
            case .auth(let id): return "auth-\(id.rawValue)"
            }
        }
    }

    public init(environment: AppEnvironment, connectionGatewayID: GatewayID? = nil) {
        self.environment = environment
        self.connectionGatewayID = connectionGatewayID
    }

    public var body: some View {
        Group {
            if let connectionGatewayID {
                if let gateway = environment.gateway(for: connectionGatewayID) {
                    connectionDetails(gateway)
                } else {
                    ContentUnavailableView("Gateway removed", systemImage: "server.rack", description: Text("This connection is no longer registered on this phone."))
                }
            } else if environment.gateways.isEmpty {
                emptyState
            } else {
                gatewayList
            }
        }
        .navigationTitle(connectionGatewayID == nil ? "Gateways" : "Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if connectionGatewayID == nil {
                Button {
                    presentAddForm()
                } label: {
                    Label("Add Gateway", systemImage: "plus")
                }
                .accessibilityIdentifier("fleet.gateways.add")

                Button {
                    Task { await environment.refreshRoster() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("fleet.gateways.refresh")
                .disabled(environment.isRefreshing)
                }
                // U3: Roster / Health / Settings moved to their own tabs
                // (Bots / Activity·Home / Settings) — no longer toolbar links.
                // FOS-3 (SPEC §6): the Gateways toolbar is Add + Command
                // Center (shell-provided). This slot keeps only Add.
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .add:
                // P2-6: let the form see save failures — it keeps the sheet
                // open, preserves the non-secret fields, and surfaces the error
                // inline for retry (the parent no longer swallows the error into
                // a post-dismiss alert that races the sheet).
                // P0-2: the form binds to the root-owned draft store so it
                // survives the H1 lock / scenePhase teardown.
                GatewayFormSheet(
                    title: "Add Gateway",
                    saveButton: "Add",
                    initial: nil,
                    draftStore: environment.gatewayFormDraft
                ) { registration, credential, confirmsTLSFirstUse in
                    _ = try await environment.addGateway(
                        registration,
                        credential: credential,
                        confirmsTLSFirstUse: confirmsTLSFirstUse)
                }
            case .edit(let gateway):
                GatewayFormSheet(
                    title: "Edit Gateway",
                    saveButton: "Save",
                    initial: gateway,
                    draftStore: environment.gatewayFormDraft
                ) { registration, credential, confirmsTLSFirstUse in
                    // Apply the edited display name / endpoint / strategy.
                    _ = try await environment.updateGateway(
                        gateway.id,
                        edits: GatewayEdit(
                            displayName: registration.displayName,
                            endpoint: registration.endpoint,
                            authConfiguration: registration.authConfiguration,
                            transport: registration.transport
                        )
                    )
                    // Store a newly-entered credential (Keychain-safe);
                    // nil keeps the registry's existing credential.
                    if let credential {
                        try await environment.saveCredential(credential, for: gateway.id)
                    }
                    if confirmsTLSFirstUse {
                        try await environment.approveTLSFirstUse(for: gateway.id)
                    }
                }
            case .auth(let id):
                GatewayAuthSheet(environment: environment, gatewayID: id)
            }
        }
        .alert("Gateway Error", isPresented: .init(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        // P1-8: destructive-removal confirmation — a named alert explaining
        // that the stored credential is deleted with the gateway. Removal
        // only proceeds on explicit confirm. (Alert, not confirmationDialog:
        // its two buttons expose stable accessibility identifiers to XCUITest.)
        .alert(
            "Remove Gateway?",
            isPresented: .init(
                get: { gatewayPendingRemoval != nil },
                set: { if !$0 { gatewayPendingRemoval = nil } }
            )
        ) {
            Button("Remove Gateway", role: .destructive) {
                confirmRemoval()
            }
            .accessibilityIdentifier("fleet.gateways.remove.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("fleet.gateways.remove.cancel")
        } message: {
            Text("Remove \(gatewayPendingRemoval?.displayName ?? "this gateway") from Fleet? Its saved connection and credentials will be removed from this phone. Bots and data on the gateway will remain.")
        }
        // P1-8: bounded undo for the most recent removal (registry only — the
        // credential is intentionally gone per the confirmation above).
        .alert(
            "Gateway Removed",
            isPresented: .init(
                get: { lastRemovedGateway != nil },
                set: { if !$0 { lastRemovedGateway = nil } }
            )
        ) {
            Button("Undo") { undoRemoval() }
                .accessibilityIdentifier("fleet.gateways.remove.undo")
            Button("OK", role: .cancel) {}
        } message: {
            Text("Undo restores \"\(lastRemovedGateway?.displayName ?? "")\" as a gateway (no stored credential).")
        }
        .alert(
            "Re-pair Secure Gateway?",
            isPresented: .init(
                get: { gatewayPendingTLSTrustReset != nil },
                set: { if !$0 { gatewayPendingTLSTrustReset = nil } }
            )
        ) {
            Button("Clear Trust and Re-pair", role: .destructive) {
                guard let gateway = gatewayPendingTLSTrustReset else { return }
                gatewayPendingTLSTrustReset = nil
                Task {
                    do {
                        try await environment.resetTLSTrust(for: gateway.id)
                    } catch {
                        operationError = "The secure gateway trust could not be cleared. Try again when no gateway operation is running."
                    }
                }
            }
            .accessibilityIdentifier("fleet.connection.tls-repair.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("fleet.connection.tls-repair.cancel")
        } message: {
            Text("The next connection will be blocked until you verify the gateway and confirm its new certificate in Edit Gateway. Existing credentials are kept.")
        }
        .background(theme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.gateways")
        // P0-2: after the H1 biometric lock releases, this view is re-created
        // with `presentedSheet == nil`. If a gateway-form draft is in flight,
        // re-present the sheet so the user returns exactly where they were.
        .onAppear {
            resumeGatewayFormDraftIfNeeded()
        }
    }

    private func connectionDetails(_ gateway: FleetGateway) -> some View {
        List {
            Section("Identity") {
                LabeledContent("Gateway", value: gateway.displayName)
                LabeledContent("Gateway ID", value: gateway.id.rawValue)
                Text(gateway.endpoint.map(Redaction.redactedURL) ?? "Endpoint not configured")
                    .font(.footnote).textSelection(.enabled)
                LabeledContent("Phone connection", value: GatewayConnectionCopy.label(environment.connectionStates[gateway.id] ?? .idle))
            }
            Section {
                Button("Connect", systemImage: "bolt") { Task { await environment.connect(to: gateway.id) } }
                    .accessibilityIdentifier("fleet.connection.connect.\(gateway.id.rawValue)")
                Button("Authentication", systemImage: "key") { presentedSheet = .auth(gateway.id) }
                Button("Test Connection", systemImage: "network") {
                    Task {
                        do { try await environment.testConnection(to: gateway.id) }
                        catch { operationError = Self.describe(error) }
                    }
                }.disabled(environment.testingGatewayIDs.contains(gateway.id))
                    .accessibilityIdentifier("fleet.connection.test.\(gateway.id.rawValue)")
                if environment.testingGatewayIDs.contains(gateway.id) { ProgressView("Testing connection…") }
                if let result = environment.testResults[gateway.id] {
                    LabeledContent("Last test", value: result.status.rawValue)
                    if let date = environment.testResultObservedAt[gateway.id] { Text(date, style: .relative).font(.footnote) }
                }
                Button("Disconnect", systemImage: "power") { Task { await environment.disconnect(from: gateway.id) } }
                Button("Reconnect", systemImage: "arrow.clockwise") { Task { await environment.reconnect(to: gateway.id) } }
            } footer: { Text("These controls affect this phone's connection. They do not stop Bots or the gateway.") }
            Section("Diagnostics") {
                NavigationLink("Connection diagnostics", value: FleetScreen.gatewayHealth(gateway.id))
                DisclosureGroup("Advertised connection capabilities") {
                    let capabilities = environment.testResults[gateway.id]?.capabilities.allStrings
                        ?? environment.rosterSnapshot?.roster.gateways[gateway.id]?.capabilities
                    if let capabilities, !capabilities.isEmpty {
                        ForEach(capabilities.sorted(), id: \.self) { Text($0).font(.footnote.monospaced()) }
                    } else { Text("No capability catalog observed.") }
                    Text("Groups and RoomLink capabilities are negotiated separately.").font(.footnote).foregroundStyle(theme.textSecondary)
                }
            }
            Section {
                Button("Edit Gateway", systemImage: "pencil") { presentEditForm(gateway) }
                Button("Remove Gateway", role: .destructive) { gatewayPendingRemoval = gateway }
                    .accessibilityIdentifier("fleet.connection.remove.\(gateway.id.rawValue)")
            }
            if gateway.endpoint?.scheme?.lowercased() == "https" {
                Section("TLS Trust") {
                    Text("The gateway's certificate key is pinned on first approved use. A changed key is blocked until you explicitly re-pair it.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                    Button("Re-pair / Rotate Certificate", role: .destructive) {
                        gatewayPendingTLSTrustReset = gateway
                    }
                    .accessibilityIdentifier("fleet.connection.tls-repair.\(gateway.id.rawValue)")
                }
            }
        }.accessibilityIdentifier("fleet.connection.\(gateway.id.rawValue)")
    }

    // MARK: P0-2 — in-progress form draft (survives the FaceID lock)

    /// Open the Add-Gateway sheet, beginning a fresh draft in the root-owned
    /// store (so an app background + relock mid-entry is restored on unlock).
    private func presentAddForm() {
        environment.gatewayFormDraft.begin(pendingSheet: .add, initial: nil)
        presentedSheet = .add
    }

    /// Open the Edit-Gateway sheet, beginning a fresh draft seeded from the
    /// gateway's current non-secret values.
    private func presentEditForm(_ gateway: FleetGateway) {
        environment.gatewayFormDraft.begin(pendingSheet: .edit(gateway.id), initial: gateway)
        presentedSheet = .edit(gateway)
    }

    /// Re-present the in-progress form draft after a lock/unlock cycle (or a
    /// scenePhase background that tore the sheet down). No-op when there is no
    /// draft or a sheet is already up.
    private func resumeGatewayFormDraftIfNeeded() {
        let draft = environment.gatewayFormDraft
        guard draft.isInProgress, presentedSheet == nil else { return }
        switch draft.pendingSheet {
        case .add:
            presentedSheet = .add
        case .edit(let gatewayID):
            // The draft stores only the ID; resolve the current gateway so the
            // edit sheet gets the live registry value. If it was removed while
            // backgrounded, drop the stale draft instead of presenting a dead edit.
            if let gateway = environment.gateway(for: gatewayID) {
                presentedSheet = .edit(gateway)
            } else {
                draft.clear()
            }
        case nil:
            break
        }
    }

    // MARK: States

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Gateways")
            } icon: {
                Image(systemName: "server.rack")
                    .foregroundStyle(theme.highlight)
            }
        } description: {
            Text("Add your first Hermes gateway to see your fleet.")
        } actions: {
            Button("Add Gateway") {
                presentAddForm()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.highlight)
            .accessibilityIdentifier("fleet.gateways.empty.add")
        }
        .accessibilityIdentifier("fleet.gateways.empty")
    }

    private var gatewayList: some View {
        List {
            // FOS-3 (§1): Control's cross-fleet diagnostics links are owned by
            // the Gateways tab now (per-gateway resources live on Gateway
            // Detail from FOS-2).
            Section {
                NavigationLink(value: FleetScreen.health) {
                    Label("Connection health", systemImage: "waveform.path.ecg")
                }
                .accessibilityIdentifier("fleet.gateways.health")
                NavigationLink(value: FleetScreen.activity) {
                    Label("Connection history", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("fleet.gateways.activity")
            } header: {
                Text("Fleet")
            }
            Section("Gateways") {
            ForEach(environment.gateways) { gateway in
            NavigationLink(value: FleetScreen.gatewayDetail(gateway.id)) {
                GatewayRowView(environment: environment, gateway: gateway)
            }
            .accessibilityIdentifier("fleet.gateways.row.\(gateway.id.rawValue)")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    // P1-8: never remove on an unconfirmed swipe — require an
                    // explicit, named confirmation that explains credential
                    // deletion before the registry + Keychain are touched.
                    gatewayPendingRemoval = gateway
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .accessibilityIdentifier("fleet.gateways.row.\(gateway.id.rawValue).remove")
            }
            .contextMenu {
                Button {
                    Task { await environment.connect(to: gateway.id) }
                } label: {
                    Label("Connect", systemImage: "bolt.fill")
                }
                Button {
                    Task { await environment.disconnect(from: gateway.id) }
                } label: {
                    Label("Disconnect", systemImage: "power")
                }
                Button {
                    Task { await environment.reconnect(to: gateway.id) }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                Divider()
                Button {
                    Task {
                        do {
                            try await environment.testConnection(to: gateway.id)
                        } catch {
                            operationError = Self.describe(error)
                        }
                    }
                } label: {
                    Label("Test Connection", systemImage: "network")
                }
                Button {
                    presentedSheet = .auth(gateway.id)
                } label: {
                    Label("Authentication", systemImage: "key")
                }
                Button {
                    presentEditForm(gateway)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .accessibilityIdentifier("fleet.gateways.list")
    }

    /// Non-secret description for a registry operation failure.
    static func describe(_ error: Error) -> String {
        Redaction.safeErrorDescription(error)
    }

    // MARK: P1-8 — confirmed removal + bounded undo

    /// Execute the confirmed destructive removal. Surfaces any failure
    /// (including a Keychain credential-cleanup failure) instead of
    /// suppressing it, and offers a bounded undo on success.
    private func confirmRemoval() {
        guard let gateway = gatewayPendingRemoval else { return }
        gatewayPendingRemoval = nil
        Task {
            do {
                try await environment.removeGateway(gateway.id)
                lastRemovedGateway = gateway
            } catch {
                operationError = Self.describe(error)
            }
        }
    }

    /// Undo the most recent removal: re-register the gateway (registry only —
    /// the credential was intentionally deleted per the confirmation). Bounded
    /// to the last removed gateway.
    private func undoRemoval() {
        guard let gateway = lastRemovedGateway else { return }
        lastRemovedGateway = nil
        guard let endpoint = gateway.endpoint else {
            operationError = Self.describe(GatewayRegistryError.invalidEndpoint)
            return
        }
        Task {
            do {
                _ = try await environment.addGateway(GatewayRegistration(
                    id: gateway.id,
                    displayName: gateway.displayName,
                    endpoint: endpoint,
                    authConfiguration: gateway.authConfiguration,
                    transport: gateway.transport
                ))
            } catch {
                operationError = Self.describe(error)
            }
        }
    }
}

/// One gateway row: identity + test-result §13 status + runtime connection
/// lifecycle badge.
private struct GatewayRowView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let gateway: FleetGateway

    init(environment: AppEnvironment, gateway: FleetGateway) {
        self.environment = environment
        self.gateway = gateway
    }

    var body: some View {
        let state = environment.connectionStates[gateway.id] ?? .idle
        // At large Dynamic Type the full row (icon + text + text badge + menu)
        // can exceed the row width. ViewThatFits picks the first fitting
        // variant — the full row normally, and a compact row (no text badge,
        // status icon only) at AX sizes so the display name always gets the
        // space it needs (M14 a11y gate: text yields to controls).
        ViewThatFits(in: .horizontal) {
            fullRow(state: state)
            compactRow(state: state)
        }
    }

    private func fullRow(state: GatewayConnectionState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(theme.highlight)
                .accessibilityHidden(true)
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(gateway.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // V3: endpoints are machine data — mono, the terminal voice.
                Text(gateway.endpoint.map(Redaction.redactedURL) ?? gateway.id.rawValue)
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if gateway.authConfiguration.credentialStored || gateway.authConfigured {
                    Label("Auth configured", systemImage: "key")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .accessibilityLabel("Authentication configured")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)

            if environment.testingGatewayIDs.contains(gateway.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Testing connection")
            } else {
                ConnectionStateBadge(state: state)
                    .accessibilityElement(children: .combine)
                    .fixedSize()
            }

            rowMenu
        }
        .padding(.vertical, 2)
    }

    /// Compact variant for large Dynamic Type: name + endpoint + a status
    /// ICON only (no text badge), so the name still has room to wrap.
    private func compactRow(state: GatewayConnectionState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(theme.highlight)
                .accessibilityHidden(true)
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(gateway.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(gateway.endpoint.map(Redaction.redactedURL) ?? gateway.id.rawValue)
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)

            if environment.testingGatewayIDs.contains(gateway.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Testing connection")
            } else {
                Image(systemName: statusSymbol(state))
                    .foregroundStyle(statusColor(state))
                    .fixedSize()
                    .accessibilityLabel("Status: \(statusLabel(state))")
            }

            rowMenu
        }
        .padding(.vertical, 2)
    }

    private var rowMenu: some View {
        Menu {
            Button {
                Task { await environment.connect(to: gateway.id) }
            } label: {
                Label("Connect", systemImage: "bolt.fill")
            }
            Button {
                Task { await environment.disconnect(from: gateway.id) }
            } label: {
                Label("Disconnect", systemImage: "power")
            }
            Button {
                Task { await environment.reconnect(to: gateway.id) }
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Divider()
            Button {
                Task {
                    do {
                        try await environment.testConnection(to: gateway.id)
                    } catch {
                        // absent gateway → surfaced by the sheet caller path
                    }
                }
            } label: {
                Label("Test Connection", systemImage: "network")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(theme.textSecondary)
                .fixedSize()
        }
        .accessibilityIdentifier("fleet.gateways.row.\(gateway.id.rawValue).menu")
    }

    private func statusSymbol(_ state: GatewayConnectionState) -> String {
        switch state {
        case .idle: return "circle"
        case .connecting: return "circle.dotted"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "wifi.slash"
        case .failed(let status):
            switch status {
            case .authenticationRequired: return "exclamationmark.circle.fill"
            case .degraded: return "exclamationmark.triangle.fill"
            case .unsupported: return "xmark.octagon.fill"
            case .offline: return "wifi.slash"
            case .online, .connecting: return "circle"
            }
        }
    }

    private func statusColor(_ state: GatewayConnectionState) -> Color {
        switch state {
        case .failed(let status):
            switch status {
            case .authenticationRequired:
                return FleetTheme.statusNeedsIntervention
            case .degraded, .unsupported:
                return FleetTheme.statusDegraded
            case .offline, .online, .connecting:
                return theme.textSecondary
            }
        case .idle, .connecting, .connected, .disconnected:
            return theme.textSecondary
        }
    }

    private func statusLabel(_ state: GatewayConnectionState) -> String {
        switch state {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .failed(let status): return statusText(status)
        }
    }

    private func statusText(_ status: GatewayStatus) -> String {
        switch status {
        case .online: return "Online"
        case .connecting: return "Connecting"
        case .degraded: return "Degraded"
        case .authenticationRequired: return "Auth Required"
        case .offline: return "Unreachable"
        case .unsupported: return "Unsupported"
        }
    }
}

/// The §13 semantic status badge: icon + text, color as reinforcement only.
/// Renders the last test-connection result status when one exists (so a
/// failed probe shows Auth Required / Unreachable even without a live connect).
private struct ConnectionStateBadge: View {
    @Environment(\.fleetTheme) private var theme
    let state: GatewayConnectionState

    var body: some View {
        Label {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }

    private var label: String {
        switch state {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .failed(let status): return statusText(status)
        }
    }

    private var symbol: String {
        switch state {
        case .idle: return "circle"
        case .connecting: return "circle.dotted"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "wifi.slash"
        case .failed(let status):
            switch status {
            case .authenticationRequired: return "exclamationmark.circle.fill"
            case .degraded: return "exclamationmark.triangle.fill"
            case .unsupported: return "xmark.octagon.fill"
            case .offline: return "wifi.slash"
            case .online, .connecting: return "circle"
            }
        }
    }

    private var color: Color {
        switch state {
        case .failed(let status):
            switch status {
            case .authenticationRequired:
                return FleetTheme.statusNeedsIntervention
            case .degraded, .unsupported:
                return FleetTheme.statusDegraded
            case .offline, .online, .connecting:
                return theme.textSecondary
            }
        case .idle, .connecting, .connected, .disconnected:
            return theme.textSecondary
        }
    }

    private func statusText(_ status: GatewayStatus) -> String {
        switch status {
        case .online: return "Online"
        case .connecting: return "Connecting…"
        case .degraded: return "Degraded"
        case .authenticationRequired: return "Auth Required"
        case .offline: return "Unreachable"
        case .unsupported: return "Unsupported"
        }
    }
}
