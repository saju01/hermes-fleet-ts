import SwiftUI
import FleetCore

/// Simple mode root: one chat, Muse-style. Composer with model chip,
/// thinking chip and send/stop; a live browser card when the agent drives
/// the browser (Bot Desktop), opening a full-screen viewer with Take control
/// / Hand back. "Advanced" switches to the existing four-tab shell.
public struct SimpleRootView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let modeController: FleetUIModeController
    private let onOpenSettings: () -> Void

    @State private var viewModel: ConversationViewModel?
    @State private var chatGeneration = 0
    @State private var composerText = ""
    @State private var showingModelPicker = false
    @State private var displayModel: DisplayViewerModel?
    @State private var showingTakeover = false
    @FocusState private var composerFocused: Bool

    public init(environment: AppEnvironment,
                modeController: FleetUIModeController,
                onOpenSettings: @escaping () -> Void = {}) {
        self.environment = environment
        self.modeController = modeController
        self.onOpenSettings = onOpenSettings
    }

    @AppStorage("fleet.simple.gateway.v1") private var storedGatewayID = ""

    /// The gateway Simple mode talks to (its `default` profile): the
    /// persisted pick when still registered, else a connected gateway, else
    /// the first registered one. Advanced keeps full multi-gateway routing.
    private var gateway: FleetGateway? {
        let all = environment.gateways
        if let stored = all.first(where: { $0.id.rawValue == storedGatewayID }) { return stored }
        if let live = all.first(where: { environment.connectionStates[$0.id] == .connected }) { return live }
        return all.first
    }

    private var route: Route? {
        guard let gateway else { return nil }
        return Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "default"))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let viewModel {
                    transcript(viewModel)
                    composer(viewModel)
                } else {
                    ContentUnavailableView("No gateway", systemImage: "server.rack",
                                           description: Text("Add a Hermes gateway in Advanced."))
                }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(gateway?.displayName ?? "Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if environment.gateways.count > 1 {
                            Picker("Gateway", selection: Binding(
                                get: { gateway?.id.rawValue ?? "" },
                                set: { storedGatewayID = $0; newChat() }
                            )) {
                                ForEach(environment.gateways, id: \.id) { gw in
                                    Text(gw.displayName).tag(gw.id.rawValue)
                                }
                            }
                            .accessibilityIdentifier("simple.menu.gateway")
                        }
                        Button("Settings", systemImage: "gearshape") { onOpenSettings() }
                            .accessibilityIdentifier("simple.menu.settings")
                        Button("Advanced", systemImage: "square.grid.2x2") {
                            modeController.setMode(.advanced)
                        }
                        .accessibilityIdentifier("simple.advanced")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("simple.menu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                        .accessibilityIdentifier("simple.newchat")
                }
            }
        }
        .task(id: chatGeneration) { await openChat() }
        .sheet(isPresented: $showingModelPicker) {
            if let tooling = viewModel?.toolingViewModel {
                ModelPickerSheet(model: tooling) { _ in restartIfEmpty() }
            }
        }
        .fullScreenCover(isPresented: $showingTakeover, onDismiss: {
            displayModel?.close()
        }) {
            if let displayModel {
                DisplayTakeoverView(model: displayModel)
            }
        }
        .accessibilityIdentifier("simple.root")
    }

    // MARK: Chat lifecycle

    private func openChat() async {
        guard let route else { viewModel = nil; return }
        let vm = environment.makeConversationViewModel(route: route, sessionID: nil)
        viewModel = vm
        if let session = environment.conversationSession(for: route.gatewayID) as? BotDisplayCapable {
            displayModel = DisplayViewerModel(display: session.display, profile: route.profileSlug.rawValue)
        } else {
            displayModel = nil
        }
        await vm?.start()
        await vm?.toolingViewModel?.loadModelChoices()
    }

    private func newChat() {
        viewModel?.teardown()
        composerText = ""
        chatGeneration += 1
    }

    /// Model/effort ride `session.create`, so a pick applies to a fresh chat;
    /// an untouched chat is restarted so the pick takes effect now.
    private func restartIfEmpty() {
        if viewModel?.transcript.contains(where: { $0.kind == .user }) != true { newChat() }
    }

    // MARK: Transcript

    private func transcript(_ vm: ConversationViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    if vm.transcript.isEmpty {
                        Text("What should Hermes do?")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                            .accessibilityIdentifier("simple.empty")
                    }
                    ForEach(displayRows(vm.transcript)) { item in
                        switch item {
                        case .row(let row):
                            SimpleRowView(row: row)
                        case .browser(let id, let detail):
                            if let displayModel {
                                BrowserCardView(model: displayModel, detail: detail) {
                                    showingTakeover = true
                                }
                                .id(id)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("simple.bottom")
                }
                .padding(FleetTheme.spacingLg)
            }
            .onChange(of: vm.transcript.count) { _, _ in
                withAnimation { proxy.scrollTo("simple.bottom", anchor: .bottom) }
            }
            .accessibilityIdentifier("simple.transcript")
        }
    }

    enum Item: Identifiable {
        case row(ConversationRow)
        case browser(id: String, detail: String?)
        var id: String {
            switch self {
            case .row(let r): r.id
            case .browser(let id, _): id
            }
        }
    }

    /// Tool rows are hidden in Simple mode except browser tools, which
    /// collapse into ONE live browser card per run of consecutive browser
    /// steps (the card shows the latest step).
    func displayRows(_ rows: [ConversationRow]) -> [Item] {
        var items: [Item] = []
        for row in rows {
            if row.kind == .tool {
                guard SimpleTranscript.isBrowserTool(row.text) else { continue }
                if case .browser(let id, _) = items.last {
                    items[items.count - 1] = .browser(id: id, detail: row.detail ?? row.text)
                } else {
                    items.append(.browser(id: "browser-\(row.id)", detail: row.detail ?? row.text))
                }
                continue
            }
            if row.kind == .status { continue }
            items.append(.row(row))
        }
        return items
    }

    // MARK: Composer

    private func composer(_ vm: ConversationViewModel) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            HStack(spacing: FleetTheme.spacingSm) {
                modelChip(vm)
                thinkingChip(vm)
                Spacer()
            }
            HStack(alignment: .bottom, spacing: FleetTheme.spacingSm) {
                TextField("Ask Hermes", text: $composerText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, FleetTheme.spacingMd)
                    .padding(.vertical, FleetTheme.spacingSm)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("simple.composer")
                if vm.isStreaming {
                    Button {
                        Task { await vm.interrupt() }
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30))
                    }
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("simple.stop")
                } else {
                    Button {
                        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        composerText = ""
                        Task { _ = await vm.send(text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.phase != .ready)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("simple.send")
                }
            }
        }
        .padding(FleetTheme.spacingMd)
        .background(theme.background)
    }

    private func chipLabel(_ systemImage: String, _ text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(FleetTheme.monoCaptionFont).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(active ? theme.highlight : theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.surface, in: Capsule())
    }

    private func modelChip(_ vm: ConversationViewModel) -> some View {
        Button { showingModelPicker = true } label: {
            chipLabel("cpu",
                      vm.toolingViewModel?.selectedModel?.shortName
                        ?? vm.sessionModel?.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) }
                        ?? "Model",
                      active: vm.toolingViewModel?.selectedModel != nil)
        }
        .disabled(vm.toolingViewModel == nil)
        .accessibilityLabel("Model")
        .accessibilityValue(vm.toolingViewModel?.selectedModel?.model ?? "profile default")
        .accessibilityIdentifier("simple.chip.model")
    }

    @ViewBuilder private func thinkingChip(_ vm: ConversationViewModel) -> some View {
        if let tooling = vm.toolingViewModel, !tooling.availableEfforts.isEmpty {
            Menu {
                Button {
                    tooling.selectEffort(nil); restartIfEmpty()
                } label: {
                    Label("Profile default", systemImage: tooling.selectedEffort == nil ? "checkmark" : "")
                }
                .accessibilityIdentifier("simple.thinking.default")
                ForEach(tooling.availableEfforts) { effort in
                    Button {
                        tooling.selectEffort(effort); restartIfEmpty()
                    } label: {
                        Label(effort.label, systemImage: tooling.selectedEffort == effort ? "checkmark" : "")
                    }
                    .accessibilityIdentifier("simple.thinking.\(effort.rawValue)")
                }
            } label: {
                chipLabel("brain", tooling.selectedEffort?.label ?? "Thinking", active: tooling.selectedEffort != nil)
            }
            .accessibilityLabel("Thinking effort")
            .accessibilityValue(tooling.selectedEffort?.label ?? "profile default")
            .accessibilityIdentifier("simple.chip.thinking")
        }
    }
}

