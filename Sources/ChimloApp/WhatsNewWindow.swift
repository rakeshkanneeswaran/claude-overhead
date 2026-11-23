import AppKit
import ChimloCore
import SwiftUI

// What's New: the walkthrough of one release.
//
// It opens when a check the owner asked for finds an update, on that
// update's own notes, and nothing is downloaded until "Update Now" is
// clicked. The same window shows the notes this copy was built with.
// Everything it draws comes from `ReleaseNotes`; no release's text or
// pictures live in these views.

/// What a What's New window is about.
enum WhatsNewSubject: Equatable {
    /// The update on offer.
    case update
    /// The version that is installed.
    case installed
}

/// The notes packaged inside this copy (`Contents/Resources/WhatsNew.json`).
struct InstalledReleaseNotes: Equatable {
    let notes: ReleaseNotes
    let assets: WhatsNewAssets
    /// A development build carries the notes of the release being prepared,
    /// which is not the version it says it is.
    let isPreview: Bool

    var menuTitle: String {
        isPreview ? "Preview What's New in \(notes.version)" : "What's New in \(notes.version)"
    }

    static func load(bundle: Bundle = .main) -> InstalledReleaseNotes? {
        guard let url = bundle.url(forResource: "WhatsNew", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        let installed = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var content = ReleaseNotesReader.content(data: data, expectedVersion: installed)
        // Only a build that cannot update itself (a development build) may
        // show notes for another version, and it says "Preview".
        if case let .unavailable(.wrongVersion(found)) = content,
           bundle.object(forInfoDictionaryKey: "SUFeedURL") == nil {
            content = ReleaseNotesReader.content(data: data, expectedVersion: found)
        }
        guard let notes = content.notes else { return nil }
        let folder = url.deletingLastPathComponent().appendingPathComponent("WhatsNew", isDirectory: true)
        return InstalledReleaseNotes(notes: notes, assets: .bundled(folder), isPreview: notes.version != installed)
    }
}

/// Everything one What's New window shows.
struct WhatsNewContent: Equatable {
    let subject: WhatsNewSubject
    let version: String
    /// The version being left behind, when this is an update.
    let installedVersion: String?
    let content: ReleaseNotesContent
    let assets: WhatsNewAssets
    let releasePage: URL?

    init(
        subject: WhatsNewSubject,
        version: String,
        installedVersion: String?,
        content: ReleaseNotesContent,
        assets: WhatsNewAssets,
        releasePage: URL?
    ) {
        self.subject = subject
        self.version = version
        self.installedVersion = installedVersion
        self.content = content
        self.assets = assets
        self.releasePage = releasePage
    }

    init(offer: ReleaseOffer) {
        subject = .update
        version = offer.version
        installedVersion = offer.installedVersion.isEmpty ? nil : offer.installedVersion
        content = offer.content
        assets = offer.assetBase.map(WhatsNewAssets.remote) ?? .none
        releasePage = offer.releasePage
    }

    init(installed: InstalledReleaseNotes) {
        subject = .installed
        version = installed.notes.version
        installedVersion = nil
        content = .notes(installed.notes)
        assets = installed.assets
        releasePage = nil
    }
}

enum WhatsNewLayout {
    static let windowSize = CGSize(width: 720, height: 640)
    static let gutter: CGFloat = 40
    /// The title bar adds its own 28 points above this in a window.
    static let headerHeight: CGFloat = 62
    static let footerHeight: CGFloat = 74
    static let stageHeight: CGFloat = 236
}

struct WhatsNewActions {
    var previous: () -> Void = {}
    var next: () -> Void = {}
    var open: (Int) -> Void = { _ in }
    var update: () -> Void = {}
    var retry: () -> Void = {}
    var close: () -> Void = {}
    var openReleasePage: () -> Void = {}
    var copyInstallCommand: () -> Void = {}
}

// MARK: Window

@MainActor
final class WhatsNewCoordinator: NSObject, NSWindowDelegate {
    static let windowTitle = "What's New in Claude Overhead"

    private let model: ApplicationModel
    private var window: NSWindow?

    init(model: ApplicationModel) {
        self.model = model
    }

