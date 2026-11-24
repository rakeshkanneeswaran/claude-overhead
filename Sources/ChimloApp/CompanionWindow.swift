import AppKit
import ChimloCore
import Combine
import SwiftUI

/// The companion window's sections. The notch stays the hero; this window is
/// where the owner goes to look deeper or to change how the notch behaves.
/// The sidebar's order and identity live in Core (`CompanionDestination`),
/// where tests pin that GitHub appears exactly once.
typealias CompanionSection = CompanionDestination

extension CompanionDestination {
    var title: String {
        switch self {
        case .overview: "Overview"
        case .sessions: "Sessions"
        case .projects: "Projects"
        case .agents: "Agents"
        case .history: "History"
        case .usage: "Usage"
        case .github: "GitHub"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .sessions: "bubble.left.and.bubble.right"
        case .projects: "folder"
        case .agents: "point.3.connected.trianglepath.dotted"
        case .history: "clock.arrow.circlepath"
        case .usage: "gauge.with.dots.needle.33percent"
        case .github: "arrow.triangle.pull"
        case .settings: "gearshape"
        }
    }
}

/// Where the window is pointed. Shared so the notch, shortcuts and banners
/// can open the window at the right place.
@MainActor
final class CompanionNavigation: ObservableObject {
    @Published var section: CompanionSection = .overview {
        didSet {
            guard section != .settings else { return }
            workspaceSection = section
            // A landing from search is for that visit: coming back to
            // Settings opens the pane at its top, not at an old group.
            if settingsAnchor != nil { settingsAnchor = nil }
        }
    }
    @Published var settingsPane: SettingsPane = .general {
        didSet {
            // Going to another pane by hand leaves the last search landing behind.
            if settingsPane != oldValue, settingsAnchor?.pane != settingsPane { settingsAnchor = nil }
        }
    }
    @Published var selectedSessionID: String?
    @Published var selectedHistoryID: String?
    @Published var selectedProjectKey: String?

    /// What is typed in Settings search. Empty shows the pane.
    @Published var settingsSearch = ""
    /// The group of controls Settings was asked to show, and a count that
    /// changes with every request so the same group can be asked for twice.
    @Published private(set) var settingsAnchor: SettingsAnchor?
    @Published private(set) var settingsAnchorRequest = 0
    private var settingsAnchorRequestedAt = Date.distantPast

    /// The workspace page Settings was entered from, for Back.
    private(set) var workspaceSection: CompanionSection = .overview

    var isInSettings: Bool { section == .settings }

    /// Whether the anchor was asked for just now, so a section tints itself
    /// only when it was landed on, not every time its pane is opened.
    var settingsAnchorIsFresh: Bool { Date.now.timeIntervalSince(settingsAnchorRequestedAt) < 1 }

    func show(_ section: CompanionSection, settingsPane: SettingsPane? = nil) {
        if let settingsPane { self.settingsPane = settingsPane }
        self.section = section
    }

    /// Opens Settings on the pane that holds a group of controls and scrolls
    /// to it: where a search result leads, and links from other pages.
    func showSettings(at anchor: SettingsAnchor) {
        settingsSearch = ""
        settingsPane = anchor.pane
        settingsAnchor = anchor
        settingsAnchorRequestedAt = .now
        settingsAnchorRequest += 1
        section = .settings
    }

    /// Back to the workspace page Settings was opened from.
    func leaveSettings() {
        settingsSearch = ""
        section = workspaceSection
    }
}

@MainActor
final class CompanionWindowCoordinator: NSObject, NSWindowDelegate {
    let navigation = CompanionNavigation()
    private let services: OverheadServices
    private var window: NSWindow?
    private var appearanceObserver: AnyCancellable?

    init(services: OverheadServices) {
        self.services = services
    }

    func show(_ section: CompanionSection? = nil, settingsPane: SettingsPane? = nil) {
        if let section { navigation.section = section }
        if let settingsPane { navigation.settingsPane = settingsPane }
        if window == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1060, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Claude Overhead"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 900, height: 600)
            window.tabbingMode = .disallowed
            window.setFrameAutosaveName("OverheadCompanionWindow")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(
                rootView: CompanionRootView(navigation: navigation)
                    // Every @EnvironmentObject a companion page declares must
                    // be handed over here: SwiftUI crashes the app the moment
                    // a page touches one that is missing. A test checks this.
                    .environmentObject(navigation)
                    .environmentObject(services)
                    .environmentObject(services.model)
                    .environmentObject(services.settings)
                    .environmentObject(services.history)
                    .environmentObject(services.github)
            )
            window.center()
            self.window = window
            // The window's appearance follows the theme, so system-drawn text
            // and controls always suit the theme's backgrounds; Match System
            // follows macOS, live, without a restart.
            appearanceObserver = services.settings.$settings
                .map(\.theme)
                .removeDuplicates()
                .sink { [weak window] theme in
                    window?.appearance = ThemeLibrary.windowAppearanceIsDark(for: theme).map { isDark in
                        NSAppearance(named: isDark ? .darkAqua : .aqua)
                    } ?? nil
                }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        services.model.companionWindowChanged(isOpen: true)
    }

    /// A closed window keeps its pages, and they are never told they went
    /// away. The model hears it here, so it stops refreshing usage for a
    /// usage card nobody can see.
    func windowWillClose(_ notification: Notification) {
        services.model.companionWindowChanged(isOpen: false)
    }

    var isVisible: Bool { window?.isVisible == true }
}

struct CompanionRootView: View {
    @ObservedObject var navigation: CompanionNavigation
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = settings.palette(systemIsDark: systemScheme == .dark)
        NavigationSplitView {
            // One sidebar, two lists: the workspace's pages, or, once
            // Settings is entered, its panes with a way back. Never both.
            ZStack {
                if navigation.isInSettings {
                    SettingsSidebar(navigation: navigation)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    List(selection: $navigation.section) {
                        ForEach(CompanionSection.allCases) { section in
                            Label(section.title, systemImage: section.symbol)
                                .tag(section)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: navigation.isInSettings)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .background(palette.surfaceColor)
        } detail: {
            CompanionPage(section: navigation.section, navigation: navigation)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(palette.backgroundColor)
        }
        .tint(palette.accentColor)
        .environment(\.overheadPalette, palette)
        // SwiftUI's own colours (.primary, .secondary, form styles) follow
        // the same light or dark as the palette.
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }
}

/// The sidebar while Settings is open: Back to the workspace, then the
/// panes. It takes the workspace list's place; the two never show together.
struct SettingsSidebar: View {
    @ObservedObject var navigation: CompanionNavigation
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { navigation.leaveSettings() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back to \(navigation.workspaceSection.title)")
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to the workspace (⌘[)")
            .accessibilityLabel("Back to \(navigation.workspaceSection.title)")
            .padding(.horizontal, 8)
            .padding(.top, 4)

            List(selection: Binding<SettingsPane?>(
                get: { navigation.settingsPane },
                set: { pane in
                    guard let pane else { return }
                    navigation.settingsSearch = ""
                    navigation.settingsPane = pane
                }
            )) {
                Section("Settings") {
                    ForEach(SettingsPane.allCases) { pane in
                        Label(pane.title, systemImage: pane.symbol)
                            .tag(pane)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}
