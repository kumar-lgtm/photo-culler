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

public final class ShortcutManager: @unchecked Sendable {
    public let actionPublisher = PassthroughSubject<ShortcutAction, Never>()
    private var monitor: Any?

    @MainActor
    public init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let r = NSApp.keyWindow?.firstResponder, r is NSText {
                return event
            }
            if let action = self.action(for: event) {
                self.actionPublisher.send(action)
                return nil
            }
            return event
        }
    }

    private func action(for event: NSEvent) -> ShortcutAction? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)
        let shift = mods.contains(.shift)
        let chars = event.charactersIgnoringModifiers ?? ""

        switch event.keyCode {
        case 123: return .navigatePrevious(shift: shift, command: cmd)
        case 124: return .navigateNext(shift: shift, command: cmd)
        case 125: return .navigateDown(shift: shift, command: cmd)
        case 126: return .navigateUp(shift: shift, command: cmd)
        case 49:  return .navigateNext(shift: false, command: false)
        case 53:  return .clearSelection
        case 48:  return .cycleComparePane(forward: !shift)  // Tab / Shift+Tab — cycle compare panes
        default: break
        }

        if cmd, let digit = Int(chars), (1...8).contains(digit) {
            return .setLabel(digit)
        }
        if cmd && chars.lowercased() == "o" { return .openFolder }
        if cmd && chars.lowercased() == "r" { return .openRenameModal }
        if cmd && chars == "0" { return .toggleSidebar }
        if cmd && chars.lowercased() == "i" { return .toggleInspector }

        guard !cmd else { return nil }

        if let digit = Int(chars) {
            if digit == 0 { return .clearRating }
            if (1...5).contains(digit) { return .setRating(digit) }
        }
        if chars == "`" { return .clearLabel }

        switch chars.lowercased() {
        case "w": return .panUp
        case "s": return .panDown
        case "a": return .panLeft
        case "d": return .panRight
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
