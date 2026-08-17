import SwiftUI
import Catalog
import Sidecar
import UniformTypeIdentifiers

struct MetadataEditorView: View {
    @ObservedObject var workspace: WorkspaceViewModel
    @State private var templates: [MetadataTemplate] = []
    @State private var selectedTemplate: MetadataTemplate?
    @State private var isEditingTemplate = false
    @State private var editingTemplate = MetadataTemplate()
    @State private var codeReplacementManager: CodeReplacementManager?
    @State private var codeReplacementCount: Int = 0
    @Environment(\.dismiss) private var dismiss
    
    private let templateManager = TemplateManager()
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            
            Divider()
            
            if let photo = workspace.currentPhoto {
                currentMetadataSection(for: photo)
            } else {
                ContentUnavailableView("No Photo Selected", systemImage: "photo", description: Text("Select a photo to edit its metadata."))
            }
            
            Divider()
            
            templateSection
        }
        .frame(minWidth: 400, idealWidth: 500, minHeight: 500)
        .task {
            templates = templateManager.loadTemplates()
        }
    }
    
    // MARK: - Header
    
    private var headerBar: some View {
        HStack {
            Text("Metadata Editor")
                .font(.headline)
            
            Spacer()
            
            let editableSelectionCount = workspace.photos.filter { workspace.selection.contains($0.id) && workspace.canWriteMetadata(to: $0) }.count
            if editableSelectionCount > 1 {
                Text("\(editableSelectionCount) editable selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.leading, 8)
        }
        .padding()
    }
    
    // MARK: - Current Metadata
    
    private func currentMetadataSection(for photo: PhotoItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Section {
                    LabeledContent("File") {
                        Text(photo.url.lastPathComponent)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("File Info")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        metadataField("Headline", text: headlineBinding, expandCodes: true)
                        metadataField("Caption", text: descriptionBinding, axis: .vertical, expandCodes: true)
                        metadataField("Creator", text: creatorBinding)
                        metadataField("Copyright", text: copyrightBinding)
                    }
                } header: {
                    HStack {
                        Text("IPTC Metadata")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        if codeReplacementCount > 0 {
                            Text("\(codeReplacementCount) codes")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        
                        Button("Load Codes", systemImage: "text.badge.plus") {
                            loadCodeReplacements()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Save", systemImage: "square.and.arrow.down") {
                            saveCurrentMetadata()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding()
        }
    }
    
    private func metadataField(_ label: String, text: Binding<String>, axis: Axis = .horizontal, expandCodes: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            if axis == .vertical {
                TextField(label, text: text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        if expandCodes, let manager = codeReplacementManager {
                            let expanded = manager.expand(newValue)
                            if expanded != newValue {
                                text.wrappedValue = expanded
                            }
                        }
                    }
            } else {
                TextField(label, text: text)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        if expandCodes, let manager = codeReplacementManager {
                            let expanded = manager.expand(newValue)
                            if expanded != newValue {
                                text.wrappedValue = expanded
                            }
                        }
                    }
            }
        }
    }
    
    // MARK: - Template Section
    
    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stationery Pad")
                    .font(.subheadline.weight(.semibold))
                
                Spacer()
                
                Button("New Template", systemImage: "plus") {
                    editingTemplate = MetadataTemplate(name: "New Template", creator: workspace.currentMetadata.creator ?? "", copyright: workspace.currentMetadata.copyright ?? "")
                    isEditingTemplate = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            if templates.isEmpty {
                Text("No templates yet. Create one to quickly apply metadata to photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(templates) { template in
                            templateCard(template)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .sheet(isPresented: $isEditingTemplate) {
            templateEditorSheet
        }
    }
    
    private func templateCard(_ template: MetadataTemplate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(template.name)
                .font(.caption.weight(.semibold))
            
            if !template.creator.isEmpty {
                Text(template.creator)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(minWidth: 100)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 8))
        .contextMenu {
            Button("Apply to Selected") {
                applyTemplate(template)
            }
            Button("Edit") {
                editingTemplate = template
                isEditingTemplate = true
            }
            Divider()
            Button("Delete", role: .destructive) {
                deleteTemplate(template)
            }
        }
        .onTapGesture(count: 2) {
            applyTemplate(template)
        }
    }
    
    private var templateEditorSheet: some View {
        VStack(spacing: 16) {
            Text(editingTemplate.name.isEmpty ? "New Template" : "Edit Template")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 12) {
                metadataField("Template Name", text: $editingTemplate.name)
                metadataField("Headline", text: $editingTemplate.headline)
                metadataField("Caption", text: $editingTemplate.description, axis: .vertical)
                metadataField("Creator", text: $editingTemplate.creator)
                metadataField("Copyright", text: $editingTemplate.copyright)
            }
            
            HStack {
                Button("Cancel", role: .cancel) {
                    isEditingTemplate = false
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Save") {
                    saveTemplate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
    }
    
    // MARK: - Bindings
    
    private var headlineBinding: Binding<String> {
        Binding(
            get: { workspace.currentMetadata.headline ?? "" },
            set: { workspace.currentMetadata.headline = $0.isEmpty ? nil : $0 }
        )
    }
    
    private var descriptionBinding: Binding<String> {
        Binding(
            get: { workspace.currentMetadata.description ?? "" },
            set: { workspace.currentMetadata.description = $0.isEmpty ? nil : $0 }
        )
    }
    
    private var creatorBinding: Binding<String> {
        Binding(
            get: { workspace.currentMetadata.creator ?? "" },
            set: { workspace.currentMetadata.creator = $0.isEmpty ? nil : $0 }
        )
    }
    
    private var copyrightBinding: Binding<String> {
        Binding(
            get: { workspace.currentMetadata.copyright ?? "" },
            set: { workspace.currentMetadata.copyright = $0.isEmpty ? nil : $0 }
        )
    }
    
    // MARK: - Actions
    
    private func saveCurrentMetadata() {
        guard let photo = workspace.currentPhoto else { return }
        guard workspace.canWriteMetadata(to: photo) else { return }
        let sidecarURL = workspace.metadataSidecarURL(for: photo)
        let metadata = workspace.currentMetadata
        workspace.cacheMetadata(metadata, for: photo)
        
        let sidecar = workspace.sidecarManager
        Task.detached {
            do {
                try sidecar.write(metadata, to: sidecarURL)
            } catch {
                print("Failed to write sidecar \(sidecarURL.path): \(error)")
            }
        }
    }
    
    private func applyTemplate(_ template: MetadataTemplate) {
        let selectedPhotos = workspace.photos.filter { workspace.selection.contains($0.id) && workspace.canWriteMetadata(to: $0) }
        let sidecar = workspace.sidecarManager
        
        for photo in selectedPhotos {
            let sidecarURL = workspace.metadataSidecarURL(for: photo)
            var metadata = workspace.metadataCache[photo.id] ?? (try? sidecar.read(from: sidecarURL)) ?? PhotoMetadata()
            metadata = template.apply(to: metadata)
            workspace.cacheMetadata(metadata, for: photo)
            
            if photo.id == workspace.currentPhoto?.id {
                workspace.currentMetadata = metadata
            }
            
            Task.detached {
                do {
                    try sidecar.write(metadata, to: sidecarURL)
                } catch {
                    print("Failed to write sidecar \(sidecarURL.path): \(error)")
                }
            }
        }
    }
    
    private func saveTemplate() {
        if let idx = templates.firstIndex(where: { $0.id == editingTemplate.id }) {
            templates[idx] = editingTemplate
        } else {
            templates.append(editingTemplate)
        }
        templateManager.saveTemplates(templates)
        isEditingTemplate = false
    }
    
    private func deleteTemplate(_ template: MetadataTemplate) {
        templates.removeAll { $0.id == template.id }
        templateManager.saveTemplates(templates)
    }
    
    private func loadCodeReplacements() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Select a tab-separated code replacement file (.txt)"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                codeReplacementManager = try CodeReplacementManager.load(from: url)
                codeReplacementCount = codeReplacementManager?.count ?? 0
            } catch {
                print("Failed to load code replacements: \(error)")
            }
        }
    }
}
