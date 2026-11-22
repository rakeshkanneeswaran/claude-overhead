import ChimloCore
import Foundation
import Testing

@Suite("Per-session sound")
struct SessionSoundTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Every session starts silent")
    func silentByDefault() {
        var gate = SessionSoundGate()
        let preferences = SessionSoundPreferences()
        for kind in OverheadEventKind.allCases where kind.isSessionSound {
            let allowed1 = gate.allows(kind, sessionID: "s1", policyAllows: true, preferences: preferences, now: now)
            #expect(!allowed1, "\(kind)")
        }
        // Out of the box the policy itself makes nothing but a session's own
        // events audible, and those still need the session's toggle.
        let defaults = NotificationPreferences()
        for kind in OverheadEventKind.allCases where !kind.isSessionSound {
            let sound = defaults.preference(for: kind).sound
            #expect(!sound || kind.isSessionSound, "\(kind) sounds by default")
        }
    }

    @Test("Turning one session on never turns on another")
    func independentSessions() {
        var preferences = SessionSoundPreferences()
        preferences.toggle("s1", at: now)
        #expect(preferences.isEnabled("s1"))
        #expect(!preferences.isEnabled("s2"))

        var gate = SessionSoundGate()
        let allowed2 = gate.allows(.sessionCompleted, sessionID: "s1", policyAllows: true, preferences: preferences, now: now)
        #expect(allowed2)
        let allowed3 = gate.allows(.sessionCompleted, sessionID: "s2", policyAllows: true, preferences: preferences, now: now)
        #expect(!allowed3)

        preferences.toggle("s1", at: now)
        #expect(!preferences.isEnabled("s1"))
    }

    @Test("A session's toggle covers its completion, failure, permission, question and context sounds")
    func toggleCoversSessionEvents() {
        var preferences = SessionSoundPreferences()
        preferences.setEnabled(true, for: "s1", at: now)
        for (offset, kind) in [OverheadEventKind.sessionCompleted, .sessionFailed, .permissionRequested, .questionAsked, .contextWarning].enumerated() {
            var gate = SessionSoundGate()
            let allowed4 = gate.allows(kind, sessionID: "s1", policyAllows: true, preferences: preferences, now: now + Double(offset))
            #expect(allowed4, "\(kind)")
        }
    }

    @Test("The policy still has the last word: mute, quiet hours or a per-event choice silence it")
    func policyStillApplies() {
        var preferences = SessionSoundPreferences()
        preferences.setEnabled(true, for: "s1", at: now)
        var gate = SessionSoundGate()
        let allowed5 = gate.allows(.sessionCompleted, sessionID: "s1", policyAllows: false, preferences: preferences, now: now)
        #expect(!allowed5)
        // Events that belong to no session follow the policy alone.
        let allowed6 = gate.allows(.usageWarning, sessionID: nil, policyAllows: true, preferences: preferences, now: now)
        #expect(allowed6)
        let allowed7 = gate.allows(.githubCIFailed, sessionID: nil, policyAllows: true, preferences: preferences, now: now)
        #expect(allowed7)
        // A session event without a session can't be attributed, so it is silent.
        let allowed8 = gate.allows(.sessionCompleted, sessionID: nil, policyAllows: true, preferences: preferences, now: now)
        #expect(!allowed8)
    }

    @Test("A burst of events for one session makes one sound; other sessions are unaffected")
    func noDuplicateSounds() {
        var preferences = SessionSoundPreferences()
        preferences.setEnabled(true, for: "s1", at: now)
        preferences.setEnabled(true, for: "s2", at: now)
        var gate = SessionSoundGate()
        let allowed9 = gate.allows(.permissionRequested, sessionID: "s1", policyAllows: true, preferences: preferences, now: now)
        #expect(allowed9)
        let allowed10 = gate.allows(.questionAsked, sessionID: "s1", policyAllows: true, preferences: preferences, now: now + 0.5)
        #expect(!allowed10)
        let allowed11 = gate.allows(.sessionCompleted, sessionID: "s1", policyAllows: true, preferences: preferences, now: now + 1.9)
        #expect(!allowed11)
        let allowed12 = gate.allows(.sessionCompleted, sessionID: "s2", policyAllows: true, preferences: preferences, now: now + 0.5)
        #expect(allowed12)
        let allowed13 = gate.allows(.sessionCompleted, sessionID: "s1", policyAllows: true, preferences: preferences, now: now + 2)
        #expect(allowed13)
    }

    @Test("A session's entry lives as long as the session")
    func lifetime() throws {
        var preferences = SessionSoundPreferences()
        preferences.setEnabled(true, for: "s1", at: now)
        preferences.setEnabled(true, for: "s2", at: now)
        // Seen again: its week starts over.
        preferences.touch(["s1"], at: now + 6 * 86_400)
        preferences.prune(now: now + 8 * 86_400)
        #expect(preferences.isEnabled("s1"))
        #expect(!preferences.isEnabled("s2"))
        // The session ended.
        preferences.forget("s1")
        #expect(!preferences.isEnabled("s1"))
        // Touching never turns a silent session on.
        preferences.touch(["s3"], at: now)
        #expect(!preferences.isEnabled("s3"))
        preferences.setEnabled(true, for: "", at: now)
        #expect(preferences.enabledSessions.isEmpty)
    }

    @Test("Per-session choices survive a restart")
    func persistence() throws {
        var preferences = SessionSoundPreferences()
        preferences.setEnabled(true, for: "s1", at: now)
        let data = try JSONEncoder().encode(preferences)
        let restored = try JSONDecoder().decode(SessionSoundPreferences.self, from: data)
        #expect(restored == preferences)
        #expect(restored.isEnabled("s1") && !restored.isEnabled("s2"))
    }

    @Test("The chosen sound and volume persist, clamped to a gentle range")
    func soundChoiceAndVolume() throws {
        let defaults = NotificationPreferences()
        #expect(defaults.soundChoice == .chime)
        #expect(defaults.soundVolume == 0.5)
        var settings = OverheadSettings()
        settings.notifications.soundChoice = .glass
        settings.notifications.soundVolume = 0.2
        let decoded = try JSONDecoder().decode(OverheadSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.notifications.soundChoice == .glass)
        #expect(decoded.notifications.soundVolume == 0.2)

        #expect(NotificationSoundVolume.clamped(5) == 1)
        #expect(NotificationSoundVolume.clamped(0) == 0.05)
        #expect(NotificationSoundVolume.clamped(.nan) == 0.5)
        let loud = Data(#"{"soundVolume": 40, "soundChoice": "airhorn"}"#.utf8)
        let odd = try JSONDecoder().decode(NotificationPreferences.self, from: loud)
        #expect(odd.soundVolume == 1)
        #expect(odd.soundChoice == .chime)
        // Every choice is either the built-in chime or a real system sound name.
        for choice in NotificationSoundChoice.allCases {
            #expect(choice == .chime ? choice.systemSoundName == nil : choice.systemSoundName != nil)
        }
    }
}

