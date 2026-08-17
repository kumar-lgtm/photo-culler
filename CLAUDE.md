# Photo Culler — Developer Guide & Architecture

Native **macOS application** (Swift 6, macOS 14+) for high-performance photo culling, modeled after Photo Mechanic. Enables instant keep/reject triage, RAW+JPEG pairing, XMP/IPTC sidecar editing, and dual-destination card ingest.

---

## 🏗 Modular Architecture

Built as a modular Swift Package Manager target hierarchy (`Package.swift`):

- `PhotoCuller/` — Executable App Target (`PhotoCullerApp.swift`). AppKit windowing with `.hiddenTitleBar` shell.
- `Packages/UI` — SwiftUI views (`ShellView`, `CompareView`, `InspectorView`, `MetadataEditorView`, `IngestView`, `RenameModal`), `WorkspaceViewModel`, Vision Face Zoom (`ImageAnalyzer`), and CoreGraphics Histogram.
- `Packages/Catalog` — Directory scanning (`CatalogScanner`), file models (`PhotoItem`), RAW+JPEG pairing, and 40+ RAW format extension matching.
- `Packages/Decode` — `ImageProvider` actor with 3-tier `NSCache` system (Thumbnail 256px, Preview 2048/3200px, Full Native) via ImageIO & CoreGraphics.
- `Packages/Sidecar` — XMP sidecar persistence, IPTC metadata Core fields, Stationery Pad templates, embedded metadata writing, and Sports Code Replacements (`\code\`).
- `Packages/Rename` — Tokenized batch renaming engine (`RenameFormatter`) supporting sequence numbers, dates, camera metadata, and ratings.
- `Packages/Shortcuts` — Sub-frame `NSEvent` key-down event interceptor (`ShortcutManager`) for zero-latency keyboard triage (0-5 stars, color labels, flags, arrow nav).
- `Packages/Ingest` — Concurrent card import pipeline (`IngestManager`) with dual-destination copy, on-the-fly metadata tagging, and renaming.

---

## 🛠 Commands & Workflow

```bash
# Debug build
swift build

# Optimized release build
swift build -c release

# Run automated tests across all local packages
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
- **Artifacts**: `build/` and `Photo Culler.dmg` are generated build outputs — do not edit manually. Always use `./scripts/package-dmg.sh` to package releases.
- **Testing**: Run `./test.sh` to verify all 7 package test suites.
