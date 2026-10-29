import SwiftUI
import Catalog
import Sidecar
import Ingest

/// The form never silently drops an enabled option when its required value is missing.
public enum IngestSetupValidation {
    public static func message(source: URL?, primary: URL?, secondary: URL?, useSecondary: Bool,
                               applyTemplate: Bool, hasTemplate: Bool, useRename: Bool, renameTemplate: String) -> String? {
        guard let source else { return "Choose a source folder to import from." }
        guard let primary else { return "Choose a primary destination for your photos." }
        if useSecondary && secondary == nil { return "Choose a backup destination or turn off the secondary copy." }
        if applyTemplate && !hasTemplate { return "Choose a metadata template or turn off Apply metadata template." }
        if useRename && renameTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a rename template or turn off Rename during ingest."
        }
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let destinations = [primary] + (useSecondary ? secondary.map { [$0] } ?? [] : [])
        let paths = destinations.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        if Set(paths).count != paths.count { return "Choose different primary and backup destinations." }
        if paths.contains(where: { $0 == sourcePath || $0.hasPrefix(sourcePath == "/" ? "/" : sourcePath + "/") }) {
            return "Choose destinations outside the source folder so imported files aren’t scanned again."
        }
        return nil
    }
}

struct IngestView: View {
    @ObservedObject var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var sourceURL: URL?
    @State private var primaryDestURL: URL?
    @State private var secondaryDestURL: URL?
    @State private var useSecondary = false
    @State private var applyTemplate = false
    @State private var selectedTemplate: MetadataTemplate?
    @State private var renameTemplate: String = "{name}_{Sequence(0001)}"
    @State private var useRename = false
    @State private var templates: [MetadataTemplate] = []
    
    @State private var isIngesting = false
    @State private var progress: IngestProgress?
    @State private var result: IngestResult?
    @State private var errorMessage: String?
    @State private var ingestTask: Task<Void, Never>?
    
    private let templateManager = TemplateManager()
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            
            Divider()
            
