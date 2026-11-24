import Foundation

extension SettingsPaneID {
    /// The pane's name in the Settings sidebar and in search results.
    public var displayName: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications & Sound"
        case .usage: "Usage"
        case .shortcuts: "Shortcuts"
        case .github: "GitHub"
        case .privacy: "Privacy"
        }
    }
}

/// A group of controls on a Settings pane: where search lands, and what the
/// pane scrolls to. Every setting belongs to exactly one.
public enum SettingsAnchor: String, CaseIterable, Identifiable, Sendable {
    // General
    case startup, display, behaviour, claudeCode, updates, about, reset
    // Appearance
    case layout, characters, glow, theme, notchContent, lists, accessibility
    // Notifications & Sound
    case sound, claudeEvents, githubEvents, delivery, quietHours, focus
    // Usage
    case context, limits, cache
    // Shortcuts
    case shortcuts
    // GitHub
    case githubConnection, repositories, monitoring, githubMode, githubPrivacy
    // Privacy
    case history, yourData, network

    public var id: String { rawValue }

    public var pane: SettingsPaneID {
        switch self {
        case .startup, .display, .behaviour, .claudeCode, .updates, .about, .reset: .general
        case .layout, .characters, .glow, .theme, .notchContent, .lists, .accessibility: .appearance
        case .sound, .claudeEvents, .githubEvents, .delivery, .quietHours, .focus: .notifications
        case .context, .limits, .cache: .usage
        case .shortcuts: .shortcuts
        case .githubConnection, .repositories, .monitoring, .githubMode, .githubPrivacy: .github
        case .history, .yourData, .network: .privacy
        }
    }
}

/// One thing the owner can change or look up in Settings, as search finds it.
public struct SettingsEntry: Identifiable, Equatable, Sendable {
    public let id: String
    /// The group of controls it is in, which also names its pane.
    public let anchor: SettingsAnchor
    public let title: String
    /// One short line: what it is.
    public let summary: String
    /// Other words someone might type for it.
    public let keywords: [String]

    public var pane: SettingsPaneID { anchor.pane }

    init(_ id: String, _ anchor: SettingsAnchor, _ title: String, _ summary: String, _ keywords: [String] = []) {
        self.id = id
        self.anchor = anchor
        self.title = title
        self.summary = summary
        self.keywords = keywords
    }
}

/// Every setting, in the order the panes show them. Settings search reads
/// this list and nothing else, so a setting that is not here cannot be found:
/// add an entry when a control is added.
public enum SettingsCatalog {
    public static let entries: [SettingsEntry] = general + appearance + notifications + usage + shortcuts + github + privacy

    private static let general: [SettingsEntry] = [
        SettingsEntry("launchAtLogin", .startup, "Open at login", "Start Claude Overhead when you log in.",
                      ["startup", "launch", "login", "boot", "start"]),
        SettingsEntry("preferredDisplay", .display, "Show the notch on", "Which display carries the notch.",
                      ["display", "screen", "monitor", "external", "pointer"]),
        SettingsEntry("notchLocked", .behaviour, "Lock Mode", "The notch opens only when you open it.",
                      ["lock", "locked", "notch", "open"]),
        SettingsEntry("unattendedRuns", .behaviour, "Unattended runs", "Whether requests from scripted runs wait in the notch.",
                      ["unattended", "script", "headless", "print", "sdk", "claude -p"]),
        SettingsEntry("claudeCode", .claudeCode, "Claude Code connection", "Connect, repair or disconnect Claude Code.",
                      ["connect", "disconnect", "reconnect", "repair", "hooks", "integration", "listener"]),
        SettingsEntry("setup", .claudeCode, "Run setup again", "Open the setup window again.",
                      ["setup", "onboarding", "welcome"]),
        SettingsEntry("updates", .updates, "Updates", "Check for updates and see what is new.",
                      ["update", "version", "check", "what's new", "release", "upgrade"]),
        SettingsEntry("about", .about, "About", "Version, licence and credits.",
                      ["about", "licence", "license", "gpl", "chimlo", "credits", "quit"]),
        SettingsEntry("reset", .reset, "Reset all settings", "Put every setting back to its default.",
                      ["reset", "defaults", "restore"]),
    ]

