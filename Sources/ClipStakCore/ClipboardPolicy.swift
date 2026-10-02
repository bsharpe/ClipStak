public enum ClipboardPolicy {
    private static let excludedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    public static func shouldCapture(types: [String]) -> Bool {
        excludedTypes.isDisjoint(with: types)
    }

    /// The bezel holds the key window, so the frontmost app at release is the wrong
    /// signal. Flycut hides itself and posts Command-V. Skip that key only when
    /// the clip we placed has been replaced.
    public static func canCompletePaste(
        expectedChangeCount: Int,
        currentChangeCount: Int,
        clipboardStillHoldsClip: Bool
    ) -> Bool {
        clipboardStillHoldsClip || expectedChangeCount == currentChangeCount
    }
}

public struct HeldModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = HeldModifiers(rawValue: 1 << 0)
    public static let shift = HeldModifiers(rawValue: 1 << 1)
    public static let option = HeldModifiers(rawValue: 1 << 2)
    public static let control = HeldModifiers(rawValue: 1 << 3)
}

public enum ReleasePaste {
    /// Paste when the hotkey chord goes up. `reported` is the flagsChanged event.
    /// Arrow keys can report an empty chord while Shift and Command are still down.
    public static func shouldPaste(
        reported: HeldModifiers,
        hardware: HeldModifiers,
        bezelVisible: Bool,
        suppressPaste: Bool,
        sticky: Bool
    ) -> Bool {
        guard bezelVisible, !suppressPaste, !sticky else { return false }
        return reported.isEmpty && hardware.isEmpty
    }
}

public enum PasteReadiness {
    public enum Action: Equatable { case wait, paste, cancel }

    /// Check after hiding the bezel, not while it is receiving navigation keys.
    public static func action(
        targetPID: Int32,
        frontmostPID: Int32?,
        clipStakPID: Int32,
        bezelIsKey: Bool,
        modifiers: HeldModifiers
    ) -> Action {
        guard let frontmostPID else { return .wait }
        guard frontmostPID == targetPID || frontmostPID == clipStakPID else { return .cancel }
        guard frontmostPID == targetPID, !bezelIsKey, modifiers.isEmpty else { return .wait }
        return .paste
    }
}
