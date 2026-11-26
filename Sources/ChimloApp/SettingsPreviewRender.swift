import AppKit
import ChimloCore
import SwiftUI

/// `Overhead --render-settings <folder>`
///
/// Draws every Settings pane to a PNG, as the companion window shows it,
/// and exits without starting the app: no listener, no hooks, no sessions,
/// no network. Settings come from a throwaway store that is deleted
/// afterwards, so the owner's own are neither read nor changed. The
/// repository picker and the character gallery are also drawn with made-up
/// data, because both are empty without an account and an open session.
///
/// It needs an app bundle (the notifier asks macOS who is calling), so it is
/// run on a packaged build: `make settings-preview`.
@MainActor
enum SettingsRenderCheck {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let flag = arguments.firstIndex(of: "--render-settings") else { return }
        guard flag + 1 < arguments.count else { fail("usage: --render-settings <folder>") }
        let output = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        let problems = render(to: output)
        guard problems.isEmpty else {
            for problem in problems { FileHandle.standardError.write(Data("  ✘ \(problem)\n".utf8)) }
            fail("Settings could not be drawn.")
        }
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }

    static func render(to output: URL) -> [String] {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            return ["Cannot create \(output.path): \(error.localizedDescription)"]
        }
        let suite = "overhead.settings-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return ["No scratch settings store."] }
        defer { defaults.removePersistentDomain(forName: suite) }

        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let settings = SettingsModel(store: SettingsStore(defaults: defaults))
        let services = OverheadServices(model: ApplicationModel(defaults: defaults), settings: settings)
        let navigation = CompanionNavigation()
        var problems: [String] = []

        func root() -> some View {
            CompanionRootView(navigation: navigation)
                .environmentObject(navigation)
                .environmentObject(services)
                .environmentObject(services.model)
                .environmentObject(services.settings)
                .environmentObject(services.history)
                .environmentObject(services.github)
        }

        func snapshot(_ name: String, width: CGFloat = 1060, height: CGFloat, prepare: () -> Void) {
            prepare()
            if let problem = draw(root(), size: CGSize(width: width, height: height), named: name, into: output) {
                problems.append(problem)
            }
        }

        // The window as it opens: the workspace, then Settings in the same sidebar.
        snapshot("00-workspace", height: 700) { navigation.section = .overview }
        let heights: [SettingsPane: CGFloat] = [
            .general: 1180, .appearance: 2700, .notifications: 3150, .usage: 760,
            .shortcuts: 820, .github: 760, .privacy: 1000,
        ]
        for (index, pane) in SettingsPane.allCases.enumerated() {
            snapshot(String(format: "%02d-%@", index + 1, pane.rawValue), height: heights[pane] ?? 1200) {
                navigation.show(.settings, settingsPane: pane)
            }
        }
        snapshot("08-appearance-window", height: 700) { navigation.show(.settings, settingsPane: .appearance) }
        snapshot("09-search", height: 700) {
            navigation.show(.settings, settingsPane: .general)
            navigation.settingsSearch = "glow"
        }
        snapshot("10-search-none", height: 700) { navigation.settingsSearch = "zzzz" }
        navigation.settingsSearch = ""
        // The window at its smallest: nothing may be cut off or pushed out.
        snapshot("14-appearance-smallest-window", width: 900, height: 1500) {
            navigation.show(.settings, settingsPane: .appearance)
        }
        snapshot("15-notifications-smallest-window", width: 900, height: 600) {
            navigation.show(.settings, settingsPane: .notifications)
        }

        // A light theme, glow off, automatic characters on: the other states.
        settings.settings.theme = .arctic
        settings.settings.setCompletionGlowEnabled(false)
        settings.settings.assignCharactersAutomatically = true
        settings.settings.projectCharacterPools = [
            "/Users/example/Projects/api-gateway": ["animals.cat", "animals.fox", "elementals.sprout"],
            "/Users/example/Projects/web-app": ["cyber.mecha-fox"],
        ]
        snapshot("11-appearance-light", height: 2700) { navigation.show(.settings, settingsPane: .appearance) }
        settings.settings.theme = OverheadSettings().theme

        // The two parts that need data, with data that belongs to nobody.
        let palette = settings.palette(systemIsDark: true)
        func part<V: View>(_ view: V, _ name: String, size: CGSize) {
            let framed = view
                .padding(24)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(palette.backgroundColor)
                .environment(\.overheadPalette, palette)
                .environment(\.colorScheme, .dark)
                .tint(palette.accentColor)
            if let problem = draw(framed, size: size, named: name, into: output) { problems.append(problem) }
        }
        part(
            CharacterGallery(
                sessions: [
                    CharacterGallery.Session(id: "s1", title: "api-gateway", worn: CharacterCatalog.character(id: "fantasy.unicorn")),
                    CharacterGallery.Session(id: "s2", title: "web-app", worn: nil),
                    CharacterGallery.Session(id: "s3", title: "docs-site", worn: CharacterCatalog.character(id: "cyber.mecha-fox")),
                ],
                reduceMotion: true,
                apply: { _, _ in }
            ),
            "12-gallery-with-sessions",
            size: CGSize(width: 840, height: 1010)
        )
        var selection = GitHubRepositorySelection()
        let repositories = sampleRepositories
        for repository in repositories where [1, 2, 11].contains(repository.id) { selection.select(repository) }
        part(
            GitHubRepositoryPicker(
                saved: selection,
                listed: repositories,
                viewer: "octo-dev",
                claudeRepositoryIDs: [1],
                isUnavailable: { $0 == 12 },
                load: .loaded,
                alertLevel: { _ in .all },
                setAlertLevel: { _, _ in },
                apply: { _ in },
                reload: {}
            ),
            "13-repository-picker",
            size: CGSize(width: 840, height: 560)
        )
        if problems.isEmpty { print("Settings: \(SettingsPane.allCases.count) panes drawn to \(output.path)") }
        return problems
    }

    /// Repositories of three owners that do not exist, two of them holding a
    /// repository with the same name.
    private static var sampleRepositories: [GitHubRepoRef] {
        [
            GitHubRepoRef(id: 1, owner: "octo-dev", name: "notch-tools", isPrivate: false),
            GitHubRepoRef(id: 2, owner: "octo-dev", name: "website", isPrivate: true),
            GitHubRepoRef(id: 3, owner: "octo-dev", name: "dotfiles", isPrivate: false),
            GitHubRepoRef(id: 11, owner: "acme-labs", name: "website", isPrivate: true),
            GitHubRepoRef(id: 12, owner: "acme-labs", name: "billing-service", isPrivate: true),
            GitHubRepoRef(id: 13, owner: "acme-labs", name: "design-system", isPrivate: false),
            GitHubRepoRef(id: 21, owner: "northwind", name: "inventory", isPrivate: true),
            GitHubRepoRef(id: 22, owner: "northwind", name: "storefront", isPrivate: true),
        ]
    }

    /// Draws a view in a window that is never shown, which is what lets the
    /// system's own controls (switches, sliders, menus) appear in the
    /// picture. Returns what went wrong, or nil.
    private static func draw<V: View>(_ view: V, size: CGSize, named name: String, into output: URL) -> String? {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.layoutIfNeeded()
        // Lazy grids, onAppear work and scroll positions settle over a few turns.
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
        }
        defer { window.close() }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return "\(name) has no bitmap." }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return "\(name) could not be written as a PNG." }
        do {
            try png.write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
            return nil
        } catch {
            return "\(name): \(error.localizedDescription)"
        }
    }
}