    private static let appearance: [SettingsEntry] = [
        SettingsEntry("layout", .layout, "Notch layout", "Minimal, Classic, Expanded, Focus or Agent View.",
                      ["layout", "minimal", "classic", "expanded", "focus", "agent view", "notch"]),
        SettingsEntry("characters", .characters, "Characters & Mascots", "Browse every character and give one to a session.",
                      ["characters", "character", "mascots", "mascot", "avatar", "sprite", "logo", "picker", "gallery",
                       "animals", "elementals", "fantasy", "cyber"]),
        SettingsEntry("automaticCharacters", .characters, "Automatic character assignment",
                      "Give every new session a random character.",
                      ["automatic", "auto", "random", "assign", "characters", "mascots"]),
        SettingsEntry("characterCollections", .characters, "Character collections",
                      "Which characters each project's sessions may be given.",
                      ["collection", "collections", "project", "pool", "characters", "mascots"]),
        SettingsEntry("glow", .glow, "Completion glow", "Light the closed notch when Claude finishes a turn.",
                      ["glow", "rgb", "light", "wave", "finished", "completion", "rainbow"]),
        SettingsEntry("glowStyle", .glow, "Glow style", "RGB Spectrum, Golden Glow, Aurora and seven more.",
                      ["rgb", "spectrum", "golden", "gold", "electric blue", "neon purple", "crimson", "emerald",
                       "cyberpunk", "aurora", "monochrome", "sunset", "theme", "preset"]),
        SettingsEntry("glowBrightness", .glow, "Glow brightness", "How strongly the glow shows.",
                      ["brightness", "intensity", "dim"]),
        SettingsEntry("theme", .theme, "Colour theme", "Midnight, Graphite, Obsidian, Warm Amber, Arctic or Match System.",
                      ["theme", "color", "colour", "midnight", "graphite", "obsidian", "warm amber", "arctic",
                       "match system", "dark", "light"]),
        SettingsEntry("accent", .theme, "Accent colour", "The colour of selections and buttons.",
                      ["accent", "tint", "color", "colour"]),
        SettingsEntry("liveActivity", .notchContent, "Live activity in the closed notch",
                      "One line of what Claude is doing, under the camera.",
                      ["activity", "strip", "closed notch", "live"]),
        SettingsEntry("subagents", .notchContent, "Show subagents", "Agent dots in the notch and agents on session rows.",
                      ["agents", "subagents", "dots"]),
        SettingsEntry("rowDensity", .notchContent, "Session rows", "Comfortable or compact rows in the open notch.",
                      ["rows", "density", "compact", "comfortable"]),
        SettingsEntry("sessionSort", .lists, "Sort sessions by", "Needs you first, recent activity or project.",
                      ["sort", "order", "sessions"]),
        SettingsEntry("groupByProject", .lists, "Group sessions by project", "Sessions listed under their project.",
                      ["group", "project", "sessions"]),
        SettingsEntry("dailyRecap", .lists, "Today's recap on Overview", "A summary of the day on the Overview page.",
                      ["recap", "overview", "summary", "today"]),
        SettingsEntry("animation", .accessibility, "Animation", "Full, reduced or minimal motion in the notch.",
                      ["animation", "motion", "animations"]),
        SettingsEntry("reduceMotion", .accessibility, "Reduce Motion", "Follows macOS: the notch holds still when it is on.",
                      ["reduce motion", "accessibility", "motion"]),
        SettingsEntry("increaseContrast", .accessibility, "Increase Contrast", "Follows macOS: stronger surfaces when it is on.",
                      ["contrast", "accessibility"]),
    ]

