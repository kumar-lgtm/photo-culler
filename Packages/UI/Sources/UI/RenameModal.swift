import SwiftUI
import Catalog
import Rename
import Decode

public struct RenameModal: View {
    @ObservedObject var workspace: WorkspaceViewModel
    @State private var template: String = "{seq}_{name}"
    @State private var sequenceStart: Int = 1
    @State private var preview: [RenameOperation] = []
    @State private var hasCollisions: Bool = false
    @State private var isRenaming: Bool = false
    @State private var errorMessage: String?
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.dismiss) var dismiss

    private let formatter = RenameFormatter()

    /// Rows shown in the preview list. The collision check still runs over the whole
    /// selection — only the rendering is capped.
    private let previewRowLimit = 5

    let commonTemplates = [
        "{seq}_{name}",
        "{date}_{seq}",
        "{name}_{seq}",
        "Photo_{seq}"
    ]

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "pencil.and.list.clipboard")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Batch Rename")
                        .font(.title)
                        .fontWeight(.bold)
                    Text(subtitle)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            HStack(alignment: .top, spacing: 20) {
                // Left Column: Configuration
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Format Template")
                            .font(.headline)

                        TextField("e.g. {seq}_{name}", text: $template)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(commonTemplates, id: \.self) { tpl in
                                    Button(tpl) {
                                        template = tpl
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }

                        Text("Tokens: {seq}, {name}, {date}, {time}, {ext}, {camera}, {lens}, {iso}")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sequence")
                            .font(.headline)
                        HStack {
                            Text("Start at:")
                            TextField("", value: $sequenceStart, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }

                    if workspace.renamer.canUndo() {
                        Button {
                            undoLastRename()
                        } label: {
                            Label("Undo last rename", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)

                // Right Column: Preview
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.headline)

                    List {
                        ForEach(preview, id: \.originalURL) { op in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(op.originalURL.lastPathComponent)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Image(systemName: "arrow.right")
                                        .foregroundColor(.secondary)
                                    Text(op.newURL.lastPathComponent)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                // Make the paired JPEG visible so it's obvious both halves move.
                                if let pairedOld = op.pairedOriginalURL, let pairedNew = op.pairedNewURL {
                                    HStack {
                                        Image(systemName: "link")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.tertiary)
                                        Text("\(pairedOld.lastPathComponent) → \(pairedNew.lastPathComponent)")
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .font(.system(.caption, design: .monospaced))
                        }

                        if selectionCount > preview.count {
                            Text("... and \(selectionCount - preview.count) more")
                                .foregroundColor(.secondary)
                                .font(.caption)
                                .padding(.top, 4)
                        }
                    }
                    .frame(height: 180)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(hasCollisions ? Color.red : Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                    if hasCollisions {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Naming collisions detected. Some files would end up with the same name.")
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    }

                    if let errorMessage {
                        HStack(alignment: .top) {
                            Image(systemName: "xmark.octagon.fill")
                            Text(errorMessage)
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: performRename) {
                    if isRenaming {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 4)
                    } else {
                        Text("Rename Files")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectionCount == 0 || hasCollisions || isRenaming)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 700)
        .onChange(of: template) { _, _ in schedulePreview() }
        .onChange(of: sequenceStart) { _, _ in schedulePreview() }
        .onAppear { schedulePreview() }
        .onDisappear { previewTask?.cancel() }
    }

    private var selectionCount: Int { workspace.renamableSelection().count }

    private var subtitle: String {
        let items = workspace.renamableSelection()
        let pairs = items.filter { $0.isRAWJPEGPair }.count
        if pairs > 0 {
            return "Rename \(items.count) selected · \(pairs) RAW+JPEG pair\(pairs == 1 ? "" : "s") move together"
        }
        return "Rename \(items.count) selected files"
    }

    /// Only read EXIF when the template actually asks for it — it costs a file open per item.
    private func templateNeedsEXIF() -> Bool {
        let exifTokens = ["{camera}", "{lens}", "{iso}", "{CameraModel}", "{Lens}", "{ISO}"]
        return exifTokens.contains { template.contains($0) }
    }

    private func contexts(for photos: [PhotoItem]) -> [RenameContext] {
        let needsEXIF = templateNeedsEXIF()
        return photos.enumerated().map { index, photo in
            let sequence = sequenceStart + index
            if needsEXIF {
                return RenameContext.forImage(at: photo.url, sequence: sequence, pairedURL: photo.pairedURL)
            }
            return RenameContext(originalURL: photo.url, sequence: sequence, pairedURL: photo.pairedURL)
        }
    }

    /// Debounced, and off the main thread.
    ///
    /// This used to run the full collision check — a `FileManager.fileExists` per item —
    /// synchronously on every keystroke. With 2,000 photos selected that was 2,000 `stat()`
    /// calls per character typed.
    private func schedulePreview() {
        previewTask?.cancel()
        let photos = workspace.renamableSelection()
        let currentTemplate = template
        let items = contexts(for: photos)
        let limit = previewRowLimit

        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }

            let result = await Task.detached(priority: .userInitiated) { () -> (operations: [RenameOperation], collisions: [URL]) in
                BatchRenamer().preview(items: items, template: currentTemplate, formatter: RenameFormatter())
            }.value

            guard !Task.isCancelled else { return }
            preview = Array(result.operations.prefix(limit))
            hasCollisions = !result.collisions.isEmpty
        }
    }

    private func performRename() {
        errorMessage = nil
        isRenaming = true

        let photos = workspace.renamableSelection()
        let items = contexts(for: photos)
        let currentTemplate = template
        let renamer = workspace.renamer

        Task {
            let plan = await Task.detached(priority: .userInitiated) { () -> (operations: [RenameOperation], collisions: [URL]) in
                renamer.preview(items: items, template: currentTemplate, formatter: RenameFormatter())
            }.value

            // Re-check at execution time; the debounced preview state could be stale.
            guard plan.collisions.isEmpty else {
                hasCollisions = true
                errorMessage = "\(plan.collisions.count) file(s) would collide. Adjust the template."
                isRenaming = false
                return
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try renamer.execute(operations: plan.operations)
                }.value
                await refreshFolder()
                dismiss()
            } catch {
                errorMessage = describe(error)
                isRenaming = false
            }
        }
    }

    private func undoLastRename() {
        errorMessage = nil
        isRenaming = true
        let renamer = workspace.renamer

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try renamer.undo()
                }.value
                await refreshFolder()
                isRenaming = false
            } catch {
                errorMessage = describe(error)
                isRenaming = false
            }
        }
    }

    /// No force-unwrap: there's no guarantee a folder is open by the time this runs.
    private func refreshFolder() async {
        guard let folder = workspace.currentFolder else { return }
        await workspace.openFolder(folder)
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case let RenameError.moveFailed(url, underlying):
            return "Couldn't rename \(url.lastPathComponent): \(underlying.localizedDescription)"
        case let RenameError.rollbackIncomplete(stranded, _):
            return "Rename failed and \(stranded.count) file(s) could not be restored. "
                 + "They are in the folder with temporary names beginning “.pcrename-”."
        case let RenameError.collisionsDetected(urls):
            return "\(urls.count) naming collision(s)."
        default:
            return error.localizedDescription
        }
    }
}
