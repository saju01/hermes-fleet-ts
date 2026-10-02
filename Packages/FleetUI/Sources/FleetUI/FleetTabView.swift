import SwiftUI
import FleetCore

public enum FleetTab: String, Hashable, Sendable, CaseIterable, Identifiable, Codable {
    case fleet, chats, bots, gateways
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .fleet: "Fleet"
        case .chats: "Chats"
        case .bots: "Bots"
        case .gateways: "Gateways"
        }
    }
    public var systemImage: String {
        switch self {
        case .fleet: "square.grid.2x2"
        case .chats: "bubble.left.and.bubble.right"
        case .bots: "cpu"
        case .gateways: "server.rack"
        }
    }
}

/// Adaptive system navigation; every tab owns its stack and the lock gate owns all content.
public struct FleetTabView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let lockController: AppLockController
    private let modeController: FleetUIModeController?
    @State private var navigation = FleetNavigationState()
    @State private var showingSettings = false
    @State private var restored = false
    @State private var showingCommandCenter = false
    @State private var autoNavHandled = false

    /// - Parameter modeController: Simple-mode gate. nil = always the tab
    ///   shell (previews/tests that predate Simple mode).
    public init(environment: AppEnvironment, lockController: AppLockController,
                modeController: FleetUIModeController? = nil) {
        self.environment = environment
        self.lockController = lockController
        self.modeController = modeController
    }

    public var body: some View {
        Group {
            if lockController.isLocked {
                AppLockView(controller: lockController)
            } else {
                // First-run gate (Hermex-style lifecycle): before the
                // registry has hydrated we show the launch continuation (the
                // splash overlay covers this window on cold launch); once
                // hydration settles, a ZERO-gateway fleet lands on the
                // first-server setup experience INSTEAD of the normal tab
                // UI — a brand-new user must understand Fleet needs a Hermes
                // server before entering the cockpit. The gate is driven by
                // the hydrated registry itself (no hasSeenOnboarding flag):
                // registering the first gateway swaps in the normal app, and
                // removing the final gateway returns to setup (intended).
                switch environment.hydrationPhase {
                case .loading:
                    ProgressView("Starting…")
                        .accessibilityIdentifier("fleet.root.loading")
                case .unconfigured:
                    FirstRunSetupView(environment: environment)
                case .configured:
                    if let modeController, modeController.mode == .simple {
                        SimpleRootView(environment: environment, modeController: modeController) {
                            showingSettings = true
                        }
                    } else {
                        tabShell
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                FleetSettingsView(controller: lockController, environment: environment, modeController: modeController)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                                .accessibilityIdentifier("fleet.settings.done")
                        }
                    }
            }
        }
        .onChange(of: navigation) { _, state in
            guard restored else { return }
            if let data = try? JSONEncoder().encode(state) {
                UserDefaults.standard.set(data, forKey: FleetNavigationState.storageKey)
            }
        }
        .tint(theme.highlight)
        .onChange(of: lockController.isLocked) { if lockController.isLocked { showingCommandCenter = false; showingSettings = false } }
        .onChange(of: environment.pendingBotChatNavigation) { target in
            guard let target else { return }
            navigation.open(target)
            environment.pendingBotChatNavigation = nil
        }
        .onChange(of: environment.pendingScreenNavigation) { target in
            guard let target else { return }
            navigation.open(target)
            environment.pendingScreenNavigation = nil
        }
        .task {
            if !restored {
                if ProcessInfo.processInfo.environment["HERMES_FLEET_AUTO_NAV"] == nil && ProcessInfo.processInfo.environment["HERMES_FLEET_NAV_RESET"] != "1" {
                    navigation = .restore(UserDefaults.standard.data(forKey: FleetNavigationState.storageKey))
                }
                restored = true
            }
            // UI-test hygiene: NAV_RESET also clears persisted explicit
            // profile selections so the §8 chooser deterministically renders
            // (a stored choice would otherwise skip straight into the pane).
            if ProcessInfo.processInfo.environment["HERMES_FLEET_NAV_RESET"] == "1" {
                GatewayResourceView.resetStoredSelections()
            }
            await performAutoNavIfNeeded()
        }
    }

    /// The normal four-tab Fleet application (configured state).
    private var tabShell: some View {
        TabView(selection: Binding(get: { navigation.selection }, set: { tab in
            navigation.selection = tab
        })) {
            ForEach(FleetTab.allCases) { tab in
                Tab(tab.label, systemImage: tab.systemImage, value: tab) {
                    NavigationStack(path: Binding(get: { navigation.paths[tab] ?? [] }, set: { path in
                        if let target = path.last, path.count > (navigation.paths[tab]?.count ?? 0) { navigation.open(target) }
                        else { navigation.paths[tab] = path }
                    })) {
                        root(tab)
                            .navigationDestination(for: FleetScreen.self) { destination($0) }
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    if tab == .fleet {
                                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                                            .accessibilityIdentifier("fleet.settings.open")
                                    }
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Command Center", systemImage: "magnifyingglass") { showingCommandCenter = true }
                                        .accessibilityIdentifier("fleet.command-center.open")
                                        .keyboardShortcut("k", modifiers: .command)
                                }
                            }
                    }
                    .accessibilityIdentifier("fleet.tab.\(tab.rawValue)")
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $showingCommandCenter) {
            FleetCommandCenter(environment: environment, navigate: { screen in
                navigation.open(screen)
            }, selectTab: { navigation.selection = $0 }, openSettings: {
                showingSettings = true
            })
        }
    }

    @ViewBuilder private func root(_ tab: FleetTab) -> some View {
        switch tab {
        case .fleet: FleetDashboardView(environment: environment)
        case .chats: FleetChatsView(environment: environment)
        case .bots: FleetRosterView(environment: environment)
        case .gateways: GatewaysView(environment: environment)
        }
    }

    @ViewBuilder
    private func destination(_ screen: FleetScreen) -> some View {
        if let id = screen.gatewayID, !environment.gateways.contains(where: { $0.id == id }), screen != .gatewayConnection(id) {
            ContentUnavailableView("Gateway unavailable", systemImage: "server.rack", description: Text("This saved destination belongs to a gateway that is no longer registered."))
        } else {
        switch screen {
        case .bots(let gatewayID):
            FleetRosterView(environment: environment, gatewayID: gatewayID)
        case .roster:
            FleetRosterView(environment: environment)
        case .botDetail(let route):
            BotDetailView(environment: environment, route: route)
        case .botRoutines(let route):
            BotRoutinesView(environment: environment, route: route)
        case .room(let id):
            if let room = environment.rooms(for: id.gatewayID).first(where: { $0.id == id }) {
                RoomChatView(room: room, environment: environment)
            } else {
                ContentUnavailableView("Group unavailable", systemImage: "person.3", description: Text("This exact group has not been resolved. Refresh its gateway to try again."))
            }
        case .conversation(let route, let sessionID, _):
            ConversationView(environment: environment, route: route, sessionID: sessionID)
        case .health:
            HealthDashboardView(environment: environment)
        case .gateways:
            GatewaysView(environment: environment)
        case .activity:
            FleetActivityView(environment: environment)
        case .gatewayDetail(let id):
            GatewayDetailView(environment: environment, gatewayID: id)
        case .gatewayConnection(let id):
            GatewaysView(environment: environment, connectionGatewayID: id)
        case .gatewayGroups(let id):
            GatewayGroupsView(environment: environment, gatewayID: id)
        case .gatewayHealth(let id):
            HealthDashboardView(environment: environment, gatewayID: id)
        case .kanban:
            List(environment.gateways) { gateway in
                NavigationLink(gateway.displayName, value: FleetScreen.gatewayKanban(gateway.id))
                    .accessibilityIdentifier("fleet.kanban.gateway.\(gateway.id.rawValue)")
            }.navigationTitle("Choose gateway")
        case .gatewayKanban(let id, let board):
            KanbanBoardView(environment: environment, gatewayID: id, board: board)
        case .cron(let id, let profile), .skills(let id, let profile), .memoryGraph(let id, let profile), .projects(let id, let profile, _):
            GatewayResourceView(environment: environment, gatewayID: id, screen: screen, profile: profile, focusPath: screen.focusPath) { selected in
                let scoped: FleetScreen
                switch screen {
                case .cron: scoped = .cron(id, profile: selected)
                case .skills: scoped = .skills(id, profile: selected)
                case .memoryGraph: scoped = .memoryGraph(id, profile: selected)
                case .projects(_, _, let path): scoped = .projects(id, profile: selected, focusPath: path)
                default: return
                }
                if let index = navigation.paths[.gateways]?.firstIndex(of: screen) {
                    navigation.paths[.gateways]?[index] = scoped
                }
            }
        }
        }
    }

    @MainActor private func performAutoNavIfNeeded() async {
        #if DEBUG
        guard !autoNavHandled, let autoNav = ProcessInfo.processInfo.environment["HERMES_FLEET_AUTO_NAV"] else { return }
        autoNavHandled = true
        await environment.load()
        await environment.refreshRoster()
        if let tab = FleetNavigationState.legacyTab(autoNav) { navigation.selection = tab }
        if autoNav == "command-center" { showingCommandCenter = true }
        if autoNav == "settings" { showingSettings = true }
        if autoNav == "kanban" { navigation.open(.kanban) }
        // Test automation specifies a stable fixture identity; it never picks a machine by order.
        if let gateway = environment.gateways.first(where: { $0.id.rawValue == "workstation" }) {
            switch autoNav {
            case "cron": navigation.open(.cron(gateway.id))
            case "skills": navigation.open(.skills(gateway.id))
            case "memory": navigation.open(.memoryGraph(gateway.id))
            case "projects", "workspace": navigation.open(.projects(gateway.id))
            case "bot-detail":
                if let bot = environment.rosterSnapshot?.roster.allBots.first(where: { $0.route.gatewayID == gateway.id && $0.route.profileSlug.rawValue == "default" }) {
                    navigation.open(.botDetail(bot.route))
                }
            default: break
            }
        }
        #endif
    }
}