    func show(_ subject: WhatsNewSubject) {
        let window = window ?? makeWindow()
        self.window = window
        window.contentView = NSHostingView(rootView: WhatsNewWindowView(
            model: model,
            subject: subject,
            close: { [weak window] in window?.close() }
        ))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let size = WhatsNewLayout.windowSize
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(SetupTheme.canvas)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Closing the window changes nothing about the update: an offer stays
    /// on offer, and a download that is running carries on.
    func windowWillClose(_ notification: Notification) {
        // Let the content go, so its animations do not run off screen.
        let closed = window
        window = nil
        DispatchQueue.main.async { closed?.contentView = nil }
    }
}

/// Joins the window to the app: which notes, where the update stands, and
/// what the buttons do.
struct WhatsNewWindowView: View {
    @ObservedObject var model: ApplicationModel
    let subject: WhatsNewSubject
    let close: () -> Void

    private var content: WhatsNewContent? {
        switch subject {
        case .update: model.updateOffer.map(WhatsNewContent.init(offer:))
        case .installed: model.installedReleaseNotes.map(WhatsNewContent.init(installed:))
        }
    }

    var body: some View {
        Group {
            if let content {
                WhatsNewWalkthroughView(
                    content: content,
                    stage: subject == .update ? WhatsNewUpdateStage(phase: model.updatePresentation?.phase) : .ready,
                    reduceMotion: model.accessibility.reduceMotion,
                    // The version these notes are for travels with the click.
                    update: { model.installOfferedUpdate(showing: content.version) },
                    retry: model.retryUpdate,
                    close: close
                )
                // A different release is a different walkthrough, from its start.
                .id(content.version)
            } else {
                // The offer went away (a new check found nothing newer).
                WhatsNewGone(close: close)
            }
        }
        .frame(width: WhatsNewLayout.windowSize.width, height: WhatsNewLayout.windowSize.height)
    }
}

private struct WhatsNewWalkthroughView: View {
    let content: WhatsNewContent
    let stage: WhatsNewUpdateStage
    let reduceMotion: Bool
    let update: () -> Void
    let retry: () -> Void
    let close: () -> Void

    @State private var walkthrough: WhatsNewWalkthrough
    @State private var movesForward = true

    init(
        content: WhatsNewContent,
        stage: WhatsNewUpdateStage,
        reduceMotion: Bool,
        update: @escaping () -> Void,
        retry: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.content = content
        self.stage = stage
        self.reduceMotion = reduceMotion
        self.update = update
        self.retry = retry
        self.close = close
        _walkthrough = State(initialValue: WhatsNewWalkthrough(cardCount: content.content.notes?.cards.count ?? 0))
    }

    var body: some View {
        WhatsNewScreen(
            content: content,
            walkthrough: walkthrough,
            stage: stage,
            reduceMotion: reduceMotion,
            movesForward: movesForward,
            actions: WhatsNewActions(
                previous: { move { $0.previous() } },
                next: { move { $0.next() } },
                open: { card in move { $0.open(card: card) } },
                update: update,
                retry: retry,
                close: close,
                openReleasePage: {
                    if let page = content.releasePage { NSWorkspace.shared.open(page) }
                },
                copyInstallCommand: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppUpdateFailure.installCommand, forType: .string)
                }
            )
        )
        .onExitCommand(perform: close)
    }

    private func move(_ change: (inout WhatsNewWalkthrough) -> Void) {
        var next = walkthrough
        change(&next)
        guard next != walkthrough else { return }
        movesForward = next.index > walkthrough.index
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.9)) {
            walkthrough = next
        }
    }
}

// MARK: The screen

