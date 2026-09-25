import Foundation
import Observation
import SwiftUI
import FleetCore

@MainActor @Observable
public final class EmbeddedTailnetViewModel {
    public private(set) var status = EmbeddedTailnetSnapshot(state: .stopped)
    public private(set) var busy = false
    public private(set) var errorMessage: String?
    private let service: any EmbeddedTailnetManaging
    public init(service: any EmbeddedTailnetManaging) { self.service = service }
    public func refresh() async { status = await service.snapshot() }
    public func start() async { await perform { try await self.service.start() } }
    public func login() async { await perform { try await self.service.login() } }
    public func stop() async { await perform { try await self.service.stop() } }
    public func logout() async { await perform { try await self.service.logout() } }
    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        status.enrollmentURL = nil
        defer { busy = false }
        do { try await action() }
        catch {
            // SDK errors can contain auth URLs or LocalAPI response bodies.
            errorMessage = "Tailscale could not complete this action. Retry; check network access, enrollment and device approval. No direct-network fallback was used."
        }
        await refresh()
    }
}

struct EmbeddedTailnetSettingsSection: View {
    @State private var model: EmbeddedTailnetViewModel
    @State private var confirmLogout = false
    @Environment(\.scenePhase) private var phase
    init(service: any EmbeddedTailnetManaging) {
        _model = State(initialValue: EmbeddedTailnetViewModel(service: service))
    }
    var body: some View {
        Section {
            LabeledContent("Status", value: model.status.state.rawValue)
                .accessibilityIdentifier("fleet.tailscale.status")
            Button("Start Tailscale") { Task { await model.start() } }
                .accessibilityIdentifier("fleet.tailscale.start")
            Button("Sign in with browser") { Task { await model.login() } }
                .accessibilityIdentifier("fleet.tailscale.login")
            if let url = model.status.enrollmentURL {
                Link("Continue to Tailscale sign-in", destination: url)
                    .accessibilityIdentifier("fleet.tailscale.browser")
            }
            Button("Stop") { Task { await model.stop() } }
            Button("Log out of Tailscale", role: .destructive) { confirmLogout = true }
                .accessibilityIdentifier("fleet.tailscale.logout")
            if let error = model.errorMessage { Text(error).font(.caption) }
        } header: { Text("Embedded Tailscale") } footer: {
            Text("Fleet joins as a separate device. It does not install a VPN or change other apps' traffic. Approve the new device and allow only the gateways it needs in your tailnet. Choose Embedded Tailscale on each gateway; Hermes login and TLS trust remain separate. Stop disconnects all embedded gateways; logout removes this node's login. Start again after reopening the app.")
        }
        .disabled(model.busy)
        .confirmationDialog("Log out this Fleet device?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { Task { await model.logout() } }
        } message: {
            Text("All embedded gateway connections will close. Gateway passwords are not removed. You will need to sign in to Tailscale again.")
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
