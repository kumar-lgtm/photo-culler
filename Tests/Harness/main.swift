import Foundation
import AppKit

// Line-buffer stdout. When output is redirected it is otherwise block-buffered, so a crash
// mid-run discards everything printed so far — which turns "it trapped somewhere" into
// "it produced no output at all".
setvbuf(stdout, nil, _IOLBF, 0)

// Headless regression suite for Photo Culler's logic packages.
//
// Runs without XCTest (and therefore without a full Xcode install):
//     swift run pcqa
//
// The UI package isn't covered here — it needs a running app — but every module that
// touches the user's files is.

// `--bench` measures instead of asserting; see Benchmarks.swift.
if let rawIndex = CommandLine.arguments.firstIndex(of: "--bench-raw-file") {
    let paths = Array(CommandLine.arguments.dropFirst(rawIndex + 1))
    do { try await RawFileBenchmark.run(paths: paths); exit(0) }
    catch { print("benchmark failed: \(error.localizedDescription)"); exit(1) }
}

if CommandLine.arguments.contains("--bench-storm") {
    do { try await DecodeStormBenchmark.run(); exit(0) }
    catch { print("benchmark failed: \(error)"); exit(1) }
}

if CommandLine.arguments.contains("--bench-open") {
    _ = NSApplication.shared
    do {
        try await OpenFolderBenchmark.run()
        exit(0)
    } catch {
        print("benchmark failed: \(error)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--bench") {
    do {
        try await Benchmarks.run()
        exit(0)
    } catch {
        print("benchmark failed: \(error)")
        exit(1)
    }
}

let runner = TestRunner()

print("\u{001B}[1mPhoto Culler — regression suite\u{001B}[0m")

// WorkspaceViewModel is @MainActor and touches AppKit; give it a real NSApplication.
_ = NSApplication.shared

do {
    try await DecodeSuite.run(runner)
    try await SidecarSuite.run(runner)
    try RenameSuite.run(runner)
    try await CatalogSuite.run(runner)
    try await IngestSuite.run(runner)
    try await WorkspaceSuite.run(runner)
} catch {
    runner.fail("suite threw an unexpected error: \(error)")
}

exit(runner.report())
