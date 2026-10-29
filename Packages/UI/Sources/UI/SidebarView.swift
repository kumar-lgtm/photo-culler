import SwiftUI
import Catalog

struct SidebarView: View {
    @ObservedObject var workspace: WorkspaceViewModel
    /// Observed directly — `FolderManager` is now an `ObservableObject`, so opening a folder
    /// actually redraws the Recents list instead of waiting for some unrelated republish.
    @ObservedObject var folderManager: FolderManager
    @State private var searchText: String = ""
    @State private var showKeyboardShortcuts = false

    private var filteredRecents: [BookmarkFolder] {
        guard !searchText.isEmpty else { return folderManager.recents }
        return folderManager.recents.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredFavorites: [BookmarkFolder] {
        guard !searchText.isEmpty else { return folderManager.favorites }
        return folderManager.favorites.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section("Recent folders") {
                if filteredRecents.isEmpty {
                    Text(emptyRecentsLabel)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(filteredRecents, id: \.id) { recent in
                        Button(action: {
                            openBookmark(recent)
                        }) {
                            Label(recent.name, systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .help(recent.path)
                    }
                }
            }

            Section("Favorites") {
                if filteredFavorites.isEmpty {
                    Text(emptyFavoritesLabel)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(filteredFavorites, id: \.id) { fav in
                        Button(action: {
                            openBookmark(fav)
                        }) {
                            Label(fav.name, systemImage: "star")
                        }
                        .buttonStyle(.plain)
                        .help(fav.path)
                    }
                }
            }
            
            Section {
                DisclosureGroup("Keyboard shortcuts", isExpanded: $showKeyboardShortcuts) {
                VStack(alignment: .leading, spacing: 6) {
                    ShortcutRow(key: "Cmd+O", action: "Open Folder")
                    ShortcutRow(key: "Cmd+R", action: "Batch Rename")
                    ShortcutRow(key: "Arrows / Space", action: "Navigate")
                    ShortcutRow(key: "Shift+C", action: "Add to Selection")
                    ShortcutRow(key: "Escape", action: "Clear Selection")
                    ShortcutRow(key: "1-5", action: "Rate")
                    ShortcutRow(key: "0", action: "Clear Rating")
                    ShortcutRow(key: "Cmd+1-8", action: "Set Color")
                    ShortcutRow(key: "`", action: "Clear Color")
                    ShortcutRow(key: "P / X / U", action: "Pick / Reject / Unflag")
                    ShortcutRow(key: "E/G/C", action: "Loupe/Grid/Compare")
                    ShortcutRow(key: "Tab (Compare)", action: "Cycle compare pane")
                    ShortcutRow(key: "Z", action: "Face Zoom")
                    ShortcutRow(key: "F", action: "100% / Fit")
                    ShortcutRow(key: "Double Click", action: "Zoom")
                    ShortcutRow(key: "W/A/S/D", action: "Pan Image")
                    ShortcutRow(key: "Cmd+I", action: "Toggle Inspector")
                    ShortcutRow(key: "Cmd+0", action: "Toggle Sidebar")
                }
                .padding(.vertical, 4)
                }
            }
            
            Section("Filters") {
                Toggle(isOn: $workspace.filterSettings.hideRejects) {
                    Label("Hide rejects", systemImage: "flag.slash")
                        .font(.body)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .help("Hide photos flagged as rejects (X) from all views.")
            }

            Section("Appearance") {
                Toggle(isOn: $workspace.isBeigeMode) {
                    Label("Beige mode", systemImage: "sparkles")
                        .font(.body)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .help("Use a warm, light appearance.")
            }
        }
        .scrollContentBackground(workspace.isBeigeMode ? .hidden : .visible)
        .background(workspace.isBeigeMode ? Color(red: 0.96, green: 0.94, blue: 0.91) : .clear)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter folders")
    }

    private var emptyRecentsLabel: String {
        if !searchText.isEmpty { return "No folders match “\(searchText)”" }
        return "No recent folders"
    }

    private var emptyFavoritesLabel: String {
        if !searchText.isEmpty { return "No favorites match “\(searchText)”" }
        return "No favorites yet"
    }

    private func openBookmark(_ folder: BookmarkFolder) {
        let (url, isStale) = folder.resolve()
        if isStale {
            // Re-record the bookmark so it keeps resolving after the folder moves or the
            // machine reboots, instead of silently degrading to a raw path.
            folderManager.refreshBookmark(for: folder, resolvedURL: url)
        }
        Task {
            await workspace.openFolder(url)
        }
    }
}
