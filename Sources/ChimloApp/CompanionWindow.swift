import AppKit
import ChimloCore
import Combine
import SwiftUI

/// The companion window's sections. The notch stays the hero; this window is
/// where the owner goes to look deeper or to change how the notch behaves.
enum CompanionSection: String, CaseIterable, Identifiable {
    case overview, sessions, projects, agents, history, usage, github, settings

    var id: String { rawValue }

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
    @Published var section: CompanionSection = .overview
    @Published var settingsPane: SettingsPane = .general
    @Published var selectedSessionID: String?
    @Published var selectedHistoryID: String?
    @Published var selectedProjectKey: String?

    func show(_ section: CompanionSection, settingsPane: SettingsPane? = nil) {
        if let settingsPane { self.settingsPane = settingsPane }
        self.section = section
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
                    .environmentObject(services)
                    .environmentObject(services.model)
                    .environmentObject(services.settings)
                    .environmentObject(services.history)
                    .environmentObject(services.github)
            )
            window.center()
            self.window = window
            appearanceObserver = services.settings.$settings
                .map(\.appearance)
                .removeDuplicates()
                .sink { [weak window] appearance in
                    window?.appearance = switch appearance {
                    case .system: nil
                    case .dark: NSAppearance(named: .darkAqua)
                    case .light: NSAppearance(named: .aqua)
                    }
                }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible == true }
}

struct CompanionRootView: View {
    @ObservedObject var navigation: CompanionNavigation
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let palette = settings.palette(systemIsDark: systemScheme == .dark)
        NavigationSplitView {
            List(selection: $navigation.section) {
                ForEach(CompanionSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .scrollContentBackground(.hidden)
            .background(palette.surfaceColor)
        } detail: {
            CompanionPage(section: navigation.section, navigation: navigation)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(palette.backgroundColor)
        }
        .tint(palette.accentColor)
        .environment(\.overheadPalette, palette)
    }
}
