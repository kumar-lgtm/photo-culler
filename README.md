# Photo Culler

**Photo Culler** is a high-performance, native macOS photo culling application modeled on industry-standard tools like Photo Mechanic. Built with **Swift 6** and **SwiftUI / AppKit** for **macOS 14+**, it provides lightning-fast, offline keep/reject triage for high-volume photo shoots with zero-lag RAW decoding, low-latency keyboard ergonomics, XMP/IPTC metadata persistence, and automated card ingest.

---

## 🏛 Architecture Breakdown

Photo Culler uses a modular multi-package Swift architecture. The top-level application shell (`PhotoCuller`) delegates core domain logic to seven specialized local Swift packages located under `Packages/`.

```
PhotoCuller (App Target)
  └── UI (SwiftUI Views, ViewModels, Vision Face Zoom, Sync Panning)
       ├── Catalog (File Scanner, RAW+JPEG Pairing, Extension Registry)
       ├── Decode (Actor-based Multi-tier ImageIO / CoreGraphics Cache)
       ├── Sidecar (XMP Persistence, IPTC Metadata, Stationery Pad, Code Replacements)
       ├── Rename (Tokenized Formatter, Sequence / Date / Metadata Expansion)
       ├── Shortcuts (NSEvent Keyboard Monitor, Fast Action Dispatcher)
       └── Ingest (Concurrent Dual-Destination Card Import Pipeline)
```

### Swift Package Roster

