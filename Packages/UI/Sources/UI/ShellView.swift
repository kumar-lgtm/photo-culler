import SwiftUI
import Catalog
import Decode
import Sidecar
import Rename
import Ingest

public struct ShellView: View {
    @StateObject private var workspace: WorkspaceViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorVisible: Bool = true
    @State private var showRenameModal: Bool = false
    @State private var showMetadataEditor: Bool = false
    @State private var showIngestView: Bool = false
    
    public init(workspace: WorkspaceViewModel) {
        _workspace = StateObject(wrappedValue: workspace)
    }
    
    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(workspace: workspace, folderManager: workspace.folderManager)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            MainViewerView(workspace: workspace)
                .inspector(isPresented: $inspectorVisible) {
                    InspectorView(workspace: workspace)
                        .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
                }
        }
        // Give the sidebar, viewer and inspector a viable initial layout. An unconstrained
        // window can repeatedly invalidate AppKit constraints during its first layout.
        .frame(minWidth: 1000, minHeight: 700)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Open Folder", systemImage: "folder", action: openFolderPanel)
            }
            
            ToolbarItem(placement: .principal) {
                HStack(spacing: 20) {
                    Picker("View Mode", selection: $workspace.viewMode) {
                        Text("Loupe").tag(ViewMode.loupe)
                        Text("Compare").tag(ViewMode.compare)
                        Text("Grid").tag(ViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .help("Loupe (E), compare selected photos (C), or grid (G)")
                    
                    if workspace.viewMode == .grid {
                        HStack {
                            Image(systemName: "square.grid.2x2")
                            Slider(value: $workspace.gridScale, in: 80...400)
                                .frame(width: 100)
                                .accessibilityLabel("Thumbnail size")
                                .accessibilityValue("\(Int(workspace.gridScale)) points")
                            Image(systemName: "square.grid.3x3")
                        }
                        .controlSize(.small)
                    }
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Metadata Editor", systemImage: "tag") {
                    showMetadataEditor = true
                }
                .labelStyle(.iconOnly)
                .help(workspace.currentPhoto == nil ? "Select a photo to edit its metadata" : "Edit metadata")
                .disabled(workspace.currentPhoto == nil)
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Card Ingest", systemImage: "sdcard") {
                    showIngestView = true
                }
                .labelStyle(.iconOnly)
                .help("Copy photos from a card to working and backup folders")
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Batch Rename", systemImage: "character.cursor.ibeam") {
                    showRenameModal = true
                }
                .labelStyle(.iconOnly)
                .help(workspace.renamableSelection().isEmpty ? "Select photos to rename" : "Rename selected photos (⌘R)")
                .disabled(workspace.renamableSelection().isEmpty)
            }
        }
        .sheet(isPresented: $showRenameModal) {
            RenameModal(workspace: workspace)
        }
        .sheet(isPresented: $showMetadataEditor) {
            MetadataEditorView(workspace: workspace)
        }
        .sheet(isPresented: $showIngestView) {
            IngestView(workspace: workspace)
        }
        .environmentObject(workspace)
        .overlay {
            if let hud = workspace.activeHUD {
                HUDView(message: hud)
                    .allowsHitTesting(false)
                    .zIndex(100)
            }
        }
        .onReceive(workspace.shortcutManager.actionPublisher) { action in
            switch action {
            case .openFolder:
                openFolderPanel()
            case .openRenameModal:
                if !workspace.renamableSelection().isEmpty { showRenameModal = true }
            case .toggleSidebar:
                columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
            case .toggleInspector:
                inspectorVisible.toggle()
            default:
                break
            }
        }
        .tint(workspace.isBeigeMode ? Color(red: 0.38, green: 0.29, blue: 0.22) : nil)
        .preferredColorScheme(workspace.isBeigeMode ? .light : nil)
        .fontDesign(workspace.isBeigeMode ? .serif : .default)
        .task {
            workspace.restoreCodeReplacements()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Queued sidecar writes must land before the process goes away. The app no
            // longer advertises sudden termination, so this window actually exists.
            let coordinator = workspace.writeCoordinator
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await coordinator.flush()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
        }
    }
    
    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await workspace.openFolder(url)
            }
        }
    }
}
