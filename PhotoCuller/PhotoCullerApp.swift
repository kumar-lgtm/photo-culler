import SwiftUI
import Catalog
import Decode
import Sidecar
import Rename
import Shortcuts
import UI

@main
struct PhotoCullerApp: App {

    @StateObject private var workspace: WorkspaceViewModel

    init() {
        NSApplication.shared.setActivationPolicy(.regular)

        let scanner = CatalogScanner()
        let folderManager = FolderManager()
        let imageProvider = ImageProvider()
        let sidecarManager = SidecarManager()
        let shortcutManager = ShortcutManager()

        _workspace = StateObject(wrappedValue: WorkspaceViewModel(
            scanner: scanner,
            folderManager: folderManager,
            imageProvider: imageProvider,
            sidecarManager: sidecarManager,
            shortcutManager: shortcutManager
        ))
    }
    
    var body: some Scene {
        WindowGroup {
            ShellView(workspace: workspace)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
        }
    }
}
