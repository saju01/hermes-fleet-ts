import SwiftUI
import FleetCore

/// Simple mode gate: a chat-only root (default) vs the four-tab Advanced
/// shell. Non-secret local preference (UserDefaults), same posture as
/// Appearance.
public enum FleetUIMode: String, CaseIterable, Identifiable, Sendable {
    case simple
    case advanced

    public var id: String { rawValue }
    public var label: String { self == .simple ? "Simple" : "Advanced" }
}

@MainActor
@Observable
public final class FleetUIModeController {
    public static let defaultsKey = "fleet.ui.mode.v1"

    public private(set) var mode: FleetUIMode
    private let defaults: UserDefaults
    /// A launch-env pin is process-scoped: switching while pinned is not
    /// persisted (keeps shared simulator containers deterministic).
    private let isPinned: Bool

    /// Resolution order: `HERMES_FLEET_UI_MODE` launch env (simple|advanced,
    /// UI tests pin a mode) → the persisted choice → `fallback`. The app
    /// passes `.simple` as the fallback; see `FleetServiceGraph` for the
    /// scripted-simulator exception that keeps the pre-existing UI suites on
    /// the tab shell they were written against.
    public init(defaults: UserDefaults = .standard,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                fallback: FleetUIMode = .simple) {
        self.defaults = defaults
        self.isPinned = environment["HERMES_FLEET_UI_MODE"].flatMap(FleetUIMode.init(rawValue:)) != nil
        if let raw = environment["HERMES_FLEET_UI_MODE"], let forced = FleetUIMode(rawValue: raw) {
            mode = forced
        } else if let raw = defaults.string(forKey: Self.defaultsKey), let stored = FleetUIMode(rawValue: raw) {
            mode = stored
        } else {
            mode = fallback
        }
    }

    public func setMode(_ mode: FleetUIMode) {
        self.mode = mode
        guard !isPinned else { return }
        defaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }
}
