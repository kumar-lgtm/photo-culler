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
    @State private var draft = PhotoMetadata()
    @State private var editorPhoto: PhotoItem?
    @State private var originalMetadata = PhotoMetadata()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    
    private let templateManager = TemplateManager()
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            
            Divider()
            
            if let photo = editorPhoto {
                currentMetadataSection(for: photo)
                    .disabled(isSaving)
            } else {
                ContentUnavailableView("No Photo Selected", systemImage: "photo", description: Text("Select a photo to edit its metadata."))
            }
            
            Divider()
            
            templateSection
                .disabled(isSaving)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding()
            }
        }
        .frame(minWidth: 400, idealWidth: 500, minHeight: 500)
        .task {
            templates = templateManager.loadTemplates()
        }
        .onAppear {
            editorPhoto = workspace.currentPhoto
            draft = workspace.currentMetadata
            originalMetadata = draft
        }
        .interactiveDismissDisabled(isSaving || draft != originalMetadata)
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
            
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Button(isSaving ? "Saving…" : "Save and close") {
                saveCurrentMetadata(closeAfterSaving: true)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(isSaving || editorPhoto == nil)
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
                        
                        if workspace.codeReplacementCount > 0 {
                            Text("\(workspace.codeReplacementCount) codes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(workspace.codeReplacementSourceURL?.lastPathComponent ?? "")
                        }
                        
                        Button("Load Codes", systemImage: "text.badge.plus") {
                            loadCodeReplacements()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Save", systemImage: "square.and.arrow.down") {
                            saveCurrentMetadata(closeAfterSaving: false)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isSaving || draft == originalMetadata)
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
                .foregroundStyle(.secondary)
            
            if axis == .vertical {
                TextField(label, text: text, axis: .vertical)
                    .accessibilityLabel(label)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        guard expandCodes else { return }
                        let expanded = workspace.expandCodes(in: newValue)
                        if expanded != newValue {
                            text.wrappedValue = expanded
                        }
                    }
            } else {
                TextField(label, text: text)
                    .accessibilityLabel(label)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        guard expandCodes else { return }
                        let expanded = workspace.expandCodes(in: newValue)
                        if expanded != newValue {
                            text.wrappedValue = expanded
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
                    editingTemplate = MetadataTemplate(name: "New Template", creator: draft.creator ?? "", copyright: draft.copyright ?? "")
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
            get: { draft.headline ?? "" },
            set: { draft.headline = $0.isEmpty ? nil : $0 }
        )
    }
    
    private var descriptionBinding: Binding<String> {
        Binding(
            get: { draft.description ?? "" },
            set: { draft.description = $0.isEmpty ? nil : $0 }
        )
    }
    
    private var creatorBinding: Binding<String> {
        Binding(
            get: { draft.creator ?? "" },
            set: { draft.creator = $0.isEmpty ? nil : $0 }
        )
    }
    
    private var copyrightBinding: Binding<String> {
        Binding(
            get: { draft.copyright ?? "" },
            set: { draft.copyright = $0.isEmpty ? nil : $0 }
        )
    }
    
    // MARK: - Actions
    
    private func saveCurrentMetadata(closeAfterSaving: Bool) {
        guard !isSaving, let photo = editorPhoto else { return }
        isSaving = true
        errorMessage = nil
        let metadata = draft
        Task {
            defer { isSaving = false }
            do {
                try await workspace.saveMetadata(metadata, for: photo)
                originalMetadata = metadata
                if closeAfterSaving { dismiss() }
            } catch {
                errorMessage = "Couldn’t finish saving metadata. \(error.localizedDescription) Check folder access and try Save again."
            }
        }
    }

    private func applyTemplate(_ template: MetadataTemplate) {
        let targets = workspace.applyTemplate(template)
        if let editorPhoto, targets.contains(workspace.metadataSidecarURL(for: editorPhoto)) {
            draft = template.apply(to: draft)
            originalMetadata = template.apply(to: originalMetadata)
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
                // Stored on the view model, not this sheet's @State — closing the editor
                // used to discard the loaded roster every single time.
                try workspace.loadCodeReplacements(from: url)
            } catch {
                errorMessage = "Couldn’t load this code file. \(error.localizedDescription) Choose another file."
            }
        }
    }
}