    private static let notifications: [SettingsEntry] = [
        SettingsEntry("playSounds", .sound, "Play sounds", "The master switch for every sound.",
                      ["sound", "sounds", "mute", "audio", "silent"]),
        SettingsEntry("soundChoice", .sound, "Sound", "Pixel chime, Tink, Pop, Glass or Purr.",
                      ["sound", "chime", "tink", "pop", "glass", "purr", "preview"]),
        SettingsEntry("soundVolume", .sound, "Volume", "How loud the sound plays.",
                      ["volume", "loud", "quiet"]),
        SettingsEntry("sessionSound", .sound, "Per-session sound", "Each session's bell in the notch turns its sound on.",
                      ["bell", "session", "sound"]),
        SettingsEntry("claudeEvents", .claudeEvents, "Claude notifications",
                      "Which events show, sound and post a banner.",
                      ["permission", "question", "failure", "completed", "context", "usage", "banner", "event",
                       "notification", "notifications"]),
        SettingsEntry("githubEvents", .githubEvents, "GitHub notifications",
                      "Pull requests, reviews, checks and workflows.",
                      ["github", "pull request", "review", "workflow", "checks", "merged", "comments", "banner"]),
        SettingsEntry("banners", .delivery, "macOS banners", "Allow Claude Overhead to post notification banners.",
                      ["banner", "banners", "notification centre", "notification center", "allow"]),
        SettingsEntry("groupCompletions", .delivery, "Group completion banners", "Several finished sessions arrive as one notice.",
                      ["group", "grouping", "completion"]),
        SettingsEntry("quietHours", .quietHours, "Quiet hours", "Hours when informational banners and sounds stop.",
                      ["quiet", "hours", "night", "schedule", "do not disturb"]),
        SettingsEntry("focusMode", .focus, "Focus mode", "A calmer notch while you concentrate.",
                      ["focus", "concentrate", "mute", "schedule", "calm"]),
    ]

    private static let usage: [SettingsEntry] = [
        SettingsEntry("contextWarning", .context, "Context warning threshold", "When a session's context is flagged as filling up.",
                      ["context", "threshold", "warn", "warning", "window"]),
        SettingsEntry("contextCritical", .context, "Context critical threshold", "When a session's context is flagged as nearly full.",
                      ["context", "threshold", "critical", "window"]),
        SettingsEntry("usageWarning", .limits, "Usage limit warning", "When the 5-hour and weekly limits are flagged.",
                      ["usage", "limit", "limits", "5-hour", "weekly", "threshold", "warn"]),
        SettingsEntry("resetCountdowns", .limits, "Reset countdowns", "Show the time until each limit resets.",
                      ["reset", "countdown", "countdowns"]),
        SettingsEntry("cacheMetrics", .cache, "Prompt-cache metrics", "Show how much of a session's input came from the cache.",
                      ["cache", "prompt cache", "metrics"]),
    ]

    private static let shortcuts: [SettingsEntry] = [
        SettingsEntry("globalShortcuts", .shortcuts, "Global shortcuts", "Keyboard shortcuts that work in any app.",
                      ["shortcut", "shortcuts", "hot key", "hotkey", "keyboard", "keys"]
                        + ShortcutAction.allCases.map { $0.displayName.lowercased() }),
        SettingsEntry("restoreShortcuts", .shortcuts, "Restore default shortcuts", "Put every shortcut back.",
                      ["restore", "defaults", "shortcut"]),
    ]