/// The whole window as a function of its state, so the release check can
/// draw every page of a release's notes without opening a window.
struct WhatsNewScreen: View {
    let content: WhatsNewContent
    let walkthrough: WhatsNewWalkthrough
    let stage: WhatsNewUpdateStage
    let reduceMotion: Bool
    var movesForward = true
    var actions = WhatsNewActions()

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: WhatsNewLayout.headerHeight, alignment: .bottom)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, WhatsNewLayout.gutter)
                .padding(.top, 18)
                .clipped()
            WhatsNewFooter(content: content, walkthrough: walkthrough, stage: stage, actions: actions)
                .frame(height: WhatsNewLayout.footerHeight)
        }
        .frame(width: WhatsNewLayout.windowSize.width, height: WhatsNewLayout.windowSize.height)
        .background(WhatsNewBackdrop())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ClaudeCodeMark(mood: .success, size: 24, reduceMotion: true)
                .accessibilityHidden(true)
            Text("What's New")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SetupTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            VersionPill(content: content)
        }
        .padding(.horizontal, WhatsNewLayout.gutter)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var page: some View {
        switch content.content {
        case let .notes(notes):
            Group {
                switch walkthrough.page {
                case .overview:
                    WhatsNewOverview(content: content, notes: notes, open: actions.open)
                case let .card(index):
                    if notes.cards.indices.contains(index) {
                        WhatsNewCardPage(card: notes.cards[index], assets: content.assets, reduceMotion: reduceMotion)
                    }
                }
            }
            .id(walkthrough.index)
            .transition(pageTransition)
        case let .unavailable(problem):
            WhatsNewUnavailable(content: content, problem: problem, openReleasePage: actions.openReleasePage)
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: movesForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movesForward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

private struct WhatsNewBackdrop: View {
    var body: some View {
        ZStack {
            SetupTheme.canvas
            RadialGradient(
                colors: [SetupTheme.accent.opacity(0.15), .clear],
                center: UnitPoint(x: 0.5, y: -0.1),
                startRadius: 0,
                endRadius: 440
            )
        }
        .ignoresSafeArea()
    }
}

/// The installed and the new version for an update ("1.2.3 → 1.2.4"), or
/// just "Version 1.2.4" for the notes of the version that is installed.
private struct VersionPill: View {
    let content: WhatsNewContent

    var body: some View {
        HStack(spacing: 7) {
            if content.subject == .update, let installed = content.installedVersion {
                Text(installed)
                    .foregroundStyle(SetupTheme.textTertiary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SetupTheme.textTertiary)
                Text(content.version)
                    .foregroundStyle(SetupTheme.accent)
            } else {
                Text("Version \(content.version)")
                    .foregroundStyle(SetupTheme.textSecondary)
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Capsule().fill(SetupTheme.raised))
        .overlay(Capsule().strokeBorder(SetupTheme.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if content.subject == .update, let installed = content.installedVersion {
            return "You have version \(installed). Version \(content.version) is available."
        }
        return "Version \(content.version)"
    }
}

extension ReleaseCategory {
    var tint: Color {
        switch self {
        case .feature: SetupTheme.accent
        case .improvement: ChimloTheme.providerBlue
        case .fix: SetupTheme.success
        case .other: SetupTheme.textSecondary
        }
    }

    var symbol: String {
        switch self {
        case .feature: "sparkles"
        case .improvement: "arrow.up.right"
        case .fix: "wrench.and.screwdriver.fill"
        case .other: "circle.fill"
        }
    }
}

private struct CategoryBadge: View {
    let category: ReleaseCategory

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: category.symbol)
                .font(.system(size: 9, weight: .bold))
            Text(category.displayName.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
        }
        .foregroundStyle(category.tint)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(category.tint.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category.displayName)
    }
}

// MARK: Pages

private struct WhatsNewOverview: View {
    let content: WhatsNewContent
    let notes: ReleaseNotes
    let open: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content.subject == .update ? "Claude Overhead \(notes.version)" : "What's new in \(notes.version)")
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.6)
                .foregroundStyle(SetupTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let date = notes.displayDate {
                Text("Released \(date)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SetupTheme.textTertiary)
                    .padding(.top, 5)
            }
            Text(notes.introduction)
                .font(.system(size: 14.5))
                .foregroundStyle(SetupTheme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            HStack(spacing: 8) {
                ForEach(notes.categoryCounts, id: \.category) { entry in
                    Text(entry.category.counted(entry.count))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.category.tint)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(entry.category.tint.opacity(0.13)))
                }
            }
            .padding(.top, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notes.summaryLine)

            contents
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }

    /// Up to six changes in one column, more in two. Everything is on the
    /// page at once: nothing to scroll for, and every row opens its card.
    private static let maximumRows = 6

    private var contents: some View {
        let cards = Array(notes.cards.enumerated())
        let columns = cards.count > Self.maximumRows ? 2 : 1
        let shown = Array(cards.prefix(Self.maximumRows * columns))
        let rows = stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.element.id) { index, card in
                        OverviewRow(card: card, showsCategory: columns == 1) { open(index) }
                    }
                    if row.count < columns {
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
            }
            if cards.count > shown.count {
                Text("and \(cards.count - shown.count) more, on the pages that follow")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SetupTheme.textTertiary)
                    .padding(.top, 4)
            }
        }
    }
}