@Suite("Lock Mode")
struct NotchLockTests {
    @Test("Locked, nothing opens the notch by itself; the owner still can")
    func lockedBlocksAutomaticOpens() {
        for trigger in [NotchLockPolicy.Trigger.ownerRequest, .sessionFailure, .updateNotice, .hover] {
            #expect(!NotchLockPolicy.opens(trigger, isLocked: true), "\(trigger)")
        }
        #expect(NotchLockPolicy.opens(.ownerAction, isLocked: true))
    }

    @Test("Unlocked, the notch behaves as before")
    func unlockedRestoresBehaviour() {
        for trigger in NotchLockPolicy.Trigger.allCases {
            #expect(NotchLockPolicy.opens(trigger, isLocked: false), "\(trigger)")
        }
        // A click-to-open layout (Focus) still does not open on hover.
        #expect(!NotchLockPolicy.opens(.hover, isLocked: false, layoutExpandsOnHover: false))
    }

    @Test("Unlocking with a request waiting shows it")
    func unlockShowsWaitingRequest() {
        #expect(NotchLockPolicy.opensOnUnlock(hasPendingOwnerRequest: true))
        #expect(!NotchLockPolicy.opensOnUnlock(hasPendingOwnerRequest: false))
    }

    @Test("Lock Mode is off by default and survives a restart")
    func persistence() throws {
        #expect(!OverheadSettings().notchLocked)
        var settings = OverheadSettings()
        settings.notchLocked = true
        let decoded = try JSONDecoder().decode(OverheadSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.notchLocked)
        let sparse = try JSONDecoder().decode(OverheadSettings.self, from: Data("{}".utf8))
        #expect(!sparse.notchLocked)
    }

    @Test("Locking never touches what Claude is waiting for")
    func requestsSurviveLock() {
        // Lock Mode is a presentation policy only: a waiting request is still
        // an owner interaction (shown in the notch, never hidden), and its only
        // endings stay the owner's answer, Claude Code giving up, or expiry.
        #expect(OverheadEventKind.permissionRequested.blocksClaude)
        #expect(OverheadEventKind.questionAsked.blocksClaude)
        #expect(!OwnerInteractionLifetime.endsPendingRequests(.activity))
    }
}