- **`PhotoCuller` (App Target)**: Executable entry point (`PhotoCullerApp.swift`). Initializes the shared actors and managers, configures AppKit windowing (`.hiddenTitleBar`), and mounts `ShellView`.
- **`UI`**: High-level presentation layer (`ShellView`, `SidebarView`, `MainViewerView`, `CompareView`, `InspectorView`, `MetadataEditorView`, `IngestView`, `RenameModal`). Implements state orchestration via `WorkspaceViewModel`, 4-up synchronized zoom/pan, CoreGraphics histogram rendering, and Apple Vision framework face detection (`ImageAnalyzer`).
- **`Catalog`**: Directory scanning (`CatalogScanner`, `FolderManager`) and catalog models (`PhotoItem`). Manages extension registries for 40+ RAW formats (`.cr2`, `.cr3`, `.nef`, `.arw`, `.dng`, etc.), JPEGs, and videos, automatically detecting and grouping RAW+JPEG file pairs.
- **`Decode`**: Actor-isolated image decoding pipeline (`ImageProvider`). Utilizes CoreGraphics and ImageIO to provide asynchronous, non-blocking image decoding across three cache tiers, each bounded by **bytes** via `NSCache.totalCostLimit` (an entry-count limit can't bound memory, since a 512px RGBA bitmap is ~1 MB):
  - `.thumbnail` (512px limit, 192 MB budget)
  - `.preview` (3200px limit, 256 MB budget)
  - `.full` (native resolution, 320 MB budget) — decoded on demand when you zoom or when the preview would be upscaled on the current display, not eagerly for every photo you land on.
- **`Sidecar`**: Metadata persistence and interoperability layer (`SidecarManager`). Parses and writes Lightroom/Capture One-compatible XMP sidecars, IPTC Core fields (`photoshop:Headline`, `dc:description`, `dc:creator`), metadata templates ("Stationery Pad"), embedded EXIF/IPTC metadata writing (`EmbeddedMetadataWriter`), and sports reporter code replacement expansion (`CodeReplacementManager`).
- **`Rename`**: Tokenized batch renaming engine (`RenameFormatter`). Expands pattern strings using contextual variables (`{Date(YYMMDD)}`, `{Sequence(001)}`, `{CameraModel}`, `{Lens}`, `{ISO}`, `{Rating}`), reading EXIF on demand so the camera/lens/ISO tokens resolve to real values. Dates are formatted with a fixed Gregorian `en_US_POSIX` calendar (a locale-dependent formatter yields Buddhist-era years on a Thai-configured Mac), and output is sanitized so a value containing `/` can't escape the directory. Renames run in **two phases** via temp names, so swaps and shifted sequences (A→B while B→C) work, RAW+JPEG pairs and their sidecars move together, and the batch is undoable.
- **`Shortcuts`**: Sub-frame keyboard event monitoring engine (`ShortcutManager`). Installs a local `NSEvent` key-down monitor to dispatch zero-latency culling commands (ratings `0-5`, color labels `⌘1-8`, clear label `` ` ``, pick/reject/unflag `P`/`X`/`U`, arrow navigation, view mode toggles). Digit and WASD-pan keys are matched by physical **key code**, so they work on AZERTY and other non-QWERTY layouts; the monitor passes events through whenever a sheet or text field has focus, so Escape still dismisses modals.
- **`Ingest`**: SD card import pipeline (`IngestManager`). Performs concurrent dual-destination file copies (e.g., primary SSD + secondary backup HDD) while simultaneously applying Stationery Pad metadata templates and batch renaming rules.

---

## ⚡ Core Features

- **Zero-Lag RAW Decoding**: Instantaneous preview generation leveraging embedded JPEG previews and multi-tier CoreGraphics decoding.
- **Keyboard-First Culling & Auto-Advance**: Single-key rating (0-5 stars), color labeling, and pick/reject tagging with instant auto-advance to the next frame.
- **4-Up Synchronized Compare View**: Compare up to 4 images side-by-side with synchronized pan/zoom lock step for focus checks.
- **Vision-Powered Face Zoom**: Uses Apple's Vision framework to detect faces in photo pairs and automatically zoom directly to facial bounding boxes for sharp focus validation.
- **XMP & IPTC Interoperability**: Non-destructive star ratings, color tags, captions, headlines, and copyright persisted into standard XMP sidecar files compatible with Adobe Lightroom, Capture One, and Bridge. Both XMP serializations are handled — Adobe's compact **attribute** form (`<rdf:Description xmp:Rating="4"/>`) and the **element** form — matched by namespace URI rather than prefix, and written back in whichever form the file already uses.
- **Serialized metadata writes**: All sidecar, embedded-IPTC and Finder-tag writes funnel through a single actor that guarantees per-file ordering and coalesces rapid keystrokes, so a burst of rating/label keys converges on the state you actually asked for instead of racing. Color labels merge into the file's existing Finder tags rather than replacing them.
- **Sports Code Replacements**: Shortcode expansion (e.g., typing `\m10\` expands to `"Lionel Messi"`) for rapid captioning during live athletic events.
- **Dual-Destination Ingest**: Concurrent copy from camera media to working drive and backup array with on-the-fly metadata tagging. Each destination is evaluated independently (so a re-run repairs an incomplete backup), destination filenames are validated for uniqueness before a single byte is copied, every copy is size-verified, and the job is cancellable with a free-space preflight.

---

## 🛠 Build, Test & Package Commands

### Building

```bash
# Debug build
swift build

# Optimized release build
swift build -c release
```

### Automated Testing

```bash
./test.sh          # regression suite, plus XCTest packages if full Xcode is installed
swift run pcqa     # regression suite only
```

The primary gate is a **headless regression suite** (`Tests/Harness`, built as the `pcqa`
executable). It runs against real files in temp directories and needs no XCTest, so it works
with only the Command Line Tools installed and in CI — unlike `swift test`, which requires a
full Xcode. It covers every module that touches your files: XMP read/write in both
serializations, write serialization under keystroke bursts, Finder-tag merging, two-phase and
pair-aware renaming, undo, and the full card-ingest path including duplicate-name refusal,
independent per-destination copying, and cancellation.

The per-package XCTest suites still exist and run automatically when a full Xcode is selected.

### Packaging & Distribution

Build the release executable, construct the macOS `.app` bundle, apply ad-hoc code signatures, and package the installer DMG:

```bash
./scripts/package-dmg.sh
```
*Output artifact: `build/Photo Culler.dmg`*

---

## 💡 Key Learnings ("What It Taught Me")

1. **Native Desktop App Architecture**: Structuring a complex macOS desktop app requires a clean boundary between UI rendering (SwiftUI) and low-level system events (AppKit `NSEvent`, `NSCache`). Adopting Swift 6 strict concurrency (`actor`, `Sendable`, `@MainActor`) prevents data races when loading multi-gigabyte photo catalogs concurrently.
2. **File-System Performance Tuning**: High-volume photo culling demands non-blocking directory scanning. Scanning 10,000+ files requires lazy directory enumeration (`FileManager.DirectoryEnumerator`), batch RAW+JPEG pairing, and atomic asynchronous file operations to keep the UI at 60 FPS.
3. **Image Rendering Speed & Memory Hierarchy**: Fast RAW previewing is achieved by leveraging ImageIO's fast thumbnail extraction (`CGImageSourceCreateThumbnailAtIndex`) rather than full RAW rasterization. A 3-tiered `NSCache` hierarchy bounds RAM by byte cost — `countLimit` alone can't, which is the difference between a cache you can reason about and one that quietly holds a gigabyte.
4. **High-Efficiency Keyboard Workflows for Creator Tools**: Professional creator tools live or die by input latency. Intercepting keystrokes at the `NSEvent` level bypasses standard UI responder chain delays, achieving sub-frame response times essential for high-speed photo triage.
