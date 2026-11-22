import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts through Carbon's hot-key API. Unlike a
/// global key-event monitor, it needs no Accessibility permission, and a
/// combination another app already owns fails to register, which is how
/// cross-app conflicts are detected.
@MainActor
final class GlobalHotKeys {
    struct Binding {
        let id: UInt32
        let keyCode: UInt16
        let command: Bool
        let option: Bool
        let control: Bool
        let shift: Bool
        let action: @MainActor () -> Void
    }

    private var references: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4F56_4844 // "OVHD"

    /// Replaces every registered shortcut. Returns the ids that could not be
    /// registered because another app or the system already uses them.
    @discardableResult
    func replace(with bindings: [Binding]) -> Set<UInt32> {
        unregisterAll()
        installHandlerIfNeeded()
        var failed = Set<UInt32>()
        for binding in bindings {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                Self.carbonModifiers(binding),
                EventHotKeyID(signature: Self.signature, id: binding.id),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                references[binding.id] = reference
                actions[binding.id] = binding.action
            } else {
                failed.insert(binding.id)
            }
        }
        return failed
    }

    func unregisterAll() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
        actions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let hotKeys = Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue()
            let id = hotKeyID.id
            Task { @MainActor in hotKeys.actions[id]?() }
            return noErr
        }, 1, &eventType, context, &handler)
    }

    private static func carbonModifiers(_ binding: Binding) -> UInt32 {
        var modifiers: UInt32 = 0
        if binding.command { modifiers |= UInt32(cmdKey) }
        if binding.option { modifiers |= UInt32(optionKey) }
        if binding.control { modifiers |= UInt32(controlKey) }
        if binding.shift { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
