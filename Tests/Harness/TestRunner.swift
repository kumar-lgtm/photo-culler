import Foundation

/// Minimal assertion harness.
///
/// XCTest ships only with full Xcode, so `swift test` cannot run on a machine that has just
/// the Command Line Tools — which meant the suite was unrunnable in exactly the environment
/// most likely to be doing a quick check, and in CI. This is a plain executable, so
/// `swift run pcqa` works anywhere the project builds.
final class TestRunner {

    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var currentSuite = ""

    func suite(_ name: String) {
        currentSuite = name
        print("\n\u{001B}[1m▸ \(name)\u{001B}[0m")
    }

    func check(_ condition: Bool, _ description: String, line: Int = #line) {
        if condition {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(description)")
        } else {
            let message = "\(currentSuite) › \(description)  (line \(line))"
            failures.append(message)
            print("  \u{001B}[31m✗ \(description)  (line \(line))\u{001B}[0m")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ description: String, line: Int = #line) {
        if actual == expected {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(description)")
        } else {
            let message = "\(currentSuite) › \(description)\n      expected: \(expected)\n      actual:   \(actual)  (line \(line))"
            failures.append(message)
            print("  \u{001B}[31m✗ \(description)\u{001B}[0m")
            print("      expected: \(expected)")
            print("      actual:   \(actual)  (line \(line))")
        }
    }

    func fail(_ description: String, line: Int = #line) {
        failures.append("\(currentSuite) › \(description)  (line \(line))")
        print("  \u{001B}[31m✗ \(description)  (line \(line))\u{001B}[0m")
    }

    func report() -> Int32 {
        print("\n" + String(repeating: "─", count: 62))
        if failures.isEmpty {
            print("\u{001B}[32m\u{001B}[1mAll \(passed) checks passed.\u{001B}[0m")
            return 0
        }
        print("\u{001B}[31m\u{001B}[1m\(failures.count) failure(s), \(passed) passed:\u{001B}[0m")
        for failure in failures {
            print("  • \(failure)")
        }
        return 1
    }
}

// MARK: - Filesystem helpers

enum TempDir {
    static func make(_ label: String = "pcqa") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension URL {
    @discardableResult
    func writeText(_ contents: String) throws -> URL {
        try contents.write(to: self, atomically: true, encoding: .utf8)
        return self
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var isHiddenFlag: Bool {
        (try? resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
    }
}