            if let result {
                completionView(result)
            } else if isIngesting {
                progressView
            } else {
                configurationView
            }
        }
        .frame(minWidth: 500, idealWidth: 560, minHeight: 480)
        .task {
            templates = templateManager.loadTemplates()
        }
        .interactiveDismissDisabled(isIngesting)
        .onDisappear { ingestTask?.cancel() }
    }
    
    // MARK: - Header
    
    private var headerBar: some View {
        HStack {
            Text("Card Ingest")
                .font(.headline)
            
            Spacer()

            // A 128GB card import used to be unstoppable: the button was hidden while
            // ingesting and the sheet could not be dismissed.
            Button(isIngesting ? "Stop ingest" : "Close") {
                if isIngesting {
                    ingestTask?.cancel()
                } else {
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    // MARK: - Configuration
    
    private var configurationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Source
                Section {
                    folderPicker(label: "Source (Card)", url: $sourceURL, systemImage: "sdcard")
                } header: {
                    Text("Source")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                // Destinations
                Section {
                    folderPicker(label: "Primary Destination", url: $primaryDestURL, systemImage: "folder.fill")
                    
                    Toggle("Copy to secondary destination", isOn: $useSecondary)
                    
                    if useSecondary {
                        folderPicker(label: "Secondary Destination", url: $secondaryDestURL, systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Destinations")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                // Metadata
                Section {
                    Toggle("Apply metadata template", isOn: $applyTemplate)
                    
                    if applyTemplate {
                        if templates.isEmpty {
                            Text("No templates available. Create one in the Metadata Editor first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Template", selection: $selectedTemplate) {
                                Text("None").tag(nil as MetadataTemplate?)
                                ForEach(templates) { template in
                                    Text(template.name).tag(template as MetadataTemplate?)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Metadata")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                // Rename
                Section {
                    Toggle("Rename during ingest", isOn: $useRename)
                    
                    if useRename {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rename template").font(.callout.weight(.medium))
                            TextField("Rename template", text: $renameTemplate)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Ingest rename template")
                            
                            Text("Tokens: {Date(yyyyMMdd)}, {Sequence(001)}, {name}, {camera}, {year}, {ext}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Renaming")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("ingest-setup-guidance")
                }
                
                Divider()
                
                // Start Button
                HStack {
                    Spacer()
                    
                    Button {
                        startIngest()
                    } label: {
                        Label("Start Ingest", systemImage: "square.and.arrow.down.on.square")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canStartIngest)
                    
                    Spacer()
                }
                
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
    }
    
    // MARK: - Folder Picker
    
    private func folderPicker(label: String, url: Binding<URL?>, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.callout.weight(.medium))
                Text(url.wrappedValue?.path ?? "No folder chosen")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .help(url.wrappedValue?.path ?? label)
            }
            
            Spacer()
            
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.message = "Select \(label)"
                
                if panel.runModal() == .OK {
                    url.wrappedValue = panel.url
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Choose \(label)")
        }
        .padding(8)
        .background(.fill.quaternary)
        .clipShape(.rect(cornerRadius: 8))
    }
    
    // MARK: - Progress
    
    private var progressView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ProgressView(value: progress?.fraction ?? 0) {
                Text("Copying files…")
                    .font(.headline)
            } currentValueLabel: {
                if let p = progress {
                    Text("\(p.copiedFiles) / \(p.totalFiles) — \(p.currentFile)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)
            
            if let p = progress {
                Text(formatBytes(p.bytesCopied) + " / " + formatBytes(p.bytesTotal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Completion
    
    private func completionView(_ result: IngestResult) -> some View {
        VStack(spacing: 16) {
            Spacer()
            
            let hadProblems = result.destinationReports.contains { !$0.failed.isEmpty } || result.wasCancelled

            Image(systemName: hadProblems ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(hadProblems ? .orange : .green)

            Text(result.wasCancelled ? "Ingest stopped" : (hadProblems ? "Ingest needs attention" : (result.destinationReports.isEmpty ? "No supported files found" : "Ingest complete")))
                .font(.title2.weight(.semibold))
            
            VStack(spacing: 6) {
                // Per-destination, so an incomplete backup is visible instead of inferred
                // from the primary's numbers.
                ForEach(Array(result.destinationReports.enumerated()), id: \.offset) { index, report in
                    Text(report.destination.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(index == 0 ? "Primary" : "Backup")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("\(report.copied.count) copied")
                        if !report.skipped.isEmpty {
                            Text("· \(report.skipped.count) already there")
                                .foregroundStyle(.secondary)
                        }
                        if !report.failed.isEmpty {
                            Text("· \(report.failed.count) failed")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.callout)
                }

                Text("\(formatBytes(result.totalBytes)) in \(String(format: "%.1f", result.duration))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            
            Spacer()

            if let primary = primaryDestURL, !result.copiedFiles.isEmpty || !result.skippedFiles.isEmpty {
                Button("Open imported folder") {
                    dismiss()
                    Task { await workspace.openFolder(primary) }
                }
                .buttonStyle(.bordered)
            }
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Actions
    
    private var canStartIngest: Bool {
        validationMessage == nil
    }

    private var validationMessage: String? {
        IngestSetupValidation.message(source: sourceURL, primary: primaryDestURL, secondary: secondaryDestURL,
                                      useSecondary: useSecondary, applyTemplate: applyTemplate,
                                      hasTemplate: selectedTemplate != nil, useRename: useRename, renameTemplate: renameTemplate)
    }
    
    private func startIngest() {
        guard canStartIngest, let source = sourceURL, let primary = primaryDestURL else { return }
        
        errorMessage = nil
        isIngesting = true
        
        let job = IngestJob(
            sourceURL: source,
            primaryDestination: primary,
            secondaryDestination: useSecondary ? secondaryDestURL : nil,
            metadataTemplate: applyTemplate ? selectedTemplate : nil,
            renameTemplate: useRename && !renameTemplate.isEmpty ? renameTemplate : nil
        )
        
        let manager = IngestManager()
        // One shared box instead of a Task per file — 5,000 spawned tasks could also land
        // out of order and make the progress bar jump backwards.
        let relay = ProgressRelay()

        ingestTask = Task {
            let streamTask = Task { @MainActor in
                for await update in relay.stream {
                    self.progress = update
                }
            }
            defer { streamTask.cancel() }

            do {
                let ingestResult = try await manager.run(job: job) { p in
                    relay.send(p)
                }
                relay.finish()
                self.result = ingestResult
                self.isIngesting = false
            } catch is CancellationError {
                relay.finish()
                self.errorMessage = "Ingest stopped. Files already copied were left in place."
                self.isIngesting = false
            } catch {
                relay.finish()
                self.errorMessage = error.localizedDescription
                self.isIngesting = false
            }
        }
    }
    
    // MARK: - Helpers
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Funnels ingest progress into a single stream that keeps only the newest value.
///
/// The previous code spawned one `Task { @MainActor in ... }` per file, which for a few
/// thousand files meant thousands of tasks whose completion order wasn't guaranteed — so
/// the progress bar could jump backwards.
final class ProgressRelay: @unchecked Sendable {
    let stream: AsyncStream<IngestProgress>
    private let continuation: AsyncStream<IngestProgress>.Continuation

    init() {
        var captured: AsyncStream<IngestProgress>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured
    }

    func send(_ progress: IngestProgress) { continuation.yield(progress) }
    func finish() { continuation.finish() }
}
