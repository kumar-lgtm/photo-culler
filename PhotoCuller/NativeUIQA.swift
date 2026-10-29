#if DEBUG
import AppKit
import SwiftUI
import Foundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Catalog
import Sidecar
import UI

/// Repeatable tests of this app's own rendered windows. Debug builds only; no global
/// keyboard injection, accessibility permissions or external desktop automation needed.
/// Launch a debug bundle with `--ui-qa-output /path/to/evidence`.
@MainActor
enum NativeUIQA {
    private static var started = false
    private static var failures: [String] = []
    private static var passed = 0

    static func run(workspace: WorkspaceViewModel, output: URL) async {
        guard !started else { return }
        started = true
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("pc-native-ui-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let empty = fixture.appendingPathComponent("empty")
            let shoot = fixture.appendingPathComponent("shoot")
            for folder in [empty, shoot] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            for index in 1...3 {
                let name = String(format: "PHOTO_%02d", index) + (index == 3 ? "_a-long-camera-filename-for-overflow-coverage" : "")
                try writeJPEG(shoot.appendingPathComponent(name + ".jpg"), seed: index)
                try SidecarManager().write(PhotoMetadata(rating: index, label: index == 2 ? .blue : .none),
                                           to: shoot.appendingPathComponent(name + ".xmp"))
            }
            guard let window = NSApp.windows.first(where: { $0.contentView != nil && !$0.isSheet }) else {
                throw NSError(domain: "NativeUIQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "App window did not appear"])
            }
            window.setContentSize(NSSize(width: 1440, height: 900))
            workspace.isBeigeMode = false
            await settle()
            try await capture(window, "01-welcome-standard", to: output)
            check(hasLabel(window, "Loupe"), "Loupe view mode has an accessible text name")
            check(hasLabel(window, "Grid"), "Grid view mode has an accessible text name")

            await workspace.openFolder(empty)
            await settle()
            try await capture(window, "02-empty-folder", to: output)
            check(hasLabel(window, "Choose another folder…"), "empty folder has a recovery action")
            workspace.isScanning = true
            await settle()
            try await capture(window, "02b-loading", to: output)
            workspace.isScanning = false

            await workspace.openFolder(shoot)
            await settle()
            workspace.filterSettings.minRating = 5
            await settle()
            try await capture(window, "03-filtered-empty", to: output)
            check(hasLabel(window, "Clear filters"), "filtered empty has a clear-filters action")
            if let clear = find(window, label: "Clear filters") { _ = clear.accessibilityPerformPress() }
            await settle()
            check(workspace.photos.count == 3, "native filter recovery restores the shoot")

            workspace.viewMode = .grid
            workspace.autoAdvance = false
            await settle()
            try await capture(window, "04-grid-standard", to: output)
            let longNames = elements(window).filter { $0.accessibilityLabel()?.contains("a-long-camera-filename") == true }
            check(longNames.count >= 2 && longNames.allSatisfy { $0.frame().width > 0 && $0.frame().width <= 250 }, "long filenames do not stretch grid or filmstrip cards")
            check(find(window, label: "PHOTO_02.jpg") != nil, "photo thumbnail is an accessible control")
            if let photo = find(window, label: "PHOTO_02.jpg") { _ = photo.accessibilityPerformPress() }
            await settle()
            check(workspace.currentPhoto?.url.lastPathComponent == "PHOTO_02.jpg", "native thumbnail selection updates photo focus")
            check(workspace.currentMetadata.rating == 2, "native thumbnail selection refreshes inspector metadata")
            check(find(window, label: "Rate photo 5 stars") != nil, "rating buttons are individually accessible")
            check(find(window, label: "Photo color label") != nil, "photo color picker is accessible by name")
            check(find(window, label: "Filter by Red") != nil, "color filters are individually accessible")
            if let rate = find(window, label: "Rate photo 5 stars") { _ = rate.accessibilityPerformPress() }
            await settle()
            await workspace.flushPendingWrites()
            check(workspace.currentMetadata.rating == 5, "rating button changes the focused photo")

            workspace.isBeigeMode = true
            for _ in 0..<30 where workspace.activeHUD != nil { try? await Task.sleep(for: .milliseconds(100)) }
            window.setContentSize(NSSize(width: 1000, height: 700))
            await settle()
            try await capture(window, "05-grid-beige-minimum-window", to: output)
            if let disclosure = elements(window).first(where: { $0.accessibilityRole() == .disclosureTriangle }) {
                _ = disclosure.accessibilityPerformPress()
                await settle()
                try await capture(window, "05b-shortcuts-expanded", to: output)
                check(elements(window).contains { String(describing: $0.accessibilityValue() ?? $0.accessibilityLabel() ?? "").contains("Cycle compare pane") }, "expanded shortcut descriptions remain accessible at minimum size")
                if let toggle = elements(window).first(where: { $0.accessibilityRole() == .disclosureTriangle }) { _ = toggle.accessibilityPerformPress() }
            }
            workspace.viewMode = .loupe
            window.setContentSize(NSSize(width: 1440, height: 900))
            await settle()
            try await capture(window, "06-loupe-beige", to: output)

            if let editor = find(window, label: "Metadata Editor") { _ = editor.accessibilityPerformPress() }
            await settle()
            guard let sheet = window.attachedSheet else { throw NSError(domain: "NativeUIQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Metadata sheet did not open"]) }
            try await capture(sheet, "07-metadata-editor", to: output)
            check(find(sheet, label: "Save and close") != nil, "editor exposes its save-and-close action")
            if let headline = find(sheet, label: "Headline", role: .textField) {
                editText(sheet, label: "Headline", value: "Cancelled native draft", fallback: headline)
                await settle()
            } else { check(false, "headline has a named editable text field") }
            if let cancel = find(sheet, label: "Cancel") { _ = cancel.accessibilityPerformPress() }
            await settle()
            check(window.attachedSheet == nil, "Cancel closes the editor")
            check(workspace.currentMetadata.headline == nil, "Cancel does not mutate workspace metadata")
            let selectedPhoto = workspace.currentPhoto!
            check(try SidecarManager().read(from: workspace.metadataSidecarURL(for: selectedPhoto)).headline == nil, "Cancel does not write a draft to disk")

            if let editor = find(window, label: "Metadata Editor") { _ = editor.accessibilityPerformPress() }
            await settle()
            if let sheet = window.attachedSheet,
               let headline = find(sheet, label: "Headline", role: .textField),
               let save = find(sheet, label: "Save and close") {
                editText(sheet, label: "Headline", value: "Native save round trip", fallback: headline)
                await settle()
                _ = save.accessibilityPerformPress()
                await workspace.flushPendingWrites()
                await settle()
                check(window.attachedSheet == nil, "successful save dismisses the editor")
                check(try SidecarManager().read(from: workspace.metadataSidecarURL(for: selectedPhoto)).headline == "Native save round trip", "native editor save round-trips to disk")
            } else { check(false, "metadata save controls remain reachable") }

            if let editor = find(window, label: "Metadata Editor") { _ = editor.accessibilityPerformPress() }
            await settle()
            if let sheet = window.attachedSheet, let headline = find(sheet, label: "Headline", role: .textField) {
                editText(sheet, label: "Headline", value: "Native retry round trip", fallback: headline)
                let moved = fixture.appendingPathComponent("temporarily-unavailable")
                try FileManager.default.moveItem(at: shoot, to: moved)
                if let save = find(sheet, label: "Save and close") { _ = save.accessibilityPerformPress() }
                await settle()
                check(window.attachedSheet != nil, "failed native save keeps the editor open")
                check(elements(sheet).contains { String(describing: $0.accessibilityValue() ?? $0.accessibilityLabel() ?? "").contains("Couldn’t finish saving metadata") }, "native write failure has a visible recovery message")
                try await capture(sheet, "07b-metadata-write-error", to: output)
                try FileManager.default.moveItem(at: moved, to: shoot)
                if let save = find(sheet, label: "Save and close") { _ = save.accessibilityPerformPress() }
                await settle()
                await workspace.flushPendingWrites()
                check(window.attachedSheet == nil, "successful native retry closes the editor")
                check(try SidecarManager().read(from: workspace.metadataSidecarURL(for: selectedPhoto)).headline == "Native retry round trip", "native retry saves the same draft after folder recovery")
            } else { check(false, "native write-error test can open the editor") }

            if let ingest = find(window, label: "Card Ingest") { _ = ingest.accessibilityPerformPress() }
            await settle()
            if let sheet = window.attachedSheet {
                try await capture(sheet, "08-ingest-incomplete", to: output)
                check(hasLabel(sheet, "Choose a source folder to import from."), "ingest explains missing required configuration")
                check(find(sheet, label: "Choose Source (Card)") != nil, "source chooser has a distinct accessible name")
                if let close = find(sheet, label: "Close") { _ = close.accessibilityPerformPress() }
            } else { check(false, "ingest sheet opens") }
            await settle()

            workspace.selection = Set(workspace.photos.prefix(2).map(\.id))
            workspace.viewMode = .compare
            for _ in 0..<60 where !workspace.selection.allSatisfy({ workspace.sharpnessCache[$0] != nil }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await settle()
            try await capture(window, "09-compare", to: output)
            let comparePanes = elements(window).filter { $0.accessibilityLabel()?.hasPrefix("Compare photo ") == true }
            check(comparePanes.count == 2, "both compare panes have named accessibility elements")
            check(comparePanes.allSatisfy { String(describing: $0.accessibilityValue() ?? "").contains("Sharpness score") }, "compare accessibility retains sharpness scores")
            check(comparePanes.contains { String(describing: $0.accessibilityValue() ?? "").contains("Highest sharpness score") }, "compare accessibility identifies the highest scored photo")
            if let firstPane = comparePanes.first {
                _ = firstPane.accessibilityPerformPress()
                await settle()
                check(workspace.currentPhoto?.url.lastPathComponent == "PHOTO_01.jpg", "accessible compare activation changes focus")
                check(workspace.currentMetadata.rating == 1, "accessible compare focus refreshes inspector metadata")
            }
            await workspace.openFolder(fixture.appendingPathComponent("missing-volume"))
            for _ in 0..<30 where workspace.activeHUD != nil { try? await Task.sleep(for: .milliseconds(100)) }
            await settle()
            try await capture(window, "10-folder-error", to: output)
            check(find(window, label: "Try again") != nil, "folder errors expose retry")
            check(find(window, label: "Choose another folder…") != nil, "folder errors expose alternate folder recovery")

            let summary = ["status": failures.isEmpty ? "passed" : "failed", "passed": passed, "failures": failures, "scope": "Native self-hosted UI rendering/accessibility actions; not a human VoiceOver or physical keyboard audit."] as [String: Any]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
            print("Native UI QA: \(passed) passed; \(failures.count) failed. Evidence: \(output.path)")
            for failure in failures { print("FAIL: \(failure)") }
            try? FileManager.default.removeItem(at: fixture)
            exit(failures.isEmpty ? 0 : 1)
        } catch {
            print("Native UI QA error: \(error)")
            let summary: [String: Any] = ["status": "error", "passed": passed, "failures": failures + [error.localizedDescription]]
            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("results.json"))
            }
            exit(1)
        }
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(450)) }

    private static func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 }
        else { failures.append(message) }
    }

    private struct AXNode {
        let object: NSObject
        private func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
            let attributes = ["accessibilityRole": "AXRole", "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue", "accessibilityChildren": "AXChildren"]
            guard let key = attributes[name] else { return nil }
            return legacy(key)
        }
        private func legacy(_ key: String) -> Any? {
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector, with: key)?.takeUnretainedValue()
        }
        func accessibilityLabel() -> String? { attribute("accessibilityLabel") as? String }
        func accessibilityValue() -> Any? { attribute("accessibilityValue") }
        func accessibilityRole() -> NSAccessibility.Role? {
            (attribute("accessibilityRole") as? String).map { NSAccessibility.Role(rawValue: $0) }
        }
        func children() -> [Any] {
            if let ordered = attribute("accessibilityChildrenInNavigationOrder") as? [Any], !ordered.isEmpty { return ordered }
            if let children = attribute("accessibilityChildren") as? [Any], !children.isEmpty { return children }
            if let children = legacy("AXChildren") as? [Any], !children.isEmpty { return children }
            return (object as? NSView)?.subviews ?? []
        }
        func accessibilityPerformPress() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Press.self)(object, selector)
        }
        func setAccessibilityValue(_ value: String) {
            let selector = NSSelectorFromString("setAccessibilityValue:")
            guard object.responds(to: selector) else { return }
            object.perform(selector, with: value)
        }
        func frame() -> NSRect {
            if let element = object as? any NSAccessibilityElementProtocol { return element.accessibilityFrame() }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return .zero }
            typealias Frame = @convention(c) (AnyObject, Selector) -> CGRect
            return unsafeBitCast(implementation, to: Frame.self)(object, selector)
        }
    }

    private static func editText(_ window: NSWindow, label: String, value: String, fallback: AXNode) {
        @MainActor func textFields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
        }
        if let root = window.contentView,
           let field = textFields(root).first(where: { $0.placeholderString == label }) {
            field.stringValue = value
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        } else { fallback.setAccessibilityValue(value) }
    }

    private static func elements(_ node: Any, depth: Int = 0) -> [AXNode] {
        guard depth < 40 else { return [] }
        if let object = node as? NSObject {
            let ax = AXNode(object: object)
            return [ax] + ax.children().flatMap { elements($0, depth: depth + 1) }
        }
        return []
    }

    private static func find(_ window: NSWindow, label: String, role: NSAccessibility.Role? = nil) -> AXNode? {
        elements(window).first { $0.accessibilityLabel() == label && (role == nil || $0.accessibilityRole() == role) }
    }

    private static func hasLabel(_ window: NSWindow, _ text: String) -> Bool {
        elements(window).contains { $0.accessibilityLabel() == text || ($0.accessibilityValue() as? String) == text }
    }

    private static func capture(_ window: NSWindow, _ name: String, to directory: URL) async throws {
        guard let view = window.contentView?.superview else { throw NSError(domain: "NativeUIQA", code: 3) }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "NativeUIQA", code: 4) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var result = bitmap
        var method = "NSView bitmap (some system glass-control layers may render differently from the composited window)"
        if CGPreflightScreenCaptureAccess() {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            if let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                let configuration = SCStreamConfiguration()
                configuration.width = Int(window.frame.width * window.backingScaleFactor)
                configuration.height = Int(window.frame.height * window.backingScaleFactor)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
                result = NSBitmapImageRep(cgImage: image)
                method = "Composited image of this app's own window (existing capture permission; no prompt or permission change)"
            }
        }
        guard let data = result.representation(using: .png, properties: [:]) else { throw NSError(domain: "NativeUIQA", code: 5) }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        try method.write(to: directory.appendingPathComponent("capture-method.txt"), atomically: true, encoding: .utf8)
        let tree = elements(window).map { "\($0.accessibilityRole()?.rawValue ?? "unknown") | \($0.accessibilityLabel() ?? "") | \(String(describing: $0.accessibilityValue() ?? "")) | \(String(describing: type(of: $0.object)))" }.joined(separator: "\n")
        try tree.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    private static func writeJPEG(_ url: URL, seed: Int) throws {
        let context = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: CGFloat(seed) / 4, green: 0.3, blue: CGFloat(4 - seed) / 4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(10)
        context.stroke(CGRect(x: 120, y: 120, width: 1360, height: 760))
        for index in 0..<seed { context.strokeEllipse(in: CGRect(x: 220 + index * 260, y: 350, width: 180, height: 180)) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "NativeUIQA", code: 6) }
    }
}
#endif
