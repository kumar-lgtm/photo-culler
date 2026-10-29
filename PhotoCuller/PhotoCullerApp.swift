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
        #if DEBUG
        if CommandLine.arguments.contains("--ui-qa-output") {
            guard Bundle.main.bundleIdentifier == "com.braveenkumar.photoculler.designqa" else {
                fatalError("Native UI QA requires the isolated bundle created by scripts/qa-ui.sh")
            }
            UserDefaults.standard.removeObject(forKey: "PhotoCuller_RecentFolders_v2")
            UserDefaults.standard.removeObject(forKey: "isBeigeMode")
        }
        #endif
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
                    #if DEBUG
                    if let index = CommandLine.arguments.firstIndex(of: "--ui-qa-output"), index + 1 < CommandLine.arguments.count {
                        Task { await NativeUIQA.run(workspace: workspace, output: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
                    }
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            SidebarCommands()
        }
    }
}
