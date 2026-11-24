import ChimloCore
import SwiftUI

/// Settings → GitHub: the integration only. Signing in and out, which
/// repositories are monitored, and what the integration watches. Using GitHub
/// (what needs attention, workflow runs, pull requests, reviews) is the
/// GitHub page; sound and banners for GitHub events are in Settings →
/// Notifications & Sound. Nothing here lists GitHub activity.
struct GitHubIntegrationView: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var github: GitHubModel
    @EnvironmentObject private var navigation: CompanionNavigation
    @Environment(\.overheadPalette) private var palette

    private var isEnabled: Bool { settings.settings.github.enabled }

    var body: some View {
        SettingsPage {
            SettingsSection(.githubConnection, "Connection") {
                GitHubConnectionGroup()
            }

            if isEnabled {
                SettingsSection(
                    .repositories,
                    "Repositories",
                    info: "Claude Overhead watches only the repositories selected here. Each repository is stored by GitHub's own id, so renames and same-named repositories under different owners stay distinct."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        GitHubRepositoryManager()
                        if !github.foldersAwaitingAccess.isEmpty {
                            SettingsGroup {
                                SettingsRow(
                                    "Projects in protected folders",
                                    detail: "\(github.foldersAwaitingAccess.count) Claude project folders are in Documents, Desktop, Downloads or iCloud Drive. Their git remotes are read only when you ask, because macOS asks you first."
                                ) {
                                    Button("Look for Repositories") { github.readProtectedFolders() }
                                }
                            }
                        }
                    }
                }

                SettingsSection(
                    .monitoring,
                    "Monitoring",
                    info: "Merge appears only on pull requests GitHub says can merge, and asks you to confirm every time. It needs push access to the repository; a fine-grained token also needs Pull requests and Contents write access."
                ) {
                    SettingsGroup {
                        Toggle("Pull requests", isOn: settings.binding(\.github.trackPullRequests))
                        Toggle("GitHub Actions runs", isOn: settings.binding(\.github.monitorActions))
                        Toggle("Review requests for you", isOn: settings.binding(\.github.reviewNotifications))
                            .disabled(!settings.settings.github.trackPullRequests)
                        SettingsToggle(
                            "Allow merging pull requests",
                            detail: "Every merge asks you to confirm.",
                            isOn: settings.binding(\.github.allowMerging)
                        )
                        .disabled(!settings.settings.github.trackPullRequests)
                        Toggle("Check running workflows every 45 seconds", isOn: settings.binding(\.github.fastRefreshWhileRunning))
                            .disabled(!settings.settings.github.monitorActions)
                        SettingsRow("Refresh everything") {
                            Picker("Refresh everything", selection: settings.binding(\.github.refreshSeconds)) {
                                ForEach(refreshChoices, id: \.self) { seconds in
                                    Text(GitHubPreferences.refreshLabel(seconds)).tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        SettingsRow("Notifications", detail: "Which GitHub events show, sound and post a banner.") {
                            Button("Notifications & Sound…") { navigation.showSettings(at: .githubEvents) }
                        }
                    }
                }

                SettingsSection(
                    .githubMode,
                    "GitHub Mode in the notch",
                    info: "GitHub Mode opens from the GitHub button or ⌃⌥G. A permission request or question from Claude always takes the notch first; GitHub Mode comes back after you answer."
                ) {
                    SettingsGroup {
                        Toggle("GitHub Mode", isOn: settings.binding(\.github.notchModeEnabled))
                    }
                    SettingsGroup {
                        Toggle("GitHub button in the open notch", isOn: settings.binding(\.github.showNotchButton))
                        SettingsRow("Open on") {
                            Picker("Open on", selection: settings.binding(\.github.defaultView)) {
                                ForEach(GitHubDefaultView.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        SettingsRow("Panel size") {
                            Picker("Panel size", selection: settings.binding(\.github.density)) {
                                ForEach(GitHubPanelDensity.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Toggle("Show your GitHub account", isOn: settings.binding(\.github.showAccount))
                        Toggle("Show repository names", isOn: settings.binding(\.github.showRepositoryInfo))
                        Toggle("Show branch, commit and author on rows", isOn: settings.binding(\.github.showDetailedMetadata))
                        Toggle("Button shows running workflows", isOn: settings.binding(\.github.showRunningIndicator))
                        Toggle("Button shows reviews and requested changes", isOn: settings.binding(\.github.showPullRequestIndicator))
                        Toggle("Failures also show in the closed notch", isOn: settings.binding(\.github.showInClosedNotch))
                    }
                    .disabled(!settings.settings.github.notchModeEnabled)
                    .opacity(settings.settings.github.notchModeEnabled ? 1 : 0.55)
                }
            }

            SettingsSection(.githubPrivacy, "Permissions and data") {
                SettingsNote("Requests go to api.github.com and nowhere else. The only thing written is a merge you confirm.")
                SettingsGroup {
                    SettingsDetails("How Claude Overhead signs in") {
                        Text("With the GitHub CLI (gh auth token) when it is installed, or with a token you save to the Keychain. The token is never written to settings or logs.")
                    }
                    SettingsDetails("What is read") {
                        Text("Pull requests, reviews, checks and Actions runs for the repositories you select. Workflow logs are never downloaded.")
                    }
                }
            }
        }
        .onAppear { if github.connection.isConnected { github.loadAvailableRepositories() } }
        .onChange(of: github.connection) { _, new in if new.isConnected { github.loadAvailableRepositories() } }
    }

    /// The offered intervals, plus one carried over from an older version.
    private var refreshChoices: [Int] {
        Array(Set(GitHubPreferences.refreshChoices + [settings.settings.github.refreshSeconds])).sorted()
    }
}

/// Whether GitHub is on, who is signed in and how, and the way in and out.
private struct GitHubConnectionGroup: View {
    @EnvironmentObject private var github: GitHubModel
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette
    @State private var token = ""
    @State private var tokenNote: String?

    var body: some View {
        SettingsGroup {
            Toggle("Use GitHub", isOn: settings.binding(\.github.enabled))
            HStack(spacing: 10) {
                statusIcon.frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.system(size: 13, weight: .medium))
                    Text(statusDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if github.connection.isConnected || github.hasStoredToken {
                    Button("Disconnect", role: .destructive) {
                        github.disconnect()
                        settings.settings.github.enabled = false
                    }
                    .help("Forgets Claude Overhead's sign-in and turns GitHub off. A GitHub CLI login stays signed in; run gh auth logout to end it.")
                }
            }
            .accessibilityElement(children: .contain)
            if settings.settings.github.enabled {
                SettingsDetails("Sign in with a personal access token") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SecureField("Personal access token (optional)", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
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
                                Button("Remove Token") {
                                    try? github.removePersonalAccessToken()
                                    tokenNote = "Token removed from your Keychain."
                                }
                            }
                        }
                        Text(tokenNote ?? "A fine-grained token with read access to pull requests, Actions and checks is enough to watch. Merging also needs Pull requests and Contents write access. It is stored only in the Keychain.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch github.connection {
        case .off: Image(systemName: "circle").foregroundStyle(palette.textTertiary)
        case .checking: ProgressView().controlSize(.small)
        case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
        case .signedOut: Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(palette.textSecondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.warning)
        }
    }

    private var statusTitle: String {
        switch github.connection {
        case .off: "Off"
        case .checking: "Checking sign-in…"
        case let .connected(login, _): "Signed in as \(login)"
        case .signedOut: "Not signed in"
        case .failed: "Couldn't connect"
        }
    }

    private var statusDetail: String {
        switch github.connection {
        case .off: "When on, requests go to api.github.com for the repositories you select. Nothing else is sent."
        case .checking: "Looking for a GitHub CLI login or a saved token."
        case let .connected(_, source):
            source == .githubCLI ? "Through the GitHub CLI" : "With a personal access token from your Keychain"
        case let .signedOut(cli):
            switch cli {
            case .notInstalled: "Install the GitHub CLI and run gh auth login, or save a personal access token below."
            case .signedOut: "The GitHub CLI is installed but signed out. Run gh auth login in Terminal, or save a token below."
            case .signedIn: "The GitHub CLI is signed in but did not share a token. Run gh auth status to check."
            }
        case let .failed(message): message
        }
    }
}

/// The repository picker with the app's own data: the repositories GitHub
/// lists, the ones Claude works in, and anything already selected (even if
/// GitHub no longer lists it, so it can still be seen and removed).
private struct GitHubRepositoryManager: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var github: GitHubModel

    var body: some View {
        GitHubRepositoryPicker(
            saved: settings.settings.github.selection,
            listed: github.claudeRepositories + (github.availableRepositories?.value ?? []),
            viewer: github.viewerLogin,
            claudeRepositoryIDs: Set(github.claudeRepositories.map(\.id)),
            isUnavailable: { github.snapshot($0)?.availability.isUnavailable == true },
            load: load,
            alertLevel: { settings.settings.github.alertLevel(for: $0) },
            setAlertLevel: { level, id in settings.settings.github.setAlertLevel(level, for: id) },
            apply: { settings.settings.github.selection = $0 },
            reload: { github.loadAvailableRepositories(force: true) }
        )
    }

    private var load: GitHubRepositoryPicker.Load {
        switch github.availableRepositories {
        case .loading?: .loading
        case let .failed(message)?: .failed(message)
        case .loaded?: .loaded
        case nil: .idle
        }
    }
}

/// Repositories grouped under their owner, each owner a heading that opens
/// and closes and says how many of its repositories are selected. Changes
/// are staged in a draft and saved with Apply, so trying selections is safe;
/// Revert throws the draft away.
///
/// It takes its data as values, so it can be drawn and checked without a
/// GitHub account.
struct GitHubRepositoryPicker: View {
    enum Load: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    let saved: GitHubRepositorySelection
    /// Everything that can be picked beyond what is already selected.
    let listed: [GitHubRepoRef]
    let viewer: String?
    let claudeRepositoryIDs: Set<Int64>
    let isUnavailable: (Int64) -> Bool
    let load: Load
    let alertLevel: (Int64) -> GitHubAlertLevel
    let setAlertLevel: (GitHubAlertLevel, Int64) -> Void
    let apply: (GitHubRepositorySelection) -> Void
    let reload: () -> Void

    @Environment(\.overheadPalette) private var palette
    @State private var draft: GitHubRepositorySelection?
    @State private var query = ""
    /// The owners opened or closed by hand; nil until the first click, when
    /// the groups holding a selection (and the viewer's own) are open.
    @State private var expanded: Set<String>?

    private var current: GitHubRepositorySelection { draft ?? saved }
    private var hasChanges: Bool { draft != nil && draft != saved }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// One row per repository id, selected ones first so a repository GitHub
    /// no longer lists is still there to remove.
    private var candidates: [GitHubRepoRef] {
        var seen = Set<Int64>()
        return (current.repositories + listed).filter { seen.insert($0.id).inserted }
    }

    private var allGroups: [GitHubOwnerGroup] {
        GitHubRepoSearch.ownerGroups(candidates, selection: current, viewer: viewer)
    }

    var body: some View {
        let visible = GitHubRepoSearch.filter(candidates, query: query)
        let groups = GitHubRepoSearch.ownerGroups(visible, selection: current, viewer: viewer)
        // Worked out once for the whole list: with hundreds of repositories,
        // asking again for every owner would group them all each time.
        let open = openOwners
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(current.count == 1 ? "1 repository selected" : "\(current.count) repositories selected")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                if hasChanges {
                    Text("Not applied yet")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.warning)
                }
                Spacer(minLength: 8)
                if !current.isEmpty {
                    Text("Focused").font(.system(size: 11.5)).foregroundStyle(palette.textSecondary)
                    Picker("Focused repository", selection: Binding(
                        get: { current.focusedID ?? 0 },
                        set: { id in edit { $0.focus(id) } }
                    )) {
                        ForEach(current.repositories) { Text($0.fullName).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 230)
                    .help("The repository GitHub Mode shows in detail")
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(palette.textTertiary)
                    TextField("Search repositories or owners", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .accessibilityLabel("Search repositories or owners")
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(palette.raisedColor)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button(isSearching ? "Select Matching" : "Select All") { edit { $0.select(all: visible) } }
                    .disabled(visible.isEmpty || visible.allSatisfy { current.contains($0.id) })
                Button(isSearching ? "Clear Matching" : "Clear") { edit { $0.deselect(all: visible) } }
                    .disabled(!visible.contains { current.contains($0.id) })
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Load the list from GitHub again")
                    .accessibilityLabel("Reload the repository list")
                    .disabled(load == .loading)
            }
            .controlSize(.small)

            loadState

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        let isOpen = isSearching || open.contains(group.owner)
                        ownerHeader(group, open: isOpen)
                        if isOpen {
                            ForEach(group.repositories) { ref in row(ref) }
                        }
                    }
                    if groups.isEmpty {
                        Text(isSearching ? "No repositories match “\(query)”." : "No repositories to show yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120, maxHeight: 340)
            .background(palette.surfaceColor)
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous)
                    .strokeBorder(palette.hairlineColor, lineWidth: 1)
            )

            HStack(spacing: 10) {
                Toggle("Also add repositories Claude works in", isOn: Binding(
                    get: { current.followClaudeRepositories },
                    set: { value in edit { $0.followClaudeRepositories = value } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Repositories you remove stay removed until you select them again.")
                Spacer(minLength: 8)
                Button("Revert") { draft = nil }.disabled(!hasChanges)
                Button("Apply") {
                    if let draft { apply(draft) }
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
        switch load {
        case .loading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading your repositories…") }
                .font(.system(size: 11.5)).foregroundStyle(palette.textSecondary)
        case let .failed(message):
            HStack {
                Text("Couldn't list your repositories: \(message)")
                    .font(.system(size: 11.5)).foregroundStyle(palette.warning)
                Button("Retry") { reload() }.controlSize(.small)
            }
        case .idle, .loaded:
            EmptyView()
        }
    }

    /// The owners that are open. (While searching every group that matched
    /// is shown open, so a match is never hidden inside a closed group.)
    private var openOwners: Set<String> {
        expanded ?? GitHubRepoSearch.initiallyExpandedOwners(allGroups, viewer: viewer)
    }

    private func toggleOpen(_ group: GitHubOwnerGroup) {
        var owners = openOwners
        if owners.contains(group.owner) { owners.remove(group.owner) } else { owners.insert(group.owner) }
        expanded = owners
    }

    private func ownerHeader(_ group: GitHubOwnerGroup, open: Bool) -> some View {
        HStack(spacing: 8) {
            Button { toggleOpen(group) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(palette.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Text(group.owner)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text("\(group.selectedCount) selected")
                        .font(.system(size: 11, weight: group.selectedCount > 0 ? .medium : .regular))
                        .foregroundStyle(group.selectedCount > 0 ? palette.accentColor : palette.textTertiary)
                    Text("of \(group.repositories.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
            .accessibilityLabel("\(group.owner), \(group.selectedCount) of \(group.repositories.count) selected")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides this owner's repositories")
            Button("All") { edit { $0.select(all: group.repositories) } }
                .disabled(group.isFullySelected)
                .accessibilityLabel("Select all of \(group.owner)")
            Button("None") { edit { $0.deselect(all: group.repositories) } }
                .disabled(group.selectedCount == 0)
                .accessibilityLabel("Clear all of \(group.owner)")
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func row(_ ref: GitHubRepoRef) -> some View {
        let selected = current.contains(ref.id)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { selected },
                set: { _ in edit { $0.toggle(ref) } }
            )) {
                HStack(spacing: 6) {
                    Text(ref.name).font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    if let isPrivate = ref.isPrivate { Pill(text: isPrivate ? "Private" : "Public") }
                    if claudeRepositoryIDs.contains(ref.id) { Pill(text: "Claude works here", color: palette.working) }
                    if isUnavailable(ref.id) { Pill(text: "Unavailable", color: palette.warning) }
                    if current.focusedID == ref.id { Pill(text: "Focused", color: palette.success) }
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("\(ref.fullName), \(selected ? "selected" : "not selected")")
            Spacer(minLength: 8)
            if selected, saved.contains(ref.id) {
                Picker("Notifications", selection: Binding(
                    get: { alertLevel(ref.id) },
                    set: { setAlertLevel($0, ref.id) }
                )) {
                    ForEach(GitHubAlertLevel.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 170)
                .help("Notifications from \(ref.fullName)")
            }
        }
        .padding(.leading, 31)
        .padding(.trailing, 12)
        .frame(minHeight: 28)
    }

    private func edit(_ change: (inout GitHubRepositorySelection) -> Void) {
        var next = current
        change(&next)
        draft = next
    }
}
