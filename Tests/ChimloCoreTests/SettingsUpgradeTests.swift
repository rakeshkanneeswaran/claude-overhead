import Foundation
import Testing
@testable import ChimloCore

/// An upgrade must never reset what a customer chose. This is a settings
/// file in exactly the shape version 1.0.8 saved it (every key 1.0.8 wrote,
/// with made-up values that differ from the defaults), read by this version.
@Suite("Settings: upgrading from 1.0.8")
struct SettingsUpgradeTests {
    private static let saved = Data(#"""
    {
      "accent": "claude",
      "animationIntensity": "full",
      "appearance": "system",
      "askAboutUnattendedRuns": true,
      "contextAttentionThreshold": 0.7,
      "contextCriticalThreshold": 0.9,
      "dailyRecapEnabled": true,
      "density": "compact",
      "focus": {
        "hideActivityLabels": true,
        "isOn": false,
        "muteSounds": true,
        "reduceAnimations": true,
        "scheduleEnabled": false,
        "suppressInformational": false
      },
      "github": {
        "allowMerging": true,
        "defaultView": "overview",
        "density": "compact",
        "enabled": true,
        "fastRefreshWhileRunning": true,
        "groupNotifications": true,
        "lastView": "overview",
        "mergeMethods": {
          "1001": "squash",
          "1002": "merge"
        },
        "monitorActions": true,
        "notchModeEnabled": true,
        "refreshSeconds": 30,
        "repositoryAlerts": {
          "1001": "all"
        },
        "reviewNotifications": true,
        "selection": {
          "excludedIDs": [
            1003
          ],
          "focusedID": 1001,
          "followClaudeRepositories": true,
          "repositories": [
            {
              "id": 1001,
              "isPrivate": true,
              "name": "project-one",
              "owner": "example-org"
            },
            {
              "id": 1002,
              "isPrivate": false,
              "name": "project-two",
              "owner": "example-org"
            }
          ]
        },
        "showAccount": true,
        "showDetailedMetadata": true,
        "showInClosedNotch": true,
        "showNotchButton": true,
        "showPullRequestIndicator": true,
        "showRepositoryInfo": true,
        "showRunningIndicator": true,
        "trackPullRequests": true
      },
      "glowIntensity": 0.4,
      "groupByProject": true,
      "historyRetentionDays": 30,
      "launchAtLogin": true,
      "layout": "expanded",
      "notchLocked": true,
      "notifications": {
        "groupCompletions": true,
        "perEvent": {},
        "quietHoursEnabled": false,
        "soundChoice": "chime",
        "soundVolume": 0.5,
        "soundsEnabled": true
      },
      "preferredDisplay": "notchedDisplay",
      "sessionSort": "attentionFirst",
      "shortcuts": {
        "focusTerminal": {
          "keyCode": 17,
          "modifiers": 6
        },
        "nextSession": {
          "keyCode": 30,
          "modifiers": 6
        },
        "openHistory": {
          "keyCode": 4,
          "modifiers": 6
        },
        "openSettings": {
          "keyCode": 43,
          "modifiers": 6
        },
        "previousSession": {
          "keyCode": 33,
          "modifiers": 6
        },
        "showSessions": {
          "keyCode": 1,
          "modifiers": 6
        },
        "toggleFocusMode": {
          "keyCode": 3,
          "modifiers": 6
        },
        "toggleGitHubMode": {
          "keyCode": 5,
          "modifiers": 6
        },
        "togglePanel": {
          "keyCode": 31,
          "modifiers": 6
        }
      },
      "shortcutsEnabled": true,
      "showAgents": false,
      "showCacheMetrics": true,
      "showClosedNotchActivity": true,
      "showResetCountdowns": true,
      "storeConversationPreviews": true,
      "theme": "graphite",
      "usageWarningThreshold": 0.65,
      "version": 1
    }
    """#.utf8)

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every value in `old` is still there, unchanged, in `new`. `new` may
    /// hold more.
    private static func missing(from new: Any?, comparedTo old: Any, at path: String) -> [String] {
        if let oldObject = old as? [String: Any] {
            guard let newObject = new as? [String: Any] else { return ["\(path): no longer an object"] }
            return oldObject.keys.sorted().flatMap { key in
                missing(from: newObject[key], comparedTo: oldObject[key] as Any, at: path.isEmpty ? key : "\(path).\(key)")
            }
        }
        if let oldArray = old as? [Any] {
            guard let newArray = new as? [Any], newArray.count == oldArray.count else { return ["\(path): array changed"] }
            return oldArray.indices.flatMap { missing(from: newArray[$0], comparedTo: oldArray[$0], at: "\(path)[\($0)]") }
        }
        guard let new else { return ["\(path): dropped"] }
        return (new as? NSObject)?.isEqual(old) == true ? [] : ["\(path): \(old) became \(new)"]
    }

    @Test("Every setting a 1.0.8 customer chose is read as they left it")
    func readsEverySetting() throws {
        let settings = try JSONDecoder().decode(OverheadSettings.self, from: Self.saved)
        #expect(settings.theme.rawValue == "graphite")
        #expect(settings.layout.rawValue == "expanded")
        #expect(settings.density.rawValue == "compact")
        #expect(settings.notchLocked)
        #expect(settings.askAboutUnattendedRuns)
        #expect(settings.launchAtLogin)
        #expect(settings.groupByProject)
        #expect(!settings.showAgents)
        #expect(settings.dailyRecapEnabled)
        #expect(settings.historyRetentionDays == 30)
        #expect(settings.glowIntensity == 0.4)
        #expect(settings.usageWarningThreshold == 0.65)
        #expect(settings.github.selection.repositories.count == 2)
        #expect(settings.github.selection.focusedID == 1001)
        #expect(settings.github.mergeMethods.count == 2)
        #expect(settings.shortcuts.count == 9)
        // Reading it changes nothing, so the app has nothing to rewrite.
        #expect(settings.normalized() == settings)
    }

    @Test("The new settings start off, so an upgraded app looks and behaves as before")
    func newSettingsStartOff() throws {
        let settings = try JSONDecoder().decode(OverheadSettings.self, from: Self.saved)
        #expect(!settings.assignCharactersAutomatically)
        #expect(settings.projectCharacterPools.isEmpty)
    }

    @Test("Saving it again keeps every key and value 1.0.8 wrote, so going back to 1.0.8 loses nothing")
    func savingKeepsEverything() throws {
        let settings = try JSONDecoder().decode(OverheadSettings.self, from: Self.saved)
        let resaved = try Self.object(JSONEncoder().encode(settings))
        let lost = Self.missing(from: resaved, comparedTo: try Self.object(Self.saved), at: "")
        #expect(lost.isEmpty, "\(lost)")
        // And what this version adds is only added.
        #expect(resaved["assignCharactersAutomatically"] as? Bool == false)
        #expect((resaved["projectCharacterPools"] as? [String: Any])?.isEmpty == true)
    }

    @Test("A customer's own choices for the new settings survive a save and load")
    func newSettingsRoundTrip() throws {
        var settings = try JSONDecoder().decode(OverheadSettings.self, from: Self.saved)
        settings.assignCharactersAutomatically = true
        settings.projectCharacterPools = ["/work/app": ["fantasy.slime"]]
        let loaded = try JSONDecoder().decode(OverheadSettings.self, from: JSONEncoder().encode(settings))
        #expect(loaded == settings)
        // Nothing else moved.
        #expect(loaded.theme.rawValue == "graphite")
        #expect(loaded.github.selection.focusedID == 1001)
    }
}
