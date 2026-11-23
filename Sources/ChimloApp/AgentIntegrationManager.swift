import ChimloCore
import Foundation

enum AgentProvider: String, CaseIterable, Sendable {
    case claude

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        }
    }
}

enum AgentConnectionState: Equatable, Sendable {
    case checking
    case disconnected
    case installedAwaitingEvent
    case receiving(Date)
    case needsRepair
    case unavailable(String)

    var isInstalled: Bool {
        switch self {
        case .installedAwaitingEvent, .receiving:
            true
        case .checking, .disconnected, .needsRepair, .unavailable:
            false
        }
    }

    var isReceiving: Bool {
        if case .receiving = self { return true }
        return false
    }
}

/// Owns the complete hook-installation seam for supported agents: stable helper
/// deployment, read-only status, full preview, marker-scoped merge, validation,
/// backup, and removal.
struct AgentIntegrationManager {
    let claudeSettingsURL: URL
    let bundledHelperURL: URL
    let stableHelperURL: URL
    let claudeStatusLineWrapperURL: URL
    let claudeStatusLineDelegateURL: URL
    let claudeCapacityCacheURL: URL

    static func live(bundle: Bundle = .main, fileManager: FileManager = .default) -> AgentIntegrationManager {
        let home = fileManager.homeDirectoryForCurrentUser
        let applicationSupport = home
            .appendingPathComponent("Library/Application Support/Overhead", isDirectory: true)
        let binaryDirectory = applicationSupport.appendingPathComponent("bin", isDirectory: true)
        return AgentIntegrationManager(
            claudeSettingsURL: home
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json"),
            bundledHelperURL: bundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("overhead"),
            stableHelperURL: binaryDirectory.appendingPathComponent("overhead"),
            claudeStatusLineWrapperURL: binaryDirectory
                .appendingPathComponent("overhead-claude-statusline"),
            claudeStatusLineDelegateURL: binaryDirectory
                .appendingPathComponent("overhead-claude-statusline-delegate"),
            claudeCapacityCacheURL: applicationSupport
                .appendingPathComponent("capacity", isDirectory: true)
                .appendingPathComponent("claude.json")
        )
    }

    /// An app opened from a downloaded disk image is quarantined, and a copy
    /// of its helper keeps the flag. Claude Code runs that copy from a
    /// shell, where macOS refuses a quarantined program that is not
    /// notarised, and every hook would fail. The owner has already chosen to
    /// run this app; its own helper is part of it. (The install script
    /// removes the flag from the whole app in the same way.)
    private static func removeQuarantine(from url: URL) {
        _ = url.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
    }

