# Photo Culler — Developer Guide & Architecture

Native **macOS application** (Swift 6, macOS 14+) for high-performance photo culling, modeled after Photo Mechanic. Enables instant keep/reject triage, RAW+JPEG pairing, XMP/IPTC sidecar editing, and dual-destination card ingest.

---

## 🏗 Modular Architecture

Built as a modular Swift Package Manager target hierarchy (`Package.swift`):

- `PhotoCuller/` — Executable App Target (`PhotoCullerApp.swift`). AppKit windowing with `.hiddenTitleBar` shell.
- `Packages/UI` — SwiftUI views (`ShellView`, `CompareView`, `InspectorView`, `MetadataEditorView`, `IngestView`, `RenameModal`), `WorkspaceViewModel`, Vision Face Zoom (`ImageAnalyzer`), and CoreGraphics Histogram.
- `Packages/Catalog` — Directory scanning (`CatalogScanner`), file models (`PhotoItem`), RAW+JPEG pairing, and 40+ RAW format extension matching.
- `Packages/Decode` — `ImageProvider` actor with 3-tier `NSCache` system (Thumbnail 512px, Preview 3200px, Full native) via ImageIO & CoreGraphics. Tiers are bounded by **byte cost** (`totalCostLimit`), not entry count.
- `Packages/Sidecar` — XMP sidecar persistence, IPTC metadata Core fields, Stationery Pad templates, embedded metadata writing, Sports Code Replacements (`\code\`), and `MetadataWriteCoordinator` — the single actor every metadata write goes through.
- `Packages/Rename` — Tokenized batch renaming engine (`RenameFormatter`) supporting sequence numbers, dates, EXIF camera metadata, and ratings. Two-phase execution, pair-aware, undoable.
- `Packages/Shortcuts` — Sub-frame `NSEvent` key-down event interceptor (`ShortcutManager`) for zero-latency keyboard triage (0-5 stars, ⌘1-8 color labels, flags, arrow nav). Digits and WASD match by physical key code.
- `Packages/Ingest` — Concurrent card import pipeline (`IngestManager`) with independent per-destination copy, size verification, on-the-fly metadata tagging, and renaming.
- `Tests/Harness` — the `pcqa` headless regression suite (see below).

---

## 🛠 Commands & Workflow

```bash
# Debug build
swift build

# Optimized release build
swift build -c release

# Headless regression suite — works WITHOUT full Xcode. This is the real gate.
swift run pcqa

# Same, plus the per-package XCTest suites when a full Xcode is selected
./test.sh

# Package release binary into distributable DMG bundle
./scripts/package-dmg.sh
```

---

## 🧠 Key Architecture & Learnings ("What It Taught Me")

- **Native Desktop App Dev**: Swift 6 strict concurrency (`actor`, `Sendable`, `@MainActor`), AppKit/SwiftUI hybrid windowing, and clean SPM module isolation.
- **File-System Performance Tuning**: Lazy directory traversal and non-blocking asynchronous file scanning for 10,000+ photo catalogs without main thread stutter.
- **Image Rendering Speed**: Multi-tiered ImageIO preview decoding, NSCache memory bounding (<500MB RAM), and Apple Vision framework face bounding box detection for instant focus checks.
- **High-Efficiency Keyboard Workflows**: Direct `NSEvent` interceptors enabling sub-frame response times and auto-advance culling ergonomics for creator tools.

---

## ⚠️ Conventions & Gotchas

- **Swift app, not web**: Built entirely in Swift with SPM (`swift build`). No `package.json` or `npm`.
- **Artifacts**: `build/` and `*.dmg` are generated build outputs — do not edit manually and they are gitignored. Always use `./scripts/package-dmg.sh` to package releases.
- **Testing**: `swift run pcqa` is the gate and needs no Xcode. `swift test` / XCTest **cannot run** on a Command Line Tools-only machine — don't conclude the suite is broken when it's really just unavailable.
- **All metadata writes go through `MetadataWriteCoordinator`.** Never call `SidecarManager.write` or `EmbeddedMetadataWriter` from a view or a loose `Task.detached` — that's what caused rapid keystrokes to clobber each other and collide on a shared temp file.
- **XMP has two serializations.** Adobe writes values as *attributes* on `rdf:Description`; other tools use child *elements*. Read/write handles both, matched by namespace URI (Foundation's XPath does **not** implement `namespace-uri()`, so selection is by `local-name()` then filtered on `XMLNode.uri`). Also: parsed namespace declarations live in `XMLElement.namespaces`, not `attributes` — checking only the latter re-declares `xmlns:` and produces a file that won't re-parse.
- **Bundle identifier is `com.braveenkumar.photoculler`** (was misspelled `photculler` until 2026-08-17). Changing it again resets every user's preferences and permissions.
- **Don't declare `NSSupportsSuddenTermination`** — background file writes are in flight; `flush()` runs on `willTerminate` instead.
- **Extension case on rename**: the auto-appended extension preserves the source case (`.CR2`); the `{ext}` token lowercases. Deliberate — see `RenameFormatter.format`.
