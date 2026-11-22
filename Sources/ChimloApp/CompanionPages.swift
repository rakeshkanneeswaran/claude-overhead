import AppKit
import ChimloCore
import SwiftUI

struct CompanionPage: View {
    let section: CompanionSection
    @ObservedObject var navigation: CompanionNavigation

    var body: some View {
        switch section {
        case .overview: OverviewPage(navigation: navigation)
        case .sessions: SessionsPage(navigation: navigation)
        case .projects: ProjectsPage(navigation: navigation)
        case .agents: AgentsPage()
        case .history: HistoryPage(navigation: navigation)
        case .usage: UsagePage()
        case .github: GitHubPage()
        case .settings: CompanionSettingsView(navigation: navigation)
        }
    }
}

// MARK: - Overview

private struct OverviewPage: View {
    @ObservedObject var navigation: CompanionNavigation
    @EnvironmentObject private var services: OverheadServices
    @EnvironmentObject private var model: ApplicationModel
    @EnvironmentObject private var history: HistoryModel
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var github: GitHubModel
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        let recap = history.recap(for: .now, github: services.recapGitHubInput)
        let live = model.sessions.filter { !$0.isDemo }
        let waiting = live.filter(\.needsAttention)
        PageScaffold(title: "Overview", subtitle: Date.now.formatted(date: .complete, time: .omitted)) {
            HStack(spacing: 12) {
                StatTile(label: "Active sessions", value: "\(live.filter { $0.mood == .working }.count)",
                         detail: "\(live.count) known", tint: palette.working)
                StatTile(label: "Waiting on you", value: "\(waiting.count)",
                         detail: waiting.isEmpty ? "Nothing blocked" : "Permission or question",
                         tint: waiting.isEmpty ? nil : palette.permission)
                StatTile(label: "Completed today", value: "\(recap.sessionsCompleted)",
                         detail: recap.sessionsFailed > 0 ? "\(recap.sessionsFailed) failed" : "No failures")
                StatTile(label: "Reported cost", value: CompanionFormat.cost(recap.costUSD),
                         detail: "From Claude Code, today")
            }

            if !waiting.isEmpty {
                Card("Needs you") {
                    ForEach(waiting) { session in
                        HStack {
                            MoodBadge(mood: session.mood)
                            Text(session.displayTitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(palette.textPrimary)
                            Spacer()
                            Button("Answer in notch") { model.openPanel() }
                            Button("Focus terminal") { services.focusHost(of: session) }
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                if settings.settings.dailyRecapEnabled {
                    Card("Today's recap") {
                        if recap.isEmpty {
                            Text("No sessions yet today.")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textSecondary)
                        } else {
                            ForEach(recap.highlights, id: \.self) { line in
                                Label(line, systemImage: "checkmark.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.textPrimary)
                            }
                            if !recap.projects.isEmpty {
                                KeyValueRow(key: "Projects", value: recap.projects.joined(separator: ", "))
                            }
                            KeyValueRow(key: "Files changed", value: "\(recap.filesChanged)")
                            if let added = recap.linesAdded, let removed = recap.linesRemoved {
                                KeyValueRow(key: "Lines", value: "+\(added) / -\(removed)")
                            }
                            if recap.agentsUsed > 0 {
                                KeyValueRow(key: "Agents used", value: "\(recap.agentsUsed)")
                            }
                        }
                    }
                }
                VStack(spacing: 12) {
                    UsageGlance()
                    if settings.settings.github.enabled {
                        Card("GitHub") {
                            KeyValueRow(key: "Reviews waiting", value: "\(github.reviewRequests.count)")
                            KeyValueRow(key: "Failing CI", value: "\(failingPRs)")
                            Button("Open GitHub") { navigation.section = .github }
                        }
                    }
                }
            }

            Card("Recent notifications") {
                if services.attention.recent.isEmpty {
                    Text("Nothing yet. Permission requests, completions and warnings appear here.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                } else {
                    ForEach(services.attention.recent.prefix(8)) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.kind.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.textPrimary)
                                .frame(width: 170, alignment: .leading)
                            Text("\(item.title) · \(item.body)")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            Text(CompanionFormat.relative(item.at))
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private var failingPRs: Int {
        github.repositories.flatMap(\.pullRequests).filter { $0.ciState == .failure }.count
    }
}

private struct UsageGlance: View {
    @EnvironmentObject private var model: ApplicationModel
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        Card("Claude usage") {
            if let snapshot = model.capacitySnapshots[.claude], !snapshot.windows.isEmpty {
                ForEach(snapshot.windows) { window in
                    HStack {
                        Text(window.kind == .weekly ? "Weekly" : "5-hour")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 60, alignment: .leading)
                        ThresholdMeter(
                            fraction: window.usedPercentage / 100,
                            attentionAt: settings.settings.usageWarningThreshold,
                            criticalAt: min(0.99, settings.settings.usageWarningThreshold + 0.1)
                        )
                        Spacer()
                        if settings.settings.showResetCountdowns, let reset = window.resetsAt {
                            Text("resets \(CompanionFormat.relative(reset))")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textTertiary)
                        }
                    }
                }
            } else {
                Text("No usage reading yet. Claude Code reports it through its status line in the terminal.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }
}

// MARK: - Sessions

private struct SessionsPage: View {
    @ObservedObject var navigation: CompanionNavigation
    @EnvironmentObject private var services: OverheadServices
    @EnvironmentObject private var model: ApplicationModel
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette
    @State private var query = ""

    var body: some View {
        let sessions = filtered
        PageScaffold(title: "Sessions", subtitle: "Claude Code sessions on this Mac, live and recent.") {
            HStack {
                TextField("Search sessions, projects, branches", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Toggle("Group by project", isOn: settings.binding(\.groupByProject))
                    .toggleStyle(.checkbox)
                Spacer()
            }
            if sessions.isEmpty {
                EmptyStateView(
                    symbol: "bubble.left.and.bubble.right",
                    title: query.isEmpty ? "No sessions" : "No matches",
                    message: query.isEmpty
                        ? "Start Claude Code in a terminal or editor and it appears here."
                        : "Nothing matches “\(query)”."
                )
            } else if settings.settings.groupByProject {
                ForEach(groups(sessions), id: \.0) { project, members in
                    Card(project) {
                        ForEach(members) { session in
                            SessionLine(session: session, selected: navigation.selectedSessionID == session.id) {
                                navigation.selectedSessionID = session.id
                            }
                        }
                    }
                }
            } else {
                Card {
                    ForEach(sessions) { session in
                        SessionLine(session: session, selected: navigation.selectedSessionID == session.id) {
                            navigation.selectedSessionID = session.id
                        }
                    }
                }
            }
            if let id = navigation.selectedSessionID, let session = model.sessions.first(where: { $0.id == id }) {
                SessionDetailCard(session: session)
            }
        }
    }

    private var filtered: [SessionDisplayModel] {
        let all = model.sessions.filter { !$0.isDemo }
        let sorted: [SessionDisplayModel] = switch settings.settings.sessionSort {
        case .recentActivity: all.sorted { $0.updatedAt > $1.updatedAt }
        case .attentionFirst: all.sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            return lhs.updatedAt > rhs.updatedAt
        }
        case .project: all.sorted { CompanionFormat.projectName($0.projectPath) < CompanionFormat.projectName($1.projectPath) }
        }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { session in
            [session.displayTitle, session.projectPath ?? "", session.insights?.gitBranch ?? "", session.model ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private func groups(_ sessions: [SessionDisplayModel]) -> [(String, [SessionDisplayModel])] {
        let grouped = Dictionary(grouping: sessions) { CompanionFormat.projectName($0.projectPath) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }
}

private struct SessionLine: View {
    let session: SessionDisplayModel
    let selected: Bool
    let select: () -> Void
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                MoodBadge(mood: session.mood).frame(width: 120, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let branch = session.insights?.gitBranch {
                            Label(branch, systemImage: "arrow.triangle.branch")
                        }
                        if let model = session.model { Text(model) }
                        if session.live?.kind == .background { Text("Background") }
                        if session.mood == .working { Text(session.detail) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                }
                Spacer()
                if let fraction = session.insights?.contextFraction {
                    ThresholdMeter(
                        fraction: fraction,
                        attentionAt: settings.settings.contextAttentionThreshold,
                        criticalAt: settings.settings.contextCriticalThreshold,
                        width: 70
                    )
                }
                Text(CompanionFormat.relative(session.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(selected ? palette.accentColor.opacity(0.14) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.displayTitle), \(MoodBadge(mood: session.mood).label)")
    }
}

private struct SessionDetailCard: View {
    let session: SessionDisplayModel
    @EnvironmentObject private var services: OverheadServices
    @EnvironmentObject private var github: GitHubModel
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette
    @State private var resumeResult: String?

    var body: some View {
        let insights = session.insights
        Card(session.displayTitle, trailing: AnyView(actions)) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    KeyValueRow(key: "State", value: MoodBadge(mood: session.mood).label)
                    KeyValueRow(key: "Project", value: session.projectPath ?? "—")
                    KeyValueRow(key: "Branch", value: insights?.gitBranch ?? "—")
                    KeyValueRow(key: "Model", value: session.model ?? insights?.model ?? "—")
                    KeyValueRow(key: "Kind", value: session.live.map { $0.kind == .background ? "Background" : "Interactive" } ?? "—")
                    KeyValueRow(key: "Reported cost", value: CompanionFormat.cost(insights?.cost?.totalUSD))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = insights?.contextFraction {
                        HStack {
                            Text("Context").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                            Spacer()
                            ThresholdMeter(
                                fraction: fraction,
                                attentionAt: settings.settings.contextAttentionThreshold,
                                criticalAt: settings.settings.contextCriticalThreshold
                            )
                        }
                        KeyValueRow(
                            key: "Tokens",
                            value: "\(CompanionFormat.tokens(insights?.contextTokens)) of \(CompanionFormat.tokens(insights?.contextWindowTokens))"
                        )
                    }
                    if let ratio = insights?.cache.hitRatio, settings.settings.showCacheMetrics {
                        KeyValueRow(key: "Prompt cache hits", value: "\(Int((ratio * 100).rounded()))%")
                    }
                    KeyValueRow(key: "Compactions", value: "\(insights?.compactions.count ?? 0)")
                    KeyValueRow(key: "Agents", value: "\(insights?.agents.count ?? 0) (\(insights?.runningAgents.count ?? 0) running)")
                    KeyValueRow(key: "Files touched", value: "\(insights?.filesTouched.count ?? 0)")
                    if let pr = github.pullRequest(for: session) {
                        KeyValueRow(key: "Pull request", value: "#\(pr.number) \(pr.title)")
                    } else if let linked = insights?.pullRequests.last {
                        KeyValueRow(key: "Pull request", value: "#\(linked.number)")
                    }
                }
            }
            if let resumeResult {
                Text(resumeResult).font(.system(size: 11)).foregroundStyle(palette.textSecondary)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Focus terminal") { services.focusHost(of: session) }
            if session.mood == .success || session.mood == .failed || session.mood == .idle {
                Button("Resume in Terminal") {
                    Task {
                        let ok = await services.resume(sessionID: session.id, projectPath: session.projectPath)
                        resumeResult = ok ? "Opened Terminal with claude --resume." : "Could not open Terminal. Is Claude Code installed?"
                    }
                }
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Projects

private struct ProjectsPage: View {
    @ObservedObject var navigation: CompanionNavigation
    @EnvironmentObject private var model: ApplicationModel
    @EnvironmentObject private var history: HistoryModel
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        let live = Set(model.sessions.filter { !$0.isDemo && $0.mood != .idle }.map(\.id))
        let attention = Set(model.sessions.filter(\.needsAttention).map(\.id))
        let pulses = history.pulses(liveSessionIDs: live, attentionSessionIDs: attention)
        PageScaffold(title: "Projects", subtitle: "Project Pulse: what Claude has been doing in each project.") {
            if pulses.isEmpty {
                EmptyStateView(symbol: "folder", title: "No projects yet",
                               message: "Projects appear once Claude Code sessions have run in them.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(pulses) { pulse in
                        Button { navigation.selectedProjectKey = pulse.projectKey } label: {
                            PulseCard(pulse: pulse, selected: navigation.selectedProjectKey == pulse.projectKey)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let key = navigation.selectedProjectKey,
                   let pulse = pulses.first(where: { $0.projectKey == key }) {
                    Card("Timeline · \(pulse.name)") {
                        let entries = history.timeline(projectKey: key)
                        if entries.isEmpty {
                            Text("No timeline entries yet.").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                        }
                        ForEach(entries.reversed().prefix(60)) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: symbol(entry.kind)).foregroundStyle(palette.accentColor).frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.textPrimary)
                                    if let detail = entry.detail {
                                        Text(detail).font(.system(size: 11)).foregroundStyle(palette.textSecondary).lineLimit(2)
                                    }
                                }
                                Spacer()
                                Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11)).foregroundStyle(palette.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func symbol(_ kind: ProjectTimelineEntry.Kind) -> String {
        switch kind {
        case .sessionStarted: "play.circle"
        case .sessionCompleted: "checkmark.circle"
        case .sessionFailed: "xmark.octagon"
        case .branchChanged: "arrow.triangle.branch"
        case .pullRequestLinked: "arrow.triangle.pull"
        case .compacted: "rectangle.compress.vertical"
        }
    }
}

private struct PulseCard: View {
    let pulse: ProjectPulse
    let selected: Bool
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pulse.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.textPrimary)
                Spacer()
                if !pulse.attentionSessionIDs.isEmpty {
                    Pill(text: "Needs you", color: palette.permission)
                } else if !pulse.activeSessionIDs.isEmpty {
                    Pill(text: "\(pulse.activeSessionIDs.count) active", color: palette.working)
                }
            }
            if let branch = pulse.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11)).foregroundStyle(palette.textSecondary)
            }
            HStack(spacing: 14) {
                Label("\(pulse.recentCompleted.count)", systemImage: "checkmark.circle").foregroundStyle(palette.success)
                Label("\(pulse.recentFailed.count)", systemImage: "xmark.octagon")
                    .foregroundStyle(pulse.recentFailed.isEmpty ? palette.textTertiary : palette.failure)
                Label("\(pulse.linkedPullRequests.count)", systemImage: "arrow.triangle.pull").foregroundStyle(palette.textSecondary)
                Spacer()
                Text(CompanionFormat.relative(pulse.lastActivityAt)).foregroundStyle(palette.textTertiary)
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .background(selected ? palette.accentColor.opacity(0.12) : palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? palette.accentColor : palette.hairlineColor, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Agents

private struct AgentsPage: View {
    @EnvironmentObject private var model: ApplicationModel
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        let withAgents = model.sessions.filter { !($0.insights?.agents.isEmpty ?? true) }
        PageScaffold(title: "Agents", subtitle: "Subagents Claude launched, from each session's transcript.") {
            if withAgents.isEmpty {
                EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: "No subagents yet",
                               message: "When Claude delegates work with the Agent tool, each subagent appears here with what it was asked to do.")
            }
            ForEach(withAgents) { session in
                Card(session.displayTitle) {
                    HStack(alignment: .top, spacing: 18) {
                        AgentConstellation(agents: session.insights?.agents ?? [])
                            .frame(width: 180, height: 180)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(session.insights?.agents ?? []) { agent in
                                AgentRow(agent: agent)
                            }
                        }
                    }
                }
            }
            Text("Background agents are tracked from the transcript; one launched in the background can show as finished as soon as it is handed off.")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
    }
}

/// The session at the centre and each subagent orbiting it, lit while it runs.
private struct AgentConstellation: View {
    let agents: [AgentRun]
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = min(proxy.size.width, proxy.size.height) / 2 - 14
            let shown = Array(agents.suffix(12))
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, agent in
                    let angle = Double(index) / Double(max(shown.count, 1)) * 2 * .pi - .pi / 2
                    let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: point)
                    }
                    .stroke(palette.hairlineColor, lineWidth: 1)
                    Circle()
                        .fill(color(agent))
                        .frame(width: 14, height: 14)
                        .position(point)
                }
                Circle()
                    .fill(palette.accentColor)
                    .frame(width: 26, height: 26)
                    .position(center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agents.count) agents, \(agents.filter(\.isRunning).count) running")
    }

    private func color(_ agent: AgentRun) -> Color {
        if agent.failed { return palette.failure }
        if agent.isRunning { return palette.working }
        return palette.success
    }
}

private struct AgentRow: View {
    let agent: AgentRun
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Pill(text: agent.failed ? "Failed" : agent.isRunning ? "Running" : "Done",
                 color: agent.failed ? palette.failure : agent.isRunning ? palette.working : palette.success)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.description ?? "Agent")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                HStack(spacing: 6) {
                    if let type = agent.subagentType { Text(type) }
                    if let model = agent.model { Text(model) }
                    if agent.runsInBackground { Text("background") }
                    if let start = agent.startedAt {
                        Text(CompanionFormat.duration((agent.finishedAt ?? .now).timeIntervalSince(start)))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
            }
        }
    }
}

// MARK: - History

private struct HistoryPage: View {
    @ObservedObject var navigation: CompanionNavigation
    @EnvironmentObject private var history: HistoryModel
    @Environment(\.overheadPalette) private var palette
    @State private var text = ""
    @State private var status: HistoryStatus?
    @State private var range: Range = .week
    @State private var project: String?

    enum Range: String, CaseIterable, Identifiable {
        case day = "24 hours", week = "7 days", month = "30 days", all = "All"
        var id: String { rawValue }
        var start: Date? {
            switch self {
            case .day: .now.addingTimeInterval(-86_400)
            case .week: .now.addingTimeInterval(-7 * 86_400)
            case .month: .now.addingTimeInterval(-30 * 86_400)
            case .all: nil
            }
        }
    }

    var body: some View {
        let results = history.search(HistoryQuery(
            text: text,
            projectPath: project,
            statuses: status.map { [$0] } ?? [],
            from: range.start
        ))
        PageScaffold(title: "History", subtitle: "\(history.records.count) sessions kept on this Mac.") {
            if let problem = history.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(palette.warning)
            }
            HStack(spacing: 10) {
                TextField("Search prompts, responses, files, branches", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Picker("Status", selection: $status) {
                    Text("Any status").tag(HistoryStatus?.none)
                    ForEach([HistoryStatus.completed, .failed, .interrupted, .running, .waiting], id: \.self) {
                        Text($0.displayName).tag(Optional($0))
                    }
                }
                .frame(width: 150)
                Picker("Project", selection: $project) {
                    Text("All projects").tag(String?.none)
                    ForEach(projects, id: \.self) { path in
                        Text(CompanionFormat.projectName(path)).tag(Optional(path))
                    }
                }
                .frame(width: 180)
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            .labelsHidden()

            HStack(alignment: .top, spacing: 12) {
                Card {
                    if results.isEmpty {
                        EmptyStateView(symbol: "clock.arrow.circlepath", title: "No sessions",
                                       message: "Nothing matches these filters.")
                    }
                    ForEach(results.prefix(200)) { record in
                        Button { navigation.selectedHistoryID = record.id } label: {
                            HistoryLine(record: record, selected: navigation.selectedHistoryID == record.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 380)
                if let id = navigation.selectedHistoryID, let record = history.record(id: id) {
                    ReceiptCard(record: record)
                        .id(record.id)
                        .frame(minWidth: 380)
                }
            }
        }
    }

    private var projects: [String] {
        Array(Set(history.records.compactMap(\.projectPath))).sorted()
    }
}

private struct HistoryLine: View {
    let record: SessionHistoryRecord
    let selected: Bool
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            HistoryStatusBadge(status: record.status).frame(width: 86, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.textPrimary).lineLimit(1)
                Text([record.projectName, record.gitBranch, record.model].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(palette.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(record.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11)).foregroundStyle(palette.textTertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(selected ? palette.accentColor.opacity(0.14) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// What a session did, with git's own record of the changes when the
/// project is a repository.
private struct ReceiptCard: View {
    let record: SessionHistoryRecord
    @EnvironmentObject private var history: HistoryModel
    @EnvironmentObject private var services: OverheadServices
    @Environment(\.overheadPalette) private var palette
    @State private var receipt: SessionReceipt?
    @State private var note: String?

    var body: some View {
        Card("Receipt", trailing: AnyView(actions)) {
            if let receipt {
                VStack(alignment: .leading, spacing: 6) {
                    Text(receipt.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.textPrimary)
                    HStack { HistoryStatusBadge(status: receipt.status); Text(receipt.projectName).foregroundStyle(palette.textSecondary) }
                        .font(.system(size: 12))
                    if let request = receipt.request {
                        Text("Asked").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                        Text(request).font(.system(size: 12)).foregroundStyle(palette.textPrimary).textSelection(.enabled)
                    }
                    if let summary = receipt.summary {
                        Text("Claude's last reply").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                        Text(summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.textSecondary)
                            .lineLimit(8).textSelection(.enabled)
                    }
                    Divider()
                    KeyValueRow(key: "Duration", value: CompanionFormat.duration(receipt.duration))
                    KeyValueRow(key: "Model", value: receipt.model ?? "—")
                    KeyValueRow(key: "Branch", value: receipt.branch ?? "—")
                    if let insertions = receipt.insertions, let deletions = receipt.deletions {
                        KeyValueRow(key: receipt.usesGit ? "Changes (git)" : "Changes (reported)",
                                    value: "\(receipt.files.count) files, +\(insertions) / -\(deletions)")
                    }
                    KeyValueRow(key: "Reported cost", value: CompanionFormat.cost(receipt.costUSD))
                    if !receipt.commits.isEmpty {
                        Text("Commits in this window").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                        ForEach(receipt.commits.prefix(10), id: \.sha) { commit in
                            Text("\(String(commit.sha.prefix(7)))  \(commit.subject)")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.textSecondary).lineLimit(1)
                        }
                    }
                    if !receipt.files.isEmpty {
                        Text("Files").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                        ForEach(receipt.files.prefix(15), id: \.path) { file in
                            HStack {
                                Text(file.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let added = file.added { Text("+\(added)").foregroundStyle(palette.success) }
                                if let removed = file.removed { Text("-\(removed)").foregroundStyle(palette.failure) }
                            }
                            .font(.system(size: 11)).foregroundStyle(palette.textSecondary)
                        }
                    }
                    if !receipt.tests.isEmpty {
                        Text("Tests").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                        ForEach(receipt.tests, id: \.command) { test in
                            HStack {
                                Text(test.command).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                Spacer()
                                Pill(text: test.outcome, color: test.outcome == HistoryTestRun.passed ? palette.success
                                     : test.outcome == HistoryTestRun.failed ? palette.failure : nil)
                            }
                        }
                    }
                    if !receipt.pullRequests.isEmpty {
                        Text("Pull requests").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                        ForEach(receipt.pullRequests, id: \.url) { pr in
                            Button("\(pr.repository) #\(pr.number)") { GitHubModel.openWebPage(pr.url) }
                                .buttonStyle(.link)
                        }
                    }
                    if let note {
                        Text(note).font(.system(size: 11)).foregroundStyle(palette.textSecondary)
                    }
                }
            } else {
                Text("Building receipt…").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
            }
        }
        .task(id: record) {
            receipt = await history.receipt(for: record)
        }
    }

    private var actions: some View {
        HStack {
            Button("Copy") {
                guard let receipt else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(receipt.shareText, forType: .string)
                note = "Receipt copied."
            }
            .disabled(receipt == nil)
            if !record.status.isActive {
                Button("Resume") {
                    Task {
                        let ok = await services.resume(sessionID: record.id, projectPath: record.projectPath)
                        note = ok ? "Opened Terminal with claude --resume." : "Could not open Terminal. Is Claude Code installed?"
                    }
                }
            }
            Button("Remove", role: .destructive) { history.remove(id: record.id) }
        }
        .controlSize(.small)
    }
}

// MARK: - Usage

private struct UsagePage: View {
    @EnvironmentObject private var model: ApplicationModel
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        let sessions = model.sessions.filter { !$0.isDemo && $0.insights != nil }
        PageScaffold(title: "Context & Usage", subtitle: "Context is per session; the 5-hour and weekly limits are per account.") {
            UsageGlance()
            Card("Context by session") {
                if sessions.isEmpty {
                    Text("No session context read yet.").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                }
                ForEach(sessions) { session in
                    HStack {
                        Text(session.displayTitle).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textPrimary).lineLimit(1)
                        Spacer()
                        if let fraction = session.insights?.contextFraction {
                            Text("\(CompanionFormat.tokens(session.insights?.contextTokens)) / \(CompanionFormat.tokens(session.insights?.contextWindowTokens))")
                                .font(.system(size: 11)).foregroundStyle(palette.textTertiary)
                            ThresholdMeter(fraction: fraction,
                                           attentionAt: settings.settings.contextAttentionThreshold,
                                           criticalAt: settings.settings.contextCriticalThreshold)
                        } else {
                            Text("—").foregroundStyle(palette.textTertiary)
                        }
                    }
                }
            }
            if settings.settings.showCacheMetrics {
                Card("Prompt cache") {
                    TimelineView(.periodic(from: .now, by: 15)) { timeline in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(sessions) { session in
                                CacheRow(session: session, now: timeline.date)
                            }
                        }
                    }
                    Text("Claude Code's prompt cache lasts about 5 minutes after the last request by default. The warm/cold estimate counts from the session's last reply; it is not read from Anthropic.")
                        .font(.system(size: 11)).foregroundStyle(palette.textTertiary)
                }
            }
        }
    }
}

private struct CacheRow: View {
    let session: SessionDisplayModel
    let now: Date
    @Environment(\.overheadPalette) private var palette
    static let defaultLifetime: TimeInterval = 5 * 60

    var body: some View {
        let cache = session.insights?.cache
        HStack {
            Text(session.displayTitle).font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary).lineLimit(1)
            Spacer()
            if let ratio = cache?.hitRatio {
                Text("\(Int((ratio * 100).rounded()))% hits")
                    .font(.system(size: 11)).foregroundStyle(palette.textSecondary)
                Text("\(CompanionFormat.tokens(cache?.cacheReadTokens)) read · \(CompanionFormat.tokens(cache?.cacheCreationTokens)) written")
                    .font(.system(size: 11)).foregroundStyle(palette.textTertiary)
            }
            if let last = session.insights?.lastUpdated {
                let remaining = Self.defaultLifetime - now.timeIntervalSince(last)
                Pill(text: remaining > 0 ? "warm ~\(CompanionFormat.duration(remaining))" : "likely cold",
                     color: remaining > 0 ? palette.success : palette.textTertiary)
            }
        }
    }
}

// MARK: - GitHub

private struct GitHubPage: View {
    @EnvironmentObject private var github: GitHubModel
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette
    @State private var onlyMine = false

    var body: some View {
        PageScaffold(title: "GitHub", subtitle: "Pull requests and Actions for the repositories Claude works in.") {
            GitHubConnectionCard()
            if github.connection.isConnected {
                if !github.reviewRequests.isEmpty {
                    Card("Review requested from you") {
                        ForEach(github.reviewRequests) { pr in PullRequestLine(pr: pr) }
                    }
                }
                Toggle("Only my pull requests", isOn: $onlyMine).toggleStyle(.checkbox)
                if github.repositories.isEmpty {
                    EmptyStateView(symbol: "arrow.triangle.pull", title: "No GitHub repositories found",
                                   message: "Repositories are discovered from the folders Claude Code works in. Only github.com remotes are supported.")
                }
                ForEach(github.repositories) { repository in
                    Card(repository.remote.fullName, trailing: AnyView(Button("Open") {
                        if let url = repository.remote.webURL?.absoluteString { GitHubModel.openWebPage(url) }
                    }.controlSize(.small))) {
                        if let problem = repository.problem {
                            Text(problem).font(.system(size: 11)).foregroundStyle(palette.warning)
                        }
                        let prs = repository.pullRequests.filter { !onlyMine || $0.author == github.viewerLogin }
                        if settings.settings.github.trackPullRequests {
                            Text("Open pull requests").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                            if prs.isEmpty {
                                Text("None").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                            }
                            ForEach(prs.prefix(15)) { pr in PullRequestLine(pr: pr) }
                        }
                        if settings.settings.github.monitorActions, !repository.runs.isEmpty {
                            Text("Recent Actions runs").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                            ForEach(repository.runs.prefix(8)) { run in RunLine(run: run) }
                        }
                    }
                }
                HStack {
                    if let refreshed = github.lastRefresh {
                        Text("Updated \(CompanionFormat.relative(refreshed))")
                    }
                    if let remaining = github.rateLimit?.remaining {
                        Text("· \(remaining) API requests left this hour")
                    }
                    Spacer()
                    Button("Refresh now") { github.refreshNow() }.disabled(github.isRefreshing)
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
            }
        }
    }
}

struct GitHubConnectionCard: View {
    @EnvironmentObject private var github: GitHubModel
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette
    @State private var token = ""
    @State private var tokenNote: String?

    var body: some View {
        Card("Connection") {
            Toggle("Use GitHub", isOn: settings.binding(\.github.enabled))
            switch github.connection {
            case .off:
                Text("Off. When on, Overhead calls api.github.com for the repositories Claude works in. Nothing else is sent.")
                    .font(.system(size: 12)).foregroundStyle(palette.textSecondary)
            case .checking:
                Text("Checking sign-in…").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
            case let .connected(login, source):
                Label("Signed in as \(login) via \(source == .githubCLI ? "GitHub CLI" : "personal access token")",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(palette.success)
            case let .signedOut(cli):
                Text(signedOutText(cli)).font(.system(size: 12)).foregroundStyle(palette.textSecondary)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(palette.warning)
            }
            if settings.settings.github.enabled {
                HStack {
                    SecureField("Personal access token (optional)", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Button("Save to Keychain") {
                        do {
                            try github.savePersonalAccessToken(token)
                            token = ""
                            tokenNote = "Saved to your Keychain."
                        } catch {
                            tokenNote = "Could not save: \(error.localizedDescription)"
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    if github.hasStoredToken {
                        Button("Remove token") {
                            try? github.removePersonalAccessToken()
                            tokenNote = "Token removed from your Keychain."
                        }
                    }
                }
                Text(tokenNote ?? "A fine-grained token with read access to pull requests, Actions and checks is enough. It is stored only in the Keychain.")
                    .font(.system(size: 11)).foregroundStyle(palette.textTertiary)
            }
        }
    }

    private func signedOutText(_ cli: GitHubCLIStatus) -> String {
        switch cli {
        case .notInstalled: "Not signed in. Install the GitHub CLI and run `gh auth login`, or save a personal access token below."
        case .signedOut: "The GitHub CLI is installed but signed out. Run `gh auth login` in Terminal, or save a token below."
        case .signedIn: "The GitHub CLI is signed in but did not share a token. Run `gh auth status` to check."
        }
    }
}

private struct PullRequestLine: View {
    let pr: GitHubPullRequest
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        Button { GitHubModel.openWebPage(pr.url) } label: {
            HStack(spacing: 8) {
                Text("#\(pr.number)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
                Text(pr.title).font(.system(size: 12)).foregroundStyle(palette.textPrimary).lineLimit(1)
                if pr.isDraft { Pill(text: "Draft") }
                Spacer()
                if let author = pr.author { Text(author).font(.system(size: 11)).foregroundStyle(palette.textTertiary) }
                CIBadge(state: pr.ciState)
                ReviewBadge(state: pr.reviewState)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RunLine: View {
    let run: GitHubWorkflowRun
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        Button { GitHubModel.openWebPage(run.url) } label: {
            HStack(spacing: 8) {
                CIBadge(state: run.ciState)
                Text(run.name).font(.system(size: 12)).foregroundStyle(palette.textPrimary).lineLimit(1)
                if let branch = run.branch {
                    Text(branch).font(.system(size: 11)).foregroundStyle(palette.textSecondary).lineLimit(1)
                }
                Spacer()
                Text(CompanionFormat.duration(run.duration)).font(.system(size: 11)).foregroundStyle(palette.textTertiary)
                Text(CompanionFormat.relative(run.updatedAt ?? run.createdAt)).font(.system(size: 11)).foregroundStyle(palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CIBadge: View {
    let state: CIState
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        switch state {
        case .success: Pill(text: "CI passed", color: palette.success)
        case .failure: Pill(text: "CI failed", color: palette.failure)
        case .inProgress: Pill(text: "Running", color: palette.working)
        case .queued: Pill(text: "Queued", color: palette.waiting)
        case .cancelled: Pill(text: "Cancelled")
        case .skipped, .neutral: Pill(text: "Skipped")
        case .unknown: EmptyView()
        }
    }
}

private struct ReviewBadge: View {
    let state: GitHubReviewState
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        switch state {
        case .approved: Pill(text: "Approved", color: palette.success)
        case .changesRequested: Pill(text: "Changes requested", color: palette.warning)
        case .reviewRequired: Pill(text: "Review required")
        case .commented: Pill(text: "Commented")
        case .none: EmptyView()
        }
    }
}
