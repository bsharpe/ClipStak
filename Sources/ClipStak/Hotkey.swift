import Carbon.HIToolbox
import Foundation

/// Shift-Command-V, using the ANSI V key position so the chord survives Dvorak and other layouts.
final class Hotkey {
    var onPress: () -> Void = {}
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func install() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCallback,
            1,
            &eventType,
            context,
            &handler
        )
        let id = EventHotKeyID(signature: OSType(0x5354414B), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }
}

private let hotkeyCallback: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue().onPress()
    return noErr
}
