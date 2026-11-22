import ChimloCore
import SwiftUI

/// GitHub → Integration: signing in, which repositories are monitored, and
/// every GitHub preference. It sits beside Overview, Actions and the rest on the
/// one GitHub page, and edits the same settings GitHub Mode in the notch reads.
struct GitHubIntegrationView: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var github: GitHubModel
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        Form {
            Section {
                GitHubConnectionCard()
                    .listRowInsets(EdgeInsets())
                if github.connection.isConnected || github.hasStoredToken {
                    HStack {
                        Text("Disconnect forgets Overhead's sign-in and turns GitHub off. A GitHub CLI login stays signed in; run `gh auth logout` to end it.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Disconnect", role: .destructive) {
                            github.disconnect()
                            settings.settings.github.enabled = false
                        }
                    }
                }
            }
            if settings.settings.github.enabled {
                Section {
                    GitHubRepositoryManager()
                } header: {
                    Text("Repositories")
                } footer: {
                    Text("Overhead watches only the repositories selected here. Each repository is stored by GitHub's own id, so renames and same-named repositories in different organizations stay distinct.")
                }
                if !github.foldersAwaitingAccess.isEmpty {
                    Section("Projects in protected folders") {
                        Text("\(github.foldersAwaitingAccess.count) Claude project folders are in Documents, Desktop, Downloads or iCloud Drive. Overhead reads their git remotes only when you ask, because macOS asks you first.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Look for repositories there") { github.readProtectedFolders() }
                    }
                }
                notchSection
                monitoringSection
                notificationsSection
            }
            Section("Privacy") {
                Text("Overhead signs in with the GitHub CLI (`gh auth token`) when it is installed, or with a token you save to the Keychain. It reads pull requests, reviews, checks and Actions runs for the repositories you select, and writes only one thing: a merge you confirm. Requests go to api.github.com and nowhere else. Logs are never downloaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if github.connection.isConnected { github.loadAvailableRepositories() } }
        .onChange(of: github.connection) { _, new in if new.isConnected { github.loadAvailableRepositories() } }
    }

    private var notchSection: some View {
        Section {
            Toggle("GitHub Mode", isOn: settings.binding(\.github.notchModeEnabled))
            Group {
                Toggle("GitHub button in the open notch", isOn: settings.binding(\.github.showNotchButton))
                Picker("Open on", selection: settings.binding(\.github.defaultView)) {
                    ForEach(GitHubDefaultView.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Panel size", selection: settings.binding(\.github.density)) {
                    ForEach(GitHubPanelDensity.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Show your GitHub account", isOn: settings.binding(\.github.showAccount))
                Toggle("Show repository names", isOn: settings.binding(\.github.showRepositoryInfo))
                Toggle("Show branch, commit and author on rows", isOn: settings.binding(\.github.showDetailedMetadata))
                Toggle("Button shows running workflows", isOn: settings.binding(\.github.showRunningIndicator))
                Toggle("Button shows reviews and requested changes", isOn: settings.binding(\.github.showPullRequestIndicator))
                Toggle("Failures also show in the closed notch", isOn: settings.binding(\.github.showInClosedNotch))
            }
            .disabled(!settings.settings.github.notchModeEnabled)
        } header: {
            Text("GitHub Mode")
        } footer: {
            Text("GitHub Mode opens from the GitHub button or ⌃⌥G. A permission request or question from Claude always takes the notch first; GitHub Mode comes back after you answer.")
        }
    }

    private var monitoringSection: some View {
        Section("Monitoring and notifications") {
            Toggle("Pull requests", isOn: settings.binding(\.github.trackPullRequests))
            Toggle("GitHub Actions runs", isOn: settings.binding(\.github.monitorActions))
            Toggle("Review requests for you", isOn: settings.binding(\.github.reviewNotifications))
                .disabled(!settings.settings.github.trackPullRequests)
            Toggle("Notify when a workflow fails", isOn: eventBinding(.githubWorkflowFailed))
                .disabled(!settings.settings.github.monitorActions)
            Toggle("Notify when a workflow succeeds", isOn: eventBinding(.githubWorkflowSucceeded))
                .disabled(!settings.settings.github.monitorActions)
            Toggle("Allow merging pull requests", isOn: settings.binding(\.github.allowMerging))
                .disabled(!settings.settings.github.trackPullRequests)
            Text("Merge appears only on pull requests GitHub says can merge, and asks you to confirm every time. It needs push access to the repository; a fine-grained token also needs Pull requests and Contents write access.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Group related notifications", isOn: settings.binding(\.github.groupNotifications))
            Toggle("Check running workflows every 45 seconds", isOn: settings.binding(\.github.fastRefreshWhileRunning))
                .disabled(!settings.settings.github.monitorActions)
            Stepper(
                "Refresh everything every \(settings.settings.github.refreshMinutes) minutes",
                value: settings.binding(\.github.refreshMinutes),
                in: GitHubPreferences.refreshRange
            )
            Text("Sound and banners for each GitHub event are below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Sound and banners for each GitHub event. Quiet hours, Focus and the
    /// global mute still apply from Settings → Notifications.
    private var notificationsSection: some View {
        Section {
            ForEach(OverheadEventKind.allCases.filter(\.isGitHub), id: \.self) { kind in
                EventPreferenceRow(kind: kind)
            }
        } header: {
            Text("GitHub notifications")
        } footer: {
            Text("Each repository's own level is set in its row above. Quiet hours, Focus and the global mute in Settings → Notifications apply here too.")
        }
    }

    private func eventBinding(_ kind: OverheadEventKind) -> Binding<Bool> {
        Binding(
            get: { settings.settings.notifications.preference(for: kind).enabled },
            set: { enabled in
                var preference = settings.settings.notifications.preference(for: kind)
                preference.enabled = enabled
                settings.settings.notifications.perEvent[kind] = preference
            }
        )
    }
}

/// The multi-repository picker. Changes are staged in a draft and saved with
/// Apply, so trying selections is safe; Revert throws the draft away.
private struct GitHubRepositoryManager: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var github: GitHubModel
    @Environment(\.overheadPalette) private var palette
    @State private var draft: GitHubRepositorySelection?
    @State private var query = ""

    private var saved: GitHubRepositorySelection { settings.settings.github.selection }
    private var current: GitHubRepositorySelection { draft ?? saved }
    private var hasChanges: Bool { draft != nil && draft != saved }

    /// Everything the owner can pick from: their GitHub repositories, the
    /// ones Claude works in, and anything already selected (even if GitHub no
    /// longer lists it, so it can still be seen and removed).
    private var candidates: [GitHubRepoRef] {
        var seen = Set<Int64>()
        var all: [GitHubRepoRef] = []
        for ref in current.repositories + github.claudeRepositories + (github.availableRepositories?.value ?? [])
        where seen.insert(ref.id).inserted {
            all.append(ref)
        }
        return all
    }

    var body: some View {
        let visible = GitHubRepoSearch.filter(candidates, query: query)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(current.count == 1 ? "Monitoring 1 repository" : "Monitoring \(current.count) repositories")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !current.isEmpty {
                    Picker("Focused", selection: Binding(
                        get: { current.focusedID ?? 0 },
                        set: { id in edit { $0.focus(id) } }
                    )) {
                        ForEach(current.repositories) { Text($0.fullName).tag($0.id) }
                    }
                    .frame(maxWidth: 260)
                    .help("The repository GitHub Mode shows in detail")
                }
            }
            HStack(spacing: 8) {
                TextField("Search repositories or owners", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Select all") { edit { $0.select(all: visible) } }
                    .disabled(visible.isEmpty || visible.allSatisfy { current.contains($0.id) })
                Button("Deselect all") { edit { $0.deselect(all: visible) } }
                    .disabled(!visible.contains { current.contains($0.id) })
                Button("Clear") { edit { $0.clear() } }
                    .disabled(current.isEmpty)
            }
            .controlSize(.small)
            loadState
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(GitHubRepoSearch.groupedByOwner(visible, viewer: github.viewerLogin), id: \.owner) { group in
                        Text(group.owner)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.textTertiary)
                            .padding(.top, 6)
                        ForEach(group.repositories) { ref in row(ref) }
                    }
                    if visible.isEmpty {
                        Text(query.isEmpty ? "No repositories to show yet." : "No repositories match “\(query)”.")
                            .font(.system(size: 12)).foregroundStyle(palette.textSecondary).padding(.vertical, 8)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 300)
            Toggle("Also add repositories Claude works in", isOn: Binding(
                get: { current.followClaudeRepositories },
                set: { value in edit { $0.followClaudeRepositories = value } }
            ))
            .help("Repositories you remove stay removed until you select them again.")
            HStack {
                if hasChanges {
                    Text("Unsaved changes").font(.system(size: 11)).foregroundStyle(palette.warning)
                }
                Spacer()
                Button("Revert") { draft = nil }.disabled(!hasChanges)
                Button("Apply") {
                    if let draft { settings.settings.github.selection = draft }
                    draft = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
            }
        }
        .onChange(of: saved) { _, newSaved in
            // Another change landed (Claude repository added, a rename). With
            // no pending edits, simply follow it.
            if draft == newSaved { draft = nil }
        }
    }

    @ViewBuilder
    private var loadState: some View {
        switch github.availableRepositories {
        case .loading?:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading your repositories…") }
                .font(.system(size: 11)).foregroundStyle(palette.textSecondary)
        case let .failed(message)?:
            HStack {
                Text("Couldn't list your repositories: \(message)").font(.system(size: 11)).foregroundStyle(palette.warning)
                Button("Retry") { github.loadAvailableRepositories(force: true) }.controlSize(.small)
            }
        case .loaded?:
            HStack {
                Spacer()
                Button("Reload list") { github.loadAvailableRepositories(force: true) }
                    .buttonStyle(.link).controlSize(.small)
            }
        case nil:
            EmptyView()
        }
    }

    private func row(_ ref: GitHubRepoRef) -> some View {
        let selected = current.contains(ref.id)
        let snapshot = github.snapshot(ref.id)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { selected },
                set: { _ in edit { $0.toggle(ref) } }
            )) {
                HStack(spacing: 6) {
                    Text(ref.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    if let isPrivate = ref.isPrivate { Pill(text: isPrivate ? "Private" : "Public") }
                    if github.claudeRepositories.contains(where: { $0.id == ref.id }) { Pill(text: "Claude works here", color: palette.working) }
                    if snapshot?.availability.isUnavailable == true { Pill(text: "Unavailable", color: palette.warning) }
                    if current.focusedID == ref.id { Pill(text: "Focused", color: palette.success) }
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("\(ref.fullName), \(selected ? "selected" : "not selected")")
            Spacer()
            if selected, saved.contains(ref.id) {
                Picker("Notifications", selection: Binding(
                    get: { settings.settings.github.alertLevel(for: ref.id) },
                    set: { settings.settings.github.setAlertLevel($0, for: ref.id) }
                )) {
                    ForEach(GitHubAlertLevel.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 170)
                .help("Notifications from \(ref.fullName)")
            }
        }
        .padding(.vertical, 2)
    }

    private func edit(_ change: (inout GitHubRepositorySelection) -> Void) {
        var next = current
        change(&next)
        draft = next
    }
}
