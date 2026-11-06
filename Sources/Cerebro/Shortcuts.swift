import Carbon.HIToolbox
import CoreGraphics

/// A keystroke Cerebro can send when a head direction fires.
struct ShortcutAction {
    let id: String
    let title: String
    /// Shown next to the title in menus, e.g. "⌃←".
    let keys: String
    let keyCode: Int?
    let flags: CGEventFlags

    var menuTitle: String { keys.isEmpty ? title : "\(title) (\(keys))" }

    static let all = [
        ShortcutAction(id: "none", title: "Nothing", keys: "", keyCode: nil, flags: []),
        ShortcutAction(id: "desktopLeft", title: "Previous Desktop", keys: "⌃←", keyCode: kVK_LeftArrow, flags: .maskControl),
        ShortcutAction(id: "desktopRight", title: "Next Desktop", keys: "⌃→", keyCode: kVK_RightArrow, flags: .maskControl),
        ShortcutAction(id: "missionControl", title: "Mission Control", keys: "⌃↑", keyCode: kVK_UpArrow, flags: .maskControl),
        ShortcutAction(id: "screenshot", title: "Screenshot", keys: "⇧⌘3", keyCode: kVK_ANSI_3, flags: [.maskShift, .maskCommand]),
        ShortcutAction(id: "return", title: "Approve", keys: "Return", keyCode: kVK_Return, flags: []),
        ShortcutAction(id: "escape", title: "Cancel", keys: "Esc", keyCode: kVK_Escape, flags: []),
    ]

    static let defaults: [Direction: String] = [
        .left: "desktopLeft", .right: "desktopRight", .up: "missionControl", .down: "screenshot",
    ]

    static func named(_ id: String?) -> ShortcutAction? {
        all.first { $0.id == id }
    }

    private static let arrowKeys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]

    func perform() {
        guard let keyCode else { return }
        var flags = flags
        // Real arrow-key events carry these two bits, so include them to match.
        if Self.arrowKeys.contains(keyCode) { flags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