public enum SimpleTranscript {
    /// Browser tool names (tools/browser_*). Vault/credential helpers are
    /// excluded: they never drive the visible page.
    public static func isBrowserTool(_ name: String) -> Bool {
        name.hasPrefix("browser_") && !name.hasPrefix("browser_vault")
    }
}

private struct SimpleRowView: View {
    @Environment(\.fleetTheme) private var theme
    let row: ConversationRow

    var body: some View {
        HStack {
            if row.kind == .user { Spacer(minLength: 48) }
            Group {
                switch row.kind {
                case .assistant:
                    if row.text.isEmpty && row.isStreaming {
                        Text("…")
                    } else {
                        AssistantRichTextView(markdown: row.text, isStreaming: row.isStreaming, identity: row.id)
                    }
                case .error:
                    Text(row.text).foregroundStyle(FleetTheme.statusDestructive)
                default:
                    Text(row.text)
                }
            }
            .padding(.horizontal, FleetTheme.spacingMd)
            .padding(.vertical, FleetTheme.spacingSm)
            .background(row.kind == .user ? theme.surface : Color.clear,
                        in: RoundedRectangle(cornerRadius: FleetTheme.radiusBubble))
            if row.kind != .user { Spacer(minLength: 24) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("simple.row.\(row.kind)")
    }
}

/// The live browser card: thumbnail (polled while visible) + Watch / Take
/// control. Thumbnails are withheld by the gateway while a human holds the
/// lease, which the card says plainly.
struct BrowserCardView: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var model: DisplayViewerModel
    let detail: String?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text("Browser").font(.subheadline.weight(.semibold))
                Spacer()
                if let detail {
                    Text(detail).font(FleetTheme.monoCaptionFont).foregroundStyle(theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85))
                if let image = model.thumbnail {
                    Image(image, scale: 1, label: Text("Browser preview")).resizable().scaledToFit()
                        .accessibilityIdentifier("simple.browser.thumbnail")
                } else if let suppressed = model.thumbnailSuppressed {
                    Text(suppressed == "human" ? "You're in control" : "Preview hidden")
                        .font(.footnote).foregroundStyle(.white.opacity(0.8))
                } else if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.white.opacity(0.8)).padding()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Watch") {
                    model.watch(); open()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("simple.browser.watch")
                Button("Take control") {
                    model.startInControl(); open()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("simple.browser.takecontrol")
            }
        }
        .padding(FleetTheme.spacingMd)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: FleetTheme.radiusCard))
        .task {
            while !Task.isCancelled {
                await model.refreshThumbnail()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple.browser.card")
    }
}
