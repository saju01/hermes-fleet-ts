import SwiftUI
import FleetUI

/// Composition root for Hermes Fleet.
///
/// Builds the observable `AppEnvironment` runtime and injects it into the
/// navigation shell. This is the only app-level surface that wires concrete
/// networking services into the application; SwiftUI remains behind the
/// FleetCore seams enforced by `ModuleBoundaryTests`.
///
/// The root also owns the biometric app-lock controller and forwards
/// `scenePhase` so protected content is gated when the app returns to the
/// foreground. Keychain reads retain their platform at-rest protection.
@main
struct HermesFleetApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var environment = FleetServiceGraph.makeDefaultEnvironment()
    @State private var lockController = FleetServiceGraph.makeLockController()
    // FOS-3 (§12): System/Light/Dark appearance preference applied at the
    // app root (nil = System — defer to the device setting).
    @State private var appearanceController = FleetAppearanceController.shared
    @State private var themeController = FleetThemeController.shared

    var body: some Scene {
        WindowGroup {
            FleetThemeRoot(controller: themeController) {
                ZStack {
                    FleetTabView(environment: environment, lockController: lockController)
                        .task {
                            // Authenticate before touching the registry,
                            // cache, or roster. Protected content must not
                            // be hydrated while the lock screen is showing.
                            await lockController.authenticateIfNeeded()
                            guard !lockController.isLocked else { return }
                            await environment.hydrateIfNeeded()
                        }

                    // Continue the launch artwork past the native LaunchScreen
                    // for a guaranteed minimum display window, then cross-fade
                    // into the app UI. UI tests can skip or explicitly opt in.
                    if SplashOverlayView.isEnabled {
                        SplashOverlayView()
                    }

                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-issue6-theme-proof") {
                        FleetThemeProofView()
                            .allowsHitTesting(false)
                    }
                    #endif
                }
            }
            // FOS-3: apply the persisted appearance override app-wide.
            .preferredColorScheme(appearanceController.selection.colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            lockController.handleScenePhase(phase)
            if phase == .background {
                Task { try? await environment.embeddedTailnet?.suspend() }
            }
            if phase == .active && !lockController.isLocked {
                Task {
                    try? await environment.embeddedTailnet?.resume()
                    await environment.restoreIntendedConnections()
                }
            }
        }
        .onChange(of: lockController.isLocked) { _, isLocked in
            if isLocked {
                // App Lock gates presentation. It is not a user disconnect
                // and must not clear desired gateway connection intent.
            } else {
                // Biometric failure enters passcode fallback. The initial
                // launch task has already returned at that point, so the
                // unlock transition must resume protected hydration.
                Task {
                    await environment.hydrateIfNeeded()
                    try? await environment.embeddedTailnet?.resume()
                    await environment.restoreIntendedConnections()
                }
            }
        }
    }
}
