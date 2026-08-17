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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Open Folder", systemImage: "folder", action: openFolderPanel)
            }
            
            ToolbarItem(placement: .principal) {
                HStack(spacing: 20) {
                    Picker("View Mode", selection: $workspace.viewMode) {
                        Image(systemName: "rectangle.grid.1x2.fill").tag(ViewMode.loupe)
                        Image(systemName: "rectangle.split.2x1.fill").tag(ViewMode.compare)
                        Image(systemName: "square.grid.3x2.fill").tag(ViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    
                    if workspace.viewMode == .grid {
                        HStack {
                            Image(systemName: "square.grid.2x2")
                            Slider(value: $workspace.gridScale, in: 80...400)
                                .frame(width: 100)
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
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Card Ingest", systemImage: "sdcard") {
                    showIngestView = true
                }
                .labelStyle(.iconOnly)
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Batch Rename", systemImage: "character.cursor.ibeam") {
                    showRenameModal = true
                }
                .labelStyle(.iconOnly)
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
                    .zIndex(100)
            }
        }
        .onReceive(workspace.shortcutManager.actionPublisher) { action in
            switch action {
            case .openFolder:
                openFolderPanel()
            case .openRenameModal:
                showRenameModal = true
            case .toggleSidebar:
                columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
            case .toggleInspector:
                inspectorVisible.toggle()
            default:
                break
            }
        }
        .tint(workspace.isBeigeMode ? Color(red: 0.65, green: 0.55, blue: 0.45) : nil)
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
