public enum ClipboardPolicy {
    private static let excludedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    public static func shouldCapture(types: [String]) -> Bool {
        excludedTypes.isDisjoint(with: types)
    }

    public static func canCompletePaste(
        expectedChangeCount: Int,
        currentChangeCount: Int,
        targetPID: Int32?,
        frontmostPID: Int32?
    ) -> Bool {
        guard let targetPID, let frontmostPID else { return false }
        return expectedChangeCount == currentChangeCount && targetPID == frontmostPID
    }
}
