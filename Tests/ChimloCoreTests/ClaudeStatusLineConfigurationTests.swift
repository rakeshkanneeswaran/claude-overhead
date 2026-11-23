import Foundation
import Testing
@testable import ChimloCore

@Suite("Claude status-line configuration")
struct ClaudeStatusLineConfigurationTests {
    private let wrapperPath = "/Users/me/Library/Application Support/Overhead/bin/overhead-claude-statusline"

    @Test("Installation preserves an existing status line")
    func preservesExistingStatusLine() throws {
        let existing = Data(#"{"theme":"dark","statusLine":{"type":"command","command":"my-status","padding":2,"refreshInterval":300}}"#.utf8)
        let plan = try ClaudeStatusLineConfiguration.merging(
            existingData: existing,
            wrapperPath: wrapperPath
        )

        #expect(try ClaudeStatusLineConfiguration.installationState(
            in: plan.data,
            wrapperPath: wrapperPath
        ) == .current)
        #expect(try ClaudeStatusLineConfiguration.originalCommand(in: plan.data) == "my-status")
        let managedRoot = try #require(JSONSerialization.jsonObject(with: plan.data) as? [String: Any])
        let managedStatusLine = try #require(managedRoot["statusLine"] as? [String: Any])
        #expect(
            (managedStatusLine["refreshInterval"] as? NSNumber)?.intValue
                == ClaudeStatusLineConfiguration.refreshIntervalSeconds
        )

        let removed = try ClaudeStatusLineConfiguration.removing(existingData: plan.data, wrapperPath: wrapperPath)
        let root = try #require(JSONSerialization.jsonObject(with: removed.data) as? [String: Any])
        let restored = try #require(root["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == "my-status")
        #expect((restored["padding"] as? NSNumber)?.intValue == 2)
        #expect((restored["refreshInterval"] as? NSNumber)?.intValue == 300)
        #expect(root[ClaudeStatusLineConfiguration.managedKey] == nil)
    }

    @Test("A managed status line without periodic refresh needs repair")
    func staleManagedInstallationNeedsRepair() throws {
        let oldInstallation = Data(
            #"{"_overheadStatusLineManaged":true,"statusLine":{"type":"command","command":"/Users/me/Library/Application Support/Overhead/bin/overhead-claude-statusline"}}"#.utf8
        )

        #expect(try ClaudeStatusLineConfiguration.installationState(
            in: oldInstallation,
            wrapperPath: wrapperPath
        ) == .needsRepair)

        let repaired = try ClaudeStatusLineConfiguration.merging(
            existingData: oldInstallation,
            wrapperPath: wrapperPath
        )
        #expect(try ClaudeStatusLineConfiguration.installationState(
            in: repaired.data,
            wrapperPath: wrapperPath
        ) == .current)
    }

    @Test("Installation without a prior status line removes cleanly")
    func noPriorStatusLine() throws {
        let plan = try ClaudeStatusLineConfiguration.merging(
            existingData: Data(#"{"theme":"dark"}"#.utf8),
            wrapperPath: wrapperPath
        )
        let repeated = try ClaudeStatusLineConfiguration.merging(
            existingData: plan.data,
            wrapperPath: wrapperPath
        )
        #expect(!repeated.changed)

        let removed = try ClaudeStatusLineConfiguration.removing(existingData: plan.data, wrapperPath: wrapperPath)
        let root = try #require(JSONSerialization.jsonObject(with: removed.data) as? [String: Any])
        #expect(root["statusLine"] == nil)
        #expect(root["theme"] as? String == "dark")
    }

    @Test("An existing Claude connection gains the capacity bridge")
    func upgradesConnectedInstallation() throws {
        let helperPath = "/Users/me/Library/Application Support/Overhead/bin/overhead"
        let existing = Data(
            #"{"statusLine":{"type":"command","command":"/Users/me/.config/status-tools/statusline"}}"#.utf8
        )
        let connected = try ClaudeHookConfiguration.merging(
            existingData: existing,
            helperPath: helperPath
        ).data

        let plan = try #require(try ClaudeStatusLineConfiguration.upgradingConnectedInstallation(
            existingData: connected,
            helperPath: helperPath,
            wrapperPath: wrapperPath
        ))

        #expect(plan.changed)
        #expect(try ClaudeStatusLineConfiguration.installationState(
            in: plan.data,
            wrapperPath: wrapperPath
        ) == .current)
        #expect(
            try ClaudeStatusLineConfiguration.originalCommand(in: plan.data)
                == "/Users/me/.config/status-tools/statusline"
        )
    }

    @Test("An unconnected Claude installation is never upgraded automatically")
    func doesNotUpgradeDisconnectedInstallation() throws {
        let existing = Data(
            #"{"statusLine":{"type":"command","command":"my-status"}}"#.utf8
        )

        #expect(try ClaudeStatusLineConfiguration.upgradingConnectedInstallation(
            existingData: existing,
            helperPath: "/Users/me/Library/Application Support/Overhead/bin/overhead",
            wrapperPath: wrapperPath
        ) == nil)
    }

    @Test("Repair preserves a status line that replaced Claude Overhead's wrapper")
    func repairPreservesExternalReplacement() throws {
        let installed = try ClaudeStatusLineConfiguration.merging(
            existingData: Data(
                #"{"statusLine":{"type":"command","command":"old-status"}}"#.utf8
            ),
            wrapperPath: wrapperPath
        )
        var root = try #require(
            JSONSerialization.jsonObject(with: installed.data) as? [String: Any]
        )
        root["statusLine"] = [
            "type": "command",
            "command": "replacement-status",
        ]
        let replaced = try JSONSerialization.data(withJSONObject: root)

        let repaired = try ClaudeStatusLineConfiguration.merging(
            existingData: replaced,
            wrapperPath: wrapperPath
        )

        #expect(
            try ClaudeStatusLineConfiguration.originalCommand(in: repaired.data)
                == "replacement-status"
        )
    }

    // MARK: 1.0.7: the command must survive the shell

    @Test("The command is quoted, so a shell runs the wrapper despite the space in its path")
    func commandRunsThroughAShell() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead status \(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Application Support/it's here", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let wrapper = directory.appendingPathComponent("overhead-claude-statusline")
        try Data("#!/bin/sh\necho ran\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

        func run(_ command: String) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let quoted = try run(ClaudeStatusLineConfiguration.command(wrapperPath: wrapper.path))
        #expect(quoted.status == 0)
        #expect(quoted.output == "ran\n")
        // What 1.0.6 and earlier wrote: the shell splits at the space.
        let bare = try run(wrapper.path)
        #expect(bare.status != 0)
    }

    @Test("The bare path earlier versions wrote is repaired, not kept as the owner's original")
    func repairsTheUnquotedCommand() throws {
        let legacy = Data(
            #"{"_overheadStatusLineManaged":true,"statusLine":{"type":"command","command":"/Users/me/Library/Application Support/Overhead/bin/overhead-claude-statusline","refreshInterval":60}}"#.utf8
        )
        #expect(try ClaudeStatusLineConfiguration.installationState(in: legacy, wrapperPath: wrapperPath) == .needsRepair)

        let repaired = try ClaudeStatusLineConfiguration.merging(existingData: legacy, wrapperPath: wrapperPath)
        #expect(repaired.changed)
        #expect(try ClaudeStatusLineConfiguration.installationState(in: repaired.data, wrapperPath: wrapperPath) == .current)
        #expect(try ClaudeStatusLineConfiguration.originalCommand(in: repaired.data) == nil)
        let root = try #require(JSONSerialization.jsonObject(with: repaired.data) as? [String: Any])
        let statusLine = try #require(root["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == "'\(wrapperPath)'")
        #expect(root[ClaudeStatusLineConfiguration.originalKey] == nil)
    }

    @Test("Repairing the bare path keeps the owner's original status line")
    func repairKeepsTheOriginal() throws {
        let legacy = Data(
            #"{"_overheadStatusLineManaged":true,"_overheadOriginalStatusLine":{"type":"command","command":"my-status","padding":2},"statusLine":{"type":"command","command":"/Users/me/Library/Application Support/Overhead/bin/overhead-claude-statusline","padding":2,"refreshInterval":60}}"#.utf8
        )
        let repaired = try ClaudeStatusLineConfiguration.merging(existingData: legacy, wrapperPath: wrapperPath)
        #expect(try ClaudeStatusLineConfiguration.originalCommand(in: repaired.data) == "my-status")

        let removed = try ClaudeStatusLineConfiguration.removing(existingData: repaired.data, wrapperPath: wrapperPath)
        let root = try #require(JSONSerialization.jsonObject(with: removed.data) as? [String: Any])
        let restored = try #require(root["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == "my-status")
    }

    @Test("Our wrapper never becomes its own delegate")
    func wrapperIsNeverItsOwnOriginal() throws {
        // The wrapper without the bookkeeping, in either spelling.
        for command in [wrapperPath, "'\(wrapperPath)'"] {
            let existing = try JSONSerialization.data(withJSONObject: [
                "statusLine": ["type": "command", "command": command],
            ])
            let plan = try ClaudeStatusLineConfiguration.merging(existingData: existing, wrapperPath: wrapperPath)
            #expect(try ClaudeStatusLineConfiguration.originalCommand(in: plan.data) == nil)
        }
    }

    @Test("An original that is our own wrapper, saved by an older version's repair, is discarded")
    func selfReferencingOriginalIsDiscarded() throws {
        // What 1.0.6 leaves after "repairing" the quoted command: the bare
        // path in place, and the quoted wrapper saved as the original.
        let afterOldRepair = try JSONSerialization.data(withJSONObject: [
            "_overheadStatusLineManaged": true,
            "_overheadOriginalStatusLine": ["type": "command", "command": "'\(wrapperPath)'", "refreshInterval": 60],
            "statusLine": ["type": "command", "command": wrapperPath, "refreshInterval": 60],
        ])
        let repaired = try ClaudeStatusLineConfiguration.merging(existingData: afterOldRepair, wrapperPath: wrapperPath)
        #expect(try ClaudeStatusLineConfiguration.originalCommand(in: repaired.data) == nil)
        #expect(try ClaudeStatusLineConfiguration.installationState(in: repaired.data, wrapperPath: wrapperPath) == .current)

        // Disconnecting from that state does not "restore" the wrapper either.
        let removed = try ClaudeStatusLineConfiguration.removing(existingData: afterOldRepair, wrapperPath: wrapperPath)
        let root = try #require(JSONSerialization.jsonObject(with: removed.data) as? [String: Any])
        #expect(root["statusLine"] == nil)
    }

    // MARK: 1.0.7: Disconnect leaves the owner's own status line alone

    @Test("Disconnect keeps a status line the owner set while connected")
    func disconnectKeepsAStatusLineSetWhileConnected() throws {
        let installed = try ClaudeStatusLineConfiguration.merging(
            existingData: Data(#"{"theme":"dark"}"#.utf8),
            wrapperPath: wrapperPath
        )
        var root = try #require(JSONSerialization.jsonObject(with: installed.data) as? [String: Any])
        root["statusLine"] = ["type": "command", "command": "mine-now", "padding": 1]
        let edited = try JSONSerialization.data(withJSONObject: root)

        let removed = try ClaudeStatusLineConfiguration.removing(existingData: edited, wrapperPath: wrapperPath)
        let after = try #require(JSONSerialization.jsonObject(with: removed.data) as? [String: Any])
        let statusLine = try #require(after["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == "mine-now")
        #expect((statusLine["padding"] as? NSNumber)?.intValue == 1)
        #expect(after[ClaudeStatusLineConfiguration.managedKey] == nil)
        #expect(after[ClaudeStatusLineConfiguration.originalKey] == nil)
        #expect(after["theme"] as? String == "dark")
    }

    @Test("Disconnect does not bring back an older status line over the owner's newer one")
    func disconnectDoesNotRevertToAnOlderOriginal() throws {
        let installed = try ClaudeStatusLineConfiguration.merging(
            existingData: Data(#"{"statusLine":{"type":"command","command":"old-status"}}"#.utf8),
            wrapperPath: wrapperPath
        )
        var root = try #require(JSONSerialization.jsonObject(with: installed.data) as? [String: Any])
        root["statusLine"] = ["type": "command", "command": "newer-status"]
        let edited = try JSONSerialization.data(withJSONObject: root)

        let removed = try ClaudeStatusLineConfiguration.removing(existingData: edited, wrapperPath: wrapperPath)
        let after = try #require(JSONSerialization.jsonObject(with: removed.data) as? [String: Any])
        #expect((after["statusLine"] as? [String: Any])?["command"] as? String == "newer-status")
    }

    @Test("Disconnect does not resurrect a status line the owner removed")
    func disconnectDoesNotResurrectARemovedStatusLine() throws {
        let installed = try ClaudeStatusLineConfiguration.merging(
            existingData: Data(#"{"statusLine":{"type":"command","command":"old-status"}}"#.utf8),
            wrapperPath: wrapperPath
        )
        var root = try #require(JSONSerialization.jsonObject(with: installed.data) as? [String: Any])
        root.removeValue(forKey: "statusLine")
        let edited = try JSONSerialization.data(withJSONObject: root)

        let removed = try ClaudeStatusLineConfiguration.removing(existingData: edited, wrapperPath: wrapperPath)
        let after = try #require(JSONSerialization.jsonObject(with: removed.data) as? [String: Any])
        #expect(after["statusLine"] == nil)
        #expect(after[ClaudeStatusLineConfiguration.originalKey] == nil)
    }

    // MARK: 1.0.7: no rewrite when nothing changed

    @Test("A current installation in Claude Code's own formatting is left untouched")
    func reformattedButCurrentIsUnchanged() throws {
        let installed = try ClaudeStatusLineConfiguration.merging(
            existingData: Data(#"{"theme":"dark","ratio":0.1,"url":"https://example.com/a"}"#.utf8),
            wrapperPath: wrapperPath
        )
        // The same values the way another writer would lay them out: other
        // key order, other indentation, no trailing newline.
        let root = try #require(JSONSerialization.jsonObject(with: installed.data) as? [String: Any])
        let reformatted = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        #expect(reformatted != installed.data)

        let again = try ClaudeStatusLineConfiguration.merging(existingData: reformatted, wrapperPath: wrapperPath)
        #expect(!again.changed)
        #expect(again.data == reformatted)
    }
}