    private static let github: [SettingsEntry] = [
        SettingsEntry("githubEnabled", .githubConnection, "Use GitHub", "Turn the GitHub integration on or off.",
                      ["github", "connect", "disconnect", "sign in", "account", "gh"]),
        SettingsEntry("githubToken", .githubConnection, "Personal access token", "Sign in with a token kept in your Keychain.",
                      ["token", "keychain", "pat", "personal access token"]),
        SettingsEntry("githubRepositories", .repositories, "Repositories", "Choose which repositories are monitored.",
                      ["repository", "repositories", "repo", "repos", "owner", "organization", "organisation", "select"]),
        SettingsEntry("githubMonitoring", .monitoring, "GitHub monitoring", "Pull requests, Actions runs and review requests.",
                      ["monitor", "monitoring", "pull requests", "actions", "reviews", "workflow"]),
        SettingsEntry("githubMerging", .monitoring, "Allow merging pull requests", "Offer Merge on pull requests that can merge.",
                      ["merge", "merging"]),
        SettingsEntry("githubRefresh", .monitoring, "Refresh interval", "How often GitHub is checked.",
                      ["refresh", "interval", "polling", "poll"]),
        SettingsEntry("githubMode", .githubMode, "GitHub Mode in the notch", "The GitHub button and what GitHub Mode shows.",
                      ["github mode", "notch", "button", "badge"]),
        SettingsEntry("githubPrivacy", .githubPrivacy, "GitHub permissions and data", "What is read, what is written and where it goes.",
                      ["privacy", "permissions", "data", "api"]),
    ]

    private static let privacy: [SettingsEntry] = [
        SettingsEntry("conversationPreviews", .history, "Keep your last prompt and Claude's reply",
                      "Whether history stores the last exchange of a session.",
                      ["prompt", "reply", "conversation", "preview", "history"]),
        SettingsEntry("historyRetention", .history, "History retention", "How long session history is kept.",
                      ["history", "retention", "keep", "days", "forever"]),
        SettingsEntry("historyFile", .yourData, "Show history file in Finder", "Where the history is stored on this Mac.",
                      ["history", "file", "finder", "data"]),
        SettingsEntry("exportHistory", .yourData, "Export history", "Save your history as a JSON file.",
                      ["export", "history", "json", "backup"]),
        SettingsEntry("deleteHistory", .yourData, "Delete all history", "Remove every stored session summary.",
                      ["delete", "clear", "history", "erase"]),
        SettingsEntry("network", .network, "Network and permissions", "What stays on this Mac and what is sent where.",
                      ["network", "telemetry", "analytics", "privacy", "data", "permissions"]),
    ]

    /// The entries that match `query`, best first. Every word typed must be
    /// found in an entry; a match in its title counts for more than one in
    /// its other words. Ties keep the order of the panes, so the same query
    /// always gives the same list.
    public static func search(_ query: String, limit: Int = 12) -> [SettingsEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = needle.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let scored: [(offset: Int, score: Int, entry: SettingsEntry)] = entries.enumerated().compactMap { offset, entry in
            score(entry, tokens: tokens, query: needle).map { (offset, $0, entry) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .prefix(max(limit, 0))
            .map(\.entry)
    }

    private static func score(_ entry: SettingsEntry, tokens: [String], query: String) -> Int? {
        let title = entry.title.lowercased()
        let titleWords = words(in: title)
        let keywords = entry.keywords.map { $0.lowercased() }
        let summary = entry.summary.lowercased()
        let pane = entry.pane.displayName.lowercased()

        var total = 0
        for token in tokens {
            let best: Int
            if titleWords.contains(where: { $0.hasPrefix(token) }) {
                best = 100
            } else if keywords.contains(token) {
                best = 90
            } else if title.contains(token) {
                best = 60
            } else if keywords.contains(where: { $0.hasPrefix(token) || words(in: $0).contains { $0.hasPrefix(token) } }) {
                best = 50
            } else if keywords.contains(where: { $0.contains(token) }) {
                best = 30
            } else if summary.contains(token) {
                best = 10
            } else if pane.contains(token) {
                best = 5
            } else {
                return nil
            }
            total += best
        }
        if title == query { total += 200 } else if title.hasPrefix(query) { total += 80 }
        if keywords.contains(query) { total += 40 }
        return total
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
