import Carbon.HIToolbox

/// A system-wide hotkey, registered through Carbon so it needs no extra permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec,
                                  Unmanaged.passUnretained(self).toOpaque(), &handlerRef) == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4D4F_5553), id: 1)  // "MOUS"
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                  GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
