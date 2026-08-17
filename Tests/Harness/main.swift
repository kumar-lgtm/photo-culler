import Foundation

// Headless regression suite for Photo Culler's logic packages.
//
// Runs without XCTest (and therefore without a full Xcode install):
//     swift run pcqa
//
// The UI package isn't covered here — it needs a running app — but every module that
// touches the user's files is.

let runner = TestRunner()

print("\u{001B}[1mPhoto Culler — regression suite\u{001B}[0m")

do {
    try await SidecarSuite.run(runner)
    try RenameSuite.run(runner)
    try await CatalogSuite.run(runner)
    try await IngestSuite.run(runner)
} catch {
    runner.fail("suite threw an unexpected error: \(error)")
}

exit(runner.report())
