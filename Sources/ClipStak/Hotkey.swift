import Carbon.HIToolbox
import Foundation

/// Shift-Command-V for the bezel and Control-Command-V for the contact sheet, using the
/// ANSI V key position so the chords survive Dvorak and other layouts.
final class Hotkey {
    enum Chord: UInt32 {
        case bezel = 1
        case sheet = 2
    }

    var onPress: (Chord) -> Void = { _ in }
    private var hotKeys: [EventHotKeyRef?] = []
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
        for (chord, modifiers) in [(Chord.bezel, cmdKey | shiftKey), (Chord.sheet, cmdKey | controlKey)] {
            var hotKey: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5354414B), id: chord.rawValue)
            RegisterEventHotKey(
                UInt32(kVK_ANSI_V),
                UInt32(modifiers),
                id,
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            hotKeys.append(hotKey)
        }
    }
}

private let hotkeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr, let chord = Hotkey.Chord(rawValue: id.id) else { return noErr }
    Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue().onPress(chord)
    return noErr
}