    /// Copies the signed helper out of the movable app bundle. Hook files only
    /// reference this stable path, so renaming or relocating Claude Overhead.app does not
    /// silently break future events.
    @discardableResult
    func prepareStableHelper(fileManager: FileManager = .default) throws -> URL {
        guard fileManager.isExecutableFile(atPath: bundledHelperURL.path) else {
            if fileManager.isExecutableFile(atPath: stableHelperURL.path) {
                return stableHelperURL
            }
            throw IntegrationError.helperUnavailable
        }

        let directory = stableHelperURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let needsCopy = !fileManager.fileExists(atPath: stableHelperURL.path)
            || !fileManager.contentsEqual(
                atPath: bundledHelperURL.path,
                andPath: stableHelperURL.path
            )

        if needsCopy {
            let stagingURL = directory.appendingPathComponent("overhead.installing")
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            try fileManager.copyItem(at: bundledHelperURL, to: stagingURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingURL.path)
            Self.removeQuarantine(from: stagingURL)

            if fileManager.fileExists(atPath: stableHelperURL.path) {
                _ = try fileManager.replaceItemAt(stableHelperURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: stableHelperURL)
            }
        }

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stableHelperURL.path)
        // Also a copy made by an earlier version, which kept the flag.
        Self.removeQuarantine(from: stableHelperURL)
        guard fileManager.isExecutableFile(atPath: stableHelperURL.path) else {
            throw IntegrationError.helperUnavailable
        }
        return stableHelperURL
    }

    func status(
        for provider: AgentProvider,
        lastReceiptAt: Date?,
        fileManager: FileManager = .default
    ) -> AgentConnectionState {
        guard fileManager.isExecutableFile(atPath: stableHelperURL.path) else {
            return .unavailable("Package Claude Overhead once to install its local helper")
        }

        do {
            let data = try configurationData(for: provider, fileManager: fileManager)
            switch provider {
            case .claude:
                let hookState = try ClaudeHookConfiguration.installationState(
                    in: data,
                    helperPath: stableHelperURL.path
                )
                let statusLineState = try ClaudeStatusLineConfiguration.installationState(
                    in: data,
                    wrapperPath: claudeStatusLineWrapperURL.path
                )
                if hookState == .missing && statusLineState == .missing { return .disconnected }
                guard hookState == .current,
                      statusLineState == .current,
                      fileManager.isExecutableFile(atPath: claudeStatusLineWrapperURL.path) else {
                    return .needsRepair
                }
                if try ClaudeStatusLineConfiguration.originalCommand(in: data ?? Data()) != nil,
                   !fileManager.isExecutableFile(atPath: claudeStatusLineDelegateURL.path) {
                    return .needsRepair
                }
            }

            if let lastReceiptAt, lastReceiptAt >= Date.now.addingTimeInterval(-30 * 60) {
                return .receiving(lastReceiptAt)
            }
            return .installedAwaitingEvent
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func preview(for provider: AgentProvider, fileManager: FileManager = .default) throws -> String {
        _ = try prepareStableHelper(fileManager: fileManager)
        let existing = try configurationData(for: provider, fileManager: fileManager)
        let data: Data
        switch provider {
        case .claude:
            let hookPlan = try ClaudeHookConfiguration.merging(
                existingData: existing,
                helperPath: stableHelperURL.path
            )
            data = try ClaudeStatusLineConfiguration.merging(
                existingData: hookPlan.data,
                wrapperPath: claudeStatusLineWrapperURL.path
            ).data
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// What a connect actually did, so setup can say so truthfully.
    struct ConnectionReport: Sendable {
        /// The settings file was rewritten. False means it was already current.
        let changedSettings: Bool
        /// Set when this connect saved the one-time copy of the original file.
        let createdBackup: URL?
    }

    @discardableResult
    func connect(_ provider: AgentProvider, fileManager: FileManager = .default) throws -> ConnectionReport {
        _ = try prepareStableHelper(fileManager: fileManager)
        let destination = configurationURL(for: provider)
        let existing = try configurationData(for: provider, fileManager: fileManager)
        let plannedData: Data
        let changed: Bool

        switch provider {
        case .claude:
            let hookPlan = try ClaudeHookConfiguration.merging(
                existingData: existing,
                helperPath: stableHelperURL.path
            )
            let statusLinePlan = try ClaudeStatusLineConfiguration.merging(
                existingData: hookPlan.data,
                wrapperPath: claudeStatusLineWrapperURL.path
            )
            plannedData = statusLinePlan.data
            changed = hookPlan.changed || statusLinePlan.changed
            try prepareClaudeStatusLineScripts(
                originalCommand: try ClaudeStatusLineConfiguration.originalCommand(
                    in: plannedData
                ),
                fileManager: fileManager
            )
        }
        guard changed else { return ConnectionReport(changedSettings: false, createdBackup: nil) }

        let backup = try writeConfiguration(
            plannedData,
            to: destination,
            existingData: existing,
            provider: provider,
            fileManager: fileManager
        )
        return ConnectionReport(changedSettings: true, createdBackup: backup)
    }

    /// Adds or repairs the capacity bridge for Claude integrations that were
    /// connected before the bridge existed. The current status-line command is
    /// retained as Claude Overhead's delegate, so another app keeps receiving the same
    /// Claude payload after the upgrade.
    @discardableResult
    func upgradeClaudeCapacityBridgeIfConnected(
        fileManager: FileManager = .default
    ) throws -> Bool {
        _ = try prepareStableHelper(fileManager: fileManager)
        let existing = try configurationData(for: .claude, fileManager: fileManager)
        guard let plan = try ClaudeStatusLineConfiguration.upgradingConnectedInstallation(
            existingData: existing,
            helperPath: stableHelperURL.path,
            wrapperPath: claudeStatusLineWrapperURL.path
        ) else {
            return false
        }

        try prepareClaudeStatusLineScripts(
            originalCommand: try ClaudeStatusLineConfiguration.originalCommand(in: plan.data),
            fileManager: fileManager
        )
        if plan.changed {
            do {
                try writeConfiguration(
                    plan.data,
                    to: claudeSettingsURL,
                    existingData: existing,
                    provider: .claude,
                    fileManager: fileManager
                )
            } catch ConfigurationFileWriter.WriteError.changedMeanwhile {
                // Nobody asked for this write. Leave Claude Code's newer file
                // alone; the next launch tries again.
                return false
            }
        }
        return true
    }

    func disconnect(_ provider: AgentProvider, fileManager: FileManager = .default) throws {
        let destination = configurationURL(for: provider)
        guard fileManager.fileExists(atPath: destination.path) else {
            if provider == .claude { removeClaudeStatusLineScripts(fileManager: fileManager) }
            return
        }
        let existing = try Data(contentsOf: destination)
        let data: Data
        let changed: Bool
        switch provider {
        case .claude:
            let hookPlan = try ClaudeHookConfiguration.removing(existingData: existing)
            let statusLinePlan = try ClaudeStatusLineConfiguration.removing(
                existingData: hookPlan.data,
                wrapperPath: claudeStatusLineWrapperURL.path
            )
            data = statusLinePlan.data
            changed = hookPlan.changed || statusLinePlan.changed
        }
        guard changed else {
            if provider == .claude { removeClaudeStatusLineScripts(fileManager: fileManager) }
            return
        }

        // Through a symlink, keeping the file's mode, and never over a
        // version Claude Code wrote since we read it.
        try ConfigurationFileWriter.replace(
            destination,
            with: data,
            expecting: existing,
            fileManager: fileManager
        )
        if provider == .claude { removeClaudeStatusLineScripts(fileManager: fileManager) }
    }

    private func configurationURL(for provider: AgentProvider) -> URL {
        switch provider {
        case .claude: claudeSettingsURL
        }
    }

    private func configurationData(
        for provider: AgentProvider,
        fileManager: FileManager
    ) throws -> Data? {
        let url = configurationURL(for: provider)
        return fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    /// Returns the backup it saved, if this was the first write.
    @discardableResult
    private func writeConfiguration(
        _ data: Data,
        to destination: URL,
        existingData: Data?,
        provider: AgentProvider,
        fileManager: FileManager
    ) throws -> URL? {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Checked before the one-time backup is taken, so the backup is
        // always a copy of the file as it really was.
        try ConfigurationFileWriter.requireUnchanged(destination, since: existingData, fileManager: fileManager)
        let backup = try preserveFirstBackup(existingData, destination: destination, fileManager: fileManager)
        try ConfigurationFileWriter.replace(
            destination,
            with: data,
            expecting: existingData,
            fileManager: fileManager
        )

        let written = try Data(contentsOf: destination)
        let isCurrent: Bool
        switch provider {
        case .claude:
            isCurrent = try ClaudeHookConfiguration.installationState(
                in: written,
                helperPath: stableHelperURL.path
            ) == .current
                && ClaudeStatusLineConfiguration.installationState(
                    in: written,
                    wrapperPath: claudeStatusLineWrapperURL.path
                ) == .current
        }
        guard isCurrent else { throw IntegrationError.validationFailed(provider.displayName) }
        return backup
    }

    private func preserveFirstBackup(
        _ existingData: Data?,
        destination: URL,
        fileManager: FileManager
    ) throws -> URL? {
        guard let existingData else { return nil }
        let backupURL = destination.appendingPathExtension("overhead-backup")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return nil }
        try existingData.write(to: backupURL, options: .atomic)
        let permissions = try fileManager.attributesOfItem(
            atPath: ConfigurationFileWriter.target(for: destination).path
        )[.posixPermissions] as? NSNumber
        try fileManager.setAttributes(
            [.posixPermissions: permissions ?? NSNumber(value: 0o600)],
            ofItemAtPath: backupURL.path
        )
        return backupURL
    }

    private func prepareClaudeStatusLineScripts(
        originalCommand: String?,
        fileManager: FileManager
    ) throws {
        let directory = claudeStatusLineWrapperURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let helper = shellQuoted(stableHelperURL.path)
        let cache = shellQuoted(claudeCapacityCacheURL.path)
        let delegate = shellQuoted(claudeStatusLineDelegateURL.path)
        let wrapper = """
        #!/bin/sh
        # Claude Overhead status-line bridge. Managed by Claude Overhead.
        input=$(cat)
        printf '%s' "$input" | \(helper) __capture-claude-capacity \(cache) >/dev/null 2>&1 || true
        # The marker stops a status line that (by mistake) points back at
        # this script from calling itself without end.
        if [ -z "$OVERHEAD_STATUS_LINE" ] && [ -x \(delegate) ]; then
          printf '%s' "$input" | OVERHEAD_STATUS_LINE=1 \(delegate)
        fi
        """ + "\n"
        try writeExecutable(wrapper, to: claudeStatusLineWrapperURL, fileManager: fileManager)

        if let originalCommand {
            let delegateScript = "#!/bin/sh\n# Original Claude Code status line preserved by Claude Overhead.\n\(originalCommand)\n"
            try writeExecutable(
                delegateScript,
                to: claudeStatusLineDelegateURL,
                fileManager: fileManager
            )
        } else if fileManager.fileExists(atPath: claudeStatusLineDelegateURL.path) {
            try fileManager.removeItem(at: claudeStatusLineDelegateURL)
        }
    }

    private func removeClaudeStatusLineScripts(fileManager: FileManager) {
        for url in [claudeStatusLineWrapperURL, claudeStatusLineDelegateURL]
            where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func writeExecutable(
        _ contents: String,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private enum IntegrationError: Error, LocalizedError {
        case helperUnavailable
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperUnavailable:
                "The packaged Claude Overhead helper is unavailable"
            case let .validationFailed(provider):
                "The \(provider) hook merge could not be validated"
            }
        }
    }
}
