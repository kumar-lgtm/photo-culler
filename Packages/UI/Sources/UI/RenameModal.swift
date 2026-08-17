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
    @Environment(\.dismiss) var dismiss
    
    private let renamer = BatchRenamer()
    private let formatter = RenameFormatter()
    
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
                    Text("Rename \(workspace.renamableSelection().count) selected files")
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
                        
                        Text("Available tokens: {seq}, {name}, {date}, {time}, {ext}")
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
                }
                .frame(maxWidth: .infinity)
                
                // Right Column: Preview
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.headline)
                    
                    List {
                        ForEach(preview, id: \.originalURL) { op in
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
                            .font(.system(.caption, design: .monospaced))
                        }
                        
                        if workspace.renamableSelection().count > preview.count {
                            Text("... and \(workspace.renamableSelection().count - preview.count) more")
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
                            Text("Naming collisions detected. Some files will have the same name.")
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
                .disabled(workspace.renamableSelection().isEmpty || hasCollisions || isRenaming)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 700)
        .onChange(of: template) { _, _ in updatePreview() }
        .onChange(of: sequenceStart) { _, _ in updatePreview() }
        .onAppear { updatePreview() }
    }
    
    private func updatePreview() {
        let selectedPhotos = workspace.renamableSelection()
        
        let previewCount = min(5, selectedPhotos.count)
        var previewItems: [RenameContext] = []
        
        for (index, photo) in selectedPhotos.prefix(previewCount).enumerated() {
            previewItems.append(RenameContext(originalURL: photo.url, sequence: sequenceStart + index))
        }
        
        // We pass ALL items to renamer to check for collisions, but only store operations for previewCount
        var allItems: [RenameContext] = []
        for (index, photo) in selectedPhotos.enumerated() {
            allItems.append(RenameContext(originalURL: photo.url, sequence: sequenceStart + index))
        }
        
        let fullResult = renamer.preview(items: allItems, template: template, formatter: formatter)
        preview = Array(fullResult.operations.prefix(previewCount))
        hasCollisions = !fullResult.collisions.isEmpty
    }
    
    private func performRename() {
        isRenaming = true
        let selectedPhotos = workspace.renamableSelection()
        
        Task {
            var items: [RenameContext] = []
            for (index, photo) in selectedPhotos.enumerated() {
                items.append(RenameContext(originalURL: photo.url, sequence: sequenceStart + index))
            }
            
            let result = renamer.preview(items: items, template: template, formatter: formatter)
            
            do {
                try renamer.execute(operations: result.operations)
                await workspace.openFolder(workspace.currentFolder!) // Refresh
                dismiss()
            } catch {
                print("Rename failed: \(error)")
                isRenaming = false
            }
        }
    }
}
