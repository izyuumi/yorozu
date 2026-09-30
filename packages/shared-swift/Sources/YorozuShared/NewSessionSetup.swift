import SwiftUI

/// The unsent session's choices stay beside its composer on every platform.
struct NewSessionSetup: View {
    let model: ChatModel
    let presentation: ThreadPresentation
    let hosts: MultiHostModel?
    let hostID: HostID?
    let chooseAgent: (AgentDescriptor) -> Void
    let chooseProject: () -> Void
    let chooseHost: (HostID) -> Void

    private var secondaryInk: Color { YorozuPalette.ink.opacity(0.72) }
    // The compiled fallback describes old hosts; it cannot prove another agent is set up.
    private var offersAgentChoice: Bool { model.agents?.contains { $0.id != .yorozu } == true }
    private var heading: LocalizedStringKey { offersAgentChoice ? "Who should answer?" : "Start a conversation" }

    private var agents: [AgentDescriptor] {
        let groups = NewThreadPicker.groups(model.availableAgents)
        return groups.assistants + groups.codingAgents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.section) {
            VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                Text(heading)
                    .font(.scaled(.largeTitle).weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(YorozuPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                if offersAgentChoice {
                    Text("Choose an agent. Send a message to begin.")
                        .font(.scaled(.callout))
                        .foregroundStyle(secondaryInk)
                }
            }

            if let hosts, let hostID, let host = hosts.session(for: hostID) {
                if hosts.hasMultipleHosts {
                    VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                        Text("Host").accessibilityAddTraits(.isHeader)
                        Menu {
                            ForEach(hosts.sessions) { choice in
                                Button { chooseHost(choice.id) } label: {
                                    if choice.id == hostID {
                                        Label(hosts.label(for: choice), systemImage: "checkmark")
                                    } else {
                                        Text(hosts.label(for: choice))
                                    }
                                }
                                .disabled(needsUpdate(choice.model))
                            }
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading) {
                                    Text(hosts.label(for: host))
                                    hostStatus(host.model)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down")
                                    .foregroundStyle(secondaryInk)
                            }
                            .frame(maxWidth: .infinity, minHeight: controlTarget, alignment: .leading)
                            .padding(LayoutMetrics.cardPadding)
                            .background(YorozuPalette.paper, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose host")
                        .accessibilityValue(hosts.label(for: host))
                        .accessibilityHint("The Mac that will receive this session")
                    }
                } else if !host.model.canDeliver || needsUpdate(host.model) {
                    hostStatus(host.model)
                }
            }

            if offersAgentChoice {
                VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                    Text("Agent").accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(agents) { descriptor in
                            if descriptor.id != agents.first?.id { Divider() }
                            agentRow(descriptor)
                        }
                    }
                    .background(YorozuPalette.paper)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius))
                }
            }

            if presentation.needsFolder {
                VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                    Text("Project").accessibilityAddTraits(.isHeader)
                    Button(action: chooseProject) {
                        HStack {
                            Image(systemName: "folder")
                            VStack(alignment: .leading) {
                                Text(presentation.projectName ?? String(localized: "Choose a project folder"))
                                if let path = presentation.projectPath {
                                    Text(path)
                                        .font(.scaled(.caption).monospaced())
                                        .foregroundStyle(secondaryInk)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(secondaryInk)
                        }
                        .frame(maxWidth: .infinity, minHeight: controlTarget, alignment: .leading)
                        .padding(LayoutMetrics.cardPadding)
                        .background(YorozuPalette.paper, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose project")
                    .accessibilityValue(presentation.projectPath ?? "")
                }
            }
        }
        .font(.scaled(.body))
        .foregroundStyle(YorozuPalette.ink)
        .frame(maxWidth: LayoutMetrics.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func agentRow(_ descriptor: AgentDescriptor) -> some View {
        let selected = descriptor.id == presentation.agent
        let summary: String
        switch descriptor.id {
        case .yorozu: summary = String(localized: "Everyday tasks, files, mail, and more.")
        case .claudeCode: summary = String(localized: "Anthropic’s coding agent.")
        case .codex: summary = String(localized: "OpenAI’s coding agent.")
        default: summary = descriptor.description ?? ""
        }
        let label = ThreadAgent.allCases.contains(descriptor.id) ? descriptor.id.label : descriptor.label
        return Button { chooseAgent(descriptor) } label: {
            HStack(spacing: LayoutMetrics.stack) {
                YorozuGlyphTile {
                    if descriptor.id == .yorozu { YorozuMark() } else { AgentMarkView(descriptor.id) }
                }
                VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                    Text(label).font(.scaled(.headline))
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.scaled(.subheadline))
                            .foregroundStyle(secondaryInk)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? YorozuPalette.vermilion : YorozuPalette.rule)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: controlTarget, alignment: .leading)
            .padding(LayoutMetrics.cardPadding)
            .background(selected ? YorozuPalette.vermilion.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(needsUpdate(model))
        .accessibilityLabel(summary.isEmpty ? label : "\(label), \(summary)")
        .accessibilityValue(selected ? String(localized: "Selected") : String(localized: "Not selected"))
        .accessibilityIdentifier("session-agent-\(descriptor.id.rawValue)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(descriptor.needsFolder ? String(localized: "Choose a project folder for this agent") : String(localized: "Use this agent for the session"))
    }

    private func needsUpdate(_ model: ChatModel) -> Bool {
        if case .updateRequired = model.compatibility { return true }
        return false
    }

    @ViewBuilder private func hostStatus(_ model: ChatModel) -> some View {
        if needsUpdate(model) {
            Label("Update required — see Settings", systemImage: "exclamationmark.circle")
                .font(.scaled(.caption))
                .foregroundStyle(YorozuPalette.warning)
        } else if !model.canDeliver {
            Label("Mac offline — messages will queue", systemImage: "wifi.slash")
                .font(.scaled(.caption))
                .foregroundStyle(secondaryInk)
        } else {
            YorozuStatusLabel(String(localized: "Connected"), tint: YorozuPalette.sage)
                .font(.scaled(.caption))
        }
    }
}
