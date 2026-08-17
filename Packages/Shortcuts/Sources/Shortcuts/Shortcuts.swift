import AppKit
import Combine

public enum ShortcutAction: Equatable, Sendable {
    case navigateNext(shift: Bool, command: Bool)
    case navigatePrevious(shift: Bool, command: Bool)
    case navigateUp(shift: Bool, command: Bool)
    case navigateDown(shift: Bool, command: Bool)
    case addToSelection
    case clearSelection
    case setRating(Int)
    case clearRating
    case setLabel(Int)
    case clearLabel
    case viewModeLoupe
    case viewModeGrid
    case viewModeCompare
    case toggleSidebar
    case toggleInspector
    case openFolder
    case openRenameModal
    case toggleFaceZoom
    case panUp
    case panDown
    case panLeft
    case panRight
    case cycleComparePane(forward: Bool)
    case setFlag(pick: Bool)   // pick == true → keeper, false → reject
    case clearFlag             // unflag
    case toggleActualSize      // 100% / fit focus check
}

/// Physical key positions, so shortcuts work on any keyboard layout.
///
/// `charactersIgnoringModifiers` returns what the key *prints*, which is layout-dependent:
/// on AZERTY the unshifted number row gives `&é"'(`, so `Int(chars)` failed and ratings 1–5
/// simply didn't work. Key codes describe the position on the board and are identical across
/// layouts, which is also what makes WASD panning land on the same four physical keys.
private enum KeyCode {
    // Digit row, in printed order 0–9.
    static let digits: [UInt16: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9
    ]
    static let w: UInt16 = 13
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2

    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    static let grave: UInt16 = 50
}

public final class ShortcutManager: @unchecked Sendable {
    public let actionPublisher = PassthroughSubject<ShortcutAction, Never>()
    private var monitor: Any?

    @MainActor
    public init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard Self.shouldIntercept() else { return event }
            if let action = self.action(for: event) {
                self.actionPublisher.send(action)
                return nil
            }
            return event
        }
    }

    deinit {
        guard let monitor else { return }
        // `removeMonitor` is main-thread-only, and deinit can land anywhere.
        if Thread.isMainThread {
            NSEvent.removeMonitor(monitor)
        } else {
            DispatchQueue.main.async { NSEvent.removeMonitor(monitor) }
        }
    }

    /// Culling keys only apply to the main window with no text field focused.
    ///
    /// The monitor consumes the events it recognizes, so intercepting while a sheet is up
    /// meant Escape (mapped to "clear selection") stopped dismissing sheets, and single
    /// letters like P/X/C were swallowed before reaching buttons in the Rename, Ingest and
    /// Metadata modals.
    @MainActor
    private static func shouldIntercept() -> Bool {
        if NSApp.modalWindow != nil { return false }

        guard let window = NSApp.keyWindow else { return false }
        if window.isSheet { return false }
        if window.attachedSheet != nil { return false }

        if let responder = window.firstResponder {
            if responder is NSText { return false }
            // SwiftUI text entry does not always vend an NSText field editor.
            if responder.isKind(of: NSTextView.self) { return false }
            if window.fieldEditor(false, for: nil) === responder { return false }
        }
        return true
    }

    private func action(for event: NSEvent) -> ShortcutAction? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)
        let shift = mods.contains(.shift)
        let option = mods.contains(.option)
        let control = mods.contains(.control)
        let chars = event.charactersIgnoringModifiers ?? ""

        // Modifier combinations we deliberately don't own.
        if option || control { return nil }

        switch event.keyCode {
        case KeyCode.leftArrow:  return .navigatePrevious(shift: shift, command: cmd)
        case KeyCode.rightArrow: return .navigateNext(shift: shift, command: cmd)
        case KeyCode.downArrow:  return .navigateDown(shift: shift, command: cmd)
        case KeyCode.upArrow:    return .navigateUp(shift: shift, command: cmd)
        case KeyCode.space:      return .navigateNext(shift: false, command: false)
        case KeyCode.escape:     return .clearSelection
        case KeyCode.tab:        return .cycleComparePane(forward: !shift)
        default: break
        }

        let digit = KeyCode.digits[event.keyCode]

        if cmd {
            if let digit {
                if digit == 0 { return .toggleSidebar }
                if (1...8).contains(digit) { return .setLabel(digit) }
                return nil
            }
            switch chars.lowercased() {
            case "o": return .openFolder
            case "r": return .openRenameModal
            case "i": return .toggleInspector
            default:  return nil
            }
        }

        if let digit {
            if digit == 0 { return .clearRating }
            if (1...5).contains(digit) { return .setRating(digit) }
            return nil
        }

        if event.keyCode == KeyCode.grave { return .clearLabel }

        // Spatial pan keys go by position; the rest stay mnemonic.
        switch event.keyCode {
        case KeyCode.w: return .panUp
        case KeyCode.s: return .panDown
        case KeyCode.a: return .panLeft
        case KeyCode.d: return .panRight
        default: break
        }

        switch chars.lowercased() {
        case "e": return .viewModeLoupe
        case "g": return .viewModeGrid
        case "c": return shift ? .addToSelection : .viewModeCompare
        case "z": return .toggleFaceZoom
        case "p": return .setFlag(pick: true)    // pick / keeper
        case "x": return .setFlag(pick: false)   // reject
        case "u": return .clearFlag              // unflag
        case "f": return .toggleActualSize       // 100% / fit
        default: return nil
        }
    }
}