private struct OverviewRow: View {
    let card: ReleaseCard
    var showsCategory = true
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 11) {
                Image(systemName: card.category.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(card.category.tint)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(card.category.tint.opacity(0.14)))
                Text(card.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SetupTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                if showsCategory {
                    Text(card.category.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(SetupTheme.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SetupTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0.035))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(card.title)
        .accessibilityLabel("\(card.category.displayName): \(card.title)")
        .accessibilityHint("Opens this change.")
    }
}

private struct WhatsNewCardPage: View {
    let card: ReleaseCard
    let assets: WhatsNewAssets
    let reduceMotion: Bool

    /// A visual this copy can draw. A card without one is a clean text card;
    /// nothing generic is drawn in its place.
    private var visual: ReleaseVisual? {
        guard let visual = card.visual, visual.isSupported else { return nil }
        return visual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let visual {
                WhatsNewVisualView(visual: visual, assets: assets, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity)
                    .frame(height: WhatsNewLayout.stageHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SetupTheme.raised)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SetupTheme.hairline, lineWidth: 1)
                    )
                    .padding(.bottom, 22)
            } else {
                // No picture: the category's own mark, and room for the words.
                Image(systemName: card.category.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(card.category.tint)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(card.category.tint.opacity(0.13)))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(card.category.tint.opacity(0.22), lineWidth: 1))
                    .padding(.top, 34)
                    .padding(.bottom, 20)
                    .accessibilityHidden(true)
            }
            CategoryBadge(category: card.category)
            Text(card.title)
                .font(.system(size: visual == nil ? 28 : 23, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(SetupTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 11)
                .accessibilityAddTraits(.isHeader)
            Text(card.summary)
                .font(.system(size: visual == nil ? 15 : 14))
                .foregroundStyle(SetupTheme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let details = card.details, !details.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle()
                                .fill(card.category.tint.opacity(0.9))
                                .frame(width: 4, height: 4)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            Text(detail)
                                .font(.system(size: 12.5))
                                .foregroundStyle(SetupTheme.textSecondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The honest fallback: the update is real, its notes are not available, and
/// nothing else is shown in their place.
private struct WhatsNewUnavailable: View {
    let content: WhatsNewContent
    let problem: ReleaseNotesProblem
    let openReleasePage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: "doc.text")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(SetupTheme.textTertiary)
                .frame(width: 60, height: 60)
                .background(Circle().fill(SetupTheme.raised))
                .accessibilityHidden(true)
            Text("Version \(content.version) is available")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(SetupTheme.textPrimary)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text(problem.explanation)
                .font(.system(size: 14))
                .foregroundStyle(SetupTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 8)
            Text("You can still update: Update Now installs version \(content.version), checked the same way as always.")
                .font(.system(size: 12.5))
                .foregroundStyle(SetupTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 6)
            if content.releasePage != nil {
                Button("Read the release notes on GitHub", action: openReleasePage)
                    .buttonStyle(SetupSecondaryButtonStyle())
                    .padding(.top, 14)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WhatsNewGone: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(SetupTheme.success)
                .accessibilityHidden(true)
            Text("You're up to date")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(SetupTheme.textPrimary)
                .padding(.top, 16)
            Text("There is no newer version of Claude Overhead to install.")
                .font(.system(size: 14))
                .foregroundStyle(SetupTheme.textSecondary)
                .padding(.top, 6)
            Button("Close", action: close)
                .buttonStyle(SetupPrimaryButtonStyle())
                .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WhatsNewBackdrop())
        .preferredColorScheme(.dark)
    }
}

// MARK: Footer

private struct WhatsNewFooter: View {
    let content: WhatsNewContent
    let walkthrough: WhatsNewWalkthrough
    let stage: WhatsNewUpdateStage
    let actions: WhatsNewActions

    private var hasPages: Bool { content.content.notes != nil }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(SetupTheme.hairline).frame(height: 1)
            HStack(spacing: 12) {
                if case let .failed(summary, recovery, canRetry, showsInstallCommand) = stage, content.subject == .update {
                    failure(summary: summary, recovery: recovery, canRetry: canRetry, showsInstallCommand: showsInstallCommand)
                } else {
                    if hasPages { navigation }
                    Spacer(minLength: 12)
                    trailing
                }
            }
            .padding(.horizontal, 26)
            .frame(maxHeight: .infinity)
        }
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            Button(action: actions.previous) {
                Label("Previous", systemImage: "chevron.left")
            }
            .buttonStyle(SetupSecondaryButtonStyle())
            .disabled(!walkthrough.canGoBack)
            .opacity(walkthrough.canGoBack ? 1 : 0.35)
            .keyboardShortcut(.leftArrow, modifiers: [])

            ProgressDots(walkthrough: walkthrough)
                .padding(.horizontal, 8)

            Button(action: actions.next) {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(SetupSecondaryButtonStyle())
            .disabled(!walkthrough.canGoForward)
            .opacity(walkthrough.canGoForward ? 1 : 0.35)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if content.subject == .installed {
            Button("Done", action: actions.close)
                .buttonStyle(SetupPrimaryButtonStyle())
        } else {
            switch stage {
            case .ready, .failed:
                // Deliberately without a default key: this window can open
                // while the owner is typing, and Return must not install.
                Button("Update Now", action: actions.update)
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .accessibilityHint("Downloads, verifies and installs version \(content.version), then restarts Claude Overhead.")
            case let .working(label, progress):
                HStack(spacing: 10) {
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(SetupTheme.accent)
                            .frame(width: 130)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(label)
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(SetupTheme.textSecondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
            case .upToDate:
                Text("Claude Overhead is up to date")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SetupTheme.textSecondary)
                Button("Close", action: actions.close)
                    .buttonStyle(SetupPrimaryButtonStyle())
            }
        }
    }

    private func failure(summary: String, recovery: String, canRetry: Bool, showsInstallCommand: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(SetupTheme.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update failed: \(summary)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SetupTheme.textPrimary)
                    .lineLimit(1)
                Text(recovery)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SetupTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if showsInstallCommand {
                Button("Copy Terminal Command", action: actions.copyInstallCommand)
                    .buttonStyle(SetupSecondaryButtonStyle())
                    .help(AppUpdateFailure.installCommand)
            }
            if canRetry {
                Button("Try Again", action: actions.retry)
                    .buttonStyle(SetupPrimaryButtonStyle())
            } else {
                Button("Close", action: actions.close)
                    .buttonStyle(SetupPrimaryButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon
        }
    }
}

/// One dot per page, and "2 of 5" beside them.
private struct ProgressDots: View {
    let walkthrough: WhatsNewWalkthrough

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<walkthrough.pageCount, id: \.self) { page in
                    Capsule()
                        .fill(page == walkthrough.index ? SetupTheme.accent : Color.white.opacity(0.18))
                        .frame(width: page == walkthrough.index ? 16 : 6, height: 6)
                }
            }
            Text(walkthrough.progressLabel)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(SetupTheme.textTertiary)
                .frame(minWidth: 56, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(walkthrough.accessibilityProgress)
    }
}

// MARK: Release check

/// `Overhead --render-whats-new <notes.json> --output <folder> [--assets <folder>] [--from <version>]`
///
/// Draws every page of a release's notes exactly as the window would, to PNG
/// files, without opening a window, and fails when a page cannot be drawn.
/// The release workflow runs it on the app it is about to publish, so no
/// release ships notes its own What's New cannot show.
@MainActor
enum WhatsNewRenderCheck {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let flag = arguments.firstIndex(of: "--render-whats-new"), flag + 1 < arguments.count else { return }
        let output = arguments.firstIndex(of: "--output").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let assets = arguments.firstIndex(of: "--assets").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let from = arguments.firstIndex(of: "--from").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        guard let output else {
            fail("usage: --render-whats-new <notes.json> --output <folder> [--assets <folder>] [--from <version>]")
        }
        let problems = render(
            notesPath: arguments[flag + 1],
            output: URL(fileURLWithPath: output, isDirectory: true),
            assets: assets.map { URL(fileURLWithPath: $0, isDirectory: true) },
            installedVersion: from
        )
        guard problems.isEmpty else {
            for problem in problems { FileHandle.standardError.write(Data("  ✘ \(problem)\n".utf8)) }
            fail("What's New cannot show these notes.")
        }
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }

    /// `installedVersion` is the version the window is drawn as updating from.
    static func render(notesPath: String, output: URL, assets: URL?, installedVersion: String? = nil) -> [String] {
        struct Header: Decodable { let version: String }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: notesPath)),
              let header = try? JSONDecoder().decode(Header.self, from: data) else {
            return ["\(notesPath) cannot be read as release notes."]
        }
        // Read exactly as an installed copy reads the feed.
        guard case let .notes(notes) = ReleaseNotesReader.content(data: data, expectedVersion: header.version) else {
            return ["The app does not accept \(notesPath) as the notes of \(header.version)."]
        }
        var problems: [String] = []
        for card in notes.cards {
            guard let visual = card.visual else { continue }
            if !visual.isSupported {
                problems.append("card \"\(card.id)\": this app cannot draw its \"\(visual.kind)\" visual.")
            }
            if case let .image(image) = visual {
                if let assets, let picture = WhatsNewImageStore.bundledPicture(image, in: assets) {
                    _ = picture
                } else {
                    problems.append("card \"\(card.id)\": the picture \"\(image.file)\" is missing or does not match its SHA-256.")
                }
            }
        }
        guard problems.isEmpty else { return problems }

        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            return ["Cannot create \(output.path): \(error.localizedDescription)"]
        }
        let content = WhatsNewContent(offer: ReleaseOffer(
            version: notes.version,
            installedVersion: installedVersion.flatMap { AppVersion($0) == nil ? nil : $0 } ?? "",
            content: .notes(notes),
            assetBase: nil
        ))
        var walkthrough = WhatsNewWalkthrough(cardCount: notes.cards.count)
        for page in 0..<walkthrough.pageCount {
            walkthrough.go(to: page)
            let name: String
            switch walkthrough.page {
            case .overview: name = "00-overview"
            case let .card(index): name = String(format: "%02d-%@", index + 1, notes.cards[index].id)
            }
            let screen = WhatsNewScreen(
                content: WhatsNewContent(
                    subject: .update,
                    version: content.version,
                    installedVersion: content.installedVersion,
                    content: content.content,
                    assets: assets.map(WhatsNewAssets.bundled) ?? .none,
                    releasePage: nil
                ),
                walkthrough: walkthrough,
                stage: .ready,
                reduceMotion: true
            )
            let renderer = ImageRenderer(content: screen)
            renderer.scale = 2
            guard let image = renderer.cgImage, isDrawn(image) else {
                problems.append("page \(name) drew nothing.")
                continue
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                problems.append("page \(name) could not be written as a PNG.")
                continue
            }
            do {
                try png.write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
            } catch {
                problems.append("page \(name): \(error.localizedDescription)")
            }
        }
        if problems.isEmpty {
            print("What's New \(notes.version): \(walkthrough.pageCount) pages drawn to \(output.path)")
        }
        return problems
    }

    /// A page that drew is the window's size and is not one flat colour.
    private static func isDrawn(_ image: CGImage) -> Bool {
        guard image.width == Int(WhatsNewLayout.windowSize.width) * 2,
              image.height == Int(WhatsNewLayout.windowSize.height) * 2,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        let step = max(4, (length / 4_000) & ~3)
        var seen: Set<UInt32> = []
        var offset = 0
        while offset + 3 < length, seen.count < 12 {
            seen.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            offset += step
        }
        return seen.count >= 12
    }
}
