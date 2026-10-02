import SwiftUI
import FleetCore

/// R9-T2 — model picker sheet: search, current-model checkmark, mono model
/// ids (Nous terminal-minimal Direction A). The selection is STICKY
/// PER-DEVICE and SESSION-SCOPED: it rides `session.create {model,
/// provider}` only — never `config.set`, never the profile default (the
/// desktop rule; methods_session.py:50-53).
public struct ModelPickerSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Bindable var model: ConversationToolingViewModel
    /// Called with the picked choice (or nil = follow profile default).
    let onPick: (ModelChoice?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    public init(
        model: ConversationToolingViewModel,
        onPick: @escaping (ModelChoice?) -> Void
    ) {
        self.model = model
        self.onPick = onPick
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.isLoadingModels && model.modelChoices == nil {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                } else if let error = model.modelLoadError, model.modelChoices == nil {
                    ContentUnavailableView {
                        Label("Models Unavailable", systemImage: "cpu")
                    } description: {
                        Text(error)
                    }
                } else if filteredChoices.isEmpty {
                    ContentUnavailableView {
                        Label("No Models Found", systemImage: "magnifyingglass")
                    } description: {
                        if searchText.isEmpty {
                            Text("This gateway reported no models.")
                        } else {
                            Text("No model matches this search.")
                        }
                    }
                } else {
                    choicesList
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .background(theme.background.ignoresSafeArea())
            .searchable(text: $searchText, prompt: "Search models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(theme.highlight)
                        .accessibilityIdentifier("model.picker.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // The explicit "follow default" reset — sticky pick off.
                    Button("Reset") {
                        model.select(nil)
                        onPick(nil)
                    }
                    .foregroundStyle(theme.highlight)
                    .disabled(model.selectedModel == nil)
                    .accessibilityLabel("Reset to profile default model")
                    .accessibilityIdentifier("model.picker.reset")
                }
            }
            .task {
                // Fresh list on every open (provider inventories move).
                await model.loadModelChoices()
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("model.picker.sheet")
    }

    /// Rows matching the current search (model id OR provider name,
    /// case-insensitive). The gateway's current model stays findable.
    private var filteredChoices: [ModelChoice] {
        let choices = model.modelChoices ?? []
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return choices }
        return choices.filter {
            $0.model.lowercased().contains(query) || $0.providerName.lowercased().contains(query)
        }
    }

    private var choicesList: some View {
        ScrollView {
            LazyVStack(spacing: FleetTheme.spacingXs, pinnedViews: [.sectionHeaders]) {
                // Sticky selection banner (what the NEXT new chat will use).
                if let selected = model.selectedModel {
                    selectedBanner(selected)
                }
                if !model.availableEfforts.isEmpty {
                    effortRow
                }
                ForEach(groupedByProvider, id: \.slug) { group in
                    Section {
                        ForEach(group.rows) { choice in
                            row(choice)
                        }
                    } header: {
                        HStack(spacing: FleetTheme.spacingSm) {
                            Text(group.name.isEmpty ? group.slug : group.name)
                                .font(FleetTheme.sectionHeaderFont)
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                            Text(group.slug)
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textMuted)
                        }
                        .padding(.horizontal, FleetTheme.spacingLg)
                        .padding(.vertical, FleetTheme.spacingSm)
                        .background(theme.surface)
                        .accessibilityElement(children: .combine)
                    }
                }
                if let error = model.modelLoadError {
                    Text("Live refresh failed — showing the last list. \(error)")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.statusDegraded)
                        .padding(FleetTheme.spacingLg)
                }
            }
            .padding(.vertical, FleetTheme.spacingSm)
        }
    }

    /// Thinking effort for new chats (sticky per-device; rides
    /// `session.create {reasoning_effort}` as a level string, never a token
    /// budget). Levels follow the model capabilities from model.options.
    private var effortRow: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Text("Thinking")
                .font(FleetTheme.microLabelFont)
                .foregroundStyle(theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FleetTheme.spacingXs) {
                    effortButton(nil, label: "Default")
                    ForEach(model.availableEfforts) { effortButton($0, label: $0.label) }
                }
            }
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.top, FleetTheme.spacingSm)
        .accessibilityIdentifier("model.picker.effort")
    }

    private func effortButton(_ effort: ReasoningEffort?, label: String) -> some View {
        let selected = model.selectedEffort == effort
        return Button {
            model.selectEffort(effort)
        } label: {
            Text(label)
                .font(FleetTheme.secondaryFont)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? theme.highlight : theme.textPrimary)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().stroke(selected ? theme.highlight : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("model.picker.effort.\(effort?.rawValue ?? "default")")
    }

    /// The sticky-pick banner shown at the top of the list.
    private func selectedBanner(_ selected: ModelChoice) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(theme.highlight)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sticky pick — new chats on this device")
                    .font(FleetTheme.microLabelFont)
                    .foregroundStyle(theme.textSecondary)
                Text(selected.model)
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Clear") {
                model.select(nil)
                onPick(nil)
            }
            .font(FleetTheme.secondaryFont)
            .foregroundStyle(theme.highlight)
            .accessibilityIdentifier("model.picker.clear")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.top, FleetTheme.spacingSm)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("model.picker.sticky")
    }

    private func row(_ choice: ModelChoice) -> some View {
        Button {
            model.select(choice)
            onPick(choice)
            dismiss()
        } label: {
            HStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: choice.isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(choice.isCurrent ? theme.highlight : theme.textMuted)
                    .accessibilityHidden(true)
                Text(choice.model)
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if choice.isCurrent {
                    Text("Current")
                        .font(FleetTheme.microLabelFont)
                        .foregroundStyle(theme.textMuted)
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingSm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fleetPressable)
        .accessibilityLabel("\(choice.model), \(choice.providerName)")
        .accessibilityValue(accessibilityValue(for: choice))
        .accessibilityHint("Sets the model for new chats on this device")
        .accessibilityIdentifier("model.picker.row.\(choice.id)")
    }

    private func accessibilityValue(for choice: ModelChoice) -> String {
        var parts: [String] = []
        if choice.isCurrent { parts.append("gateway current") }
        if model.selectedModel?.id == choice.id { parts.append("sticky pick") }
        return parts.joined(separator: ", ")
    }

    /// Provider grouping preserving the gateway's row order.
    private var groupedByProvider: [(slug: String, name: String, rows: [ModelChoice])] {
        guard !filteredChoices.isEmpty else { return [] }
        var order: [String] = []
        var bySlug: [String: (name: String, rows: [ModelChoice])] = [:]
        for choice in filteredChoices {
            if bySlug[choice.provider] == nil {
                bySlug[choice.provider] = (choice.providerName, [])
                order.append(choice.provider)
            }
            bySlug[choice.provider]?.rows.append(choice)
        }
        return order.map { slug in (slug, bySlug[slug]!.name, bySlug[slug]!.rows) }
    }
}
