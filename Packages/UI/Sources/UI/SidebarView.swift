import SwiftUI
import Catalog

struct SidebarView: View {
    @ObservedObject var workspace: WorkspaceViewModel
    @State private var searchText: String = ""
    
    var body: some View {
        List {
            Section(workspace.isBeigeMode ? "recent spaces" : "Recent Folders") {
                if workspace.folderManager.recents.isEmpty {
                    Text(workspace.isBeigeMode ? "no spaces yet..." : "No recent folders")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(workspace.folderManager.recents, id: \.id) { recent in
                        Button(action: {
                            openBookmark(recent)
                        }) {
                            Label(workspace.isBeigeMode ? recent.name.lowercased() : recent.name, systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            Section(workspace.isBeigeMode ? "curated favorites" : "Favorites") {
                if workspace.folderManager.favorites.isEmpty {
                    Text(workspace.isBeigeMode ? "waiting to be curated..." : "No favorites yet")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(workspace.folderManager.favorites, id: \.id) { fav in
                        Button(action: {
                            openBookmark(fav)
                        }) {
                            Label(workspace.isBeigeMode ? fav.name.lowercased() : fav.name, systemImage: "star")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            Section(workspace.isBeigeMode ? "mindful shortcuts" : "Keyboard Shortcuts") {
                VStack(alignment: .leading, spacing: 6) {
                    ShortcutRow(key: "Cmd+O", action: workspace.isBeigeMode ? "open space" : "Open Folder")
                    ShortcutRow(key: "Cmd+R", action: workspace.isBeigeMode ? "rename aesthetics" : "Batch Rename")
                    ShortcutRow(key: "Arrows / Space", action: workspace.isBeigeMode ? "breathe & navigate" : "Navigate")
                    ShortcutRow(key: "Shift+C", action: workspace.isBeigeMode ? "add to moodboard" : "Add to Selection")
                    ShortcutRow(key: "Escape", action: workspace.isBeigeMode ? "let go" : "Clear Selection")
                    ShortcutRow(key: "1-5", action: workspace.isBeigeMode ? "curate rating" : "Rate")
                    ShortcutRow(key: "0", action: workspace.isBeigeMode ? "clear mind" : "Clear Rating")
                    ShortcutRow(key: "Cmd+1-8", action: workspace.isBeigeMode ? "color energy" : "Set Color")
                    ShortcutRow(key: "`", action: workspace.isBeigeMode ? "clear energy" : "Clear Color")
                    ShortcutRow(key: "P / X / U", action: workspace.isBeigeMode ? "keep / cut / reset" : "Pick / Reject / Unflag")
                    ShortcutRow(key: "E/G/C", action: workspace.isBeigeMode ? "focus/grid/moodboard" : "Loupe/Grid/Compare")
                    ShortcutRow(key: "Tab", action: workspace.isBeigeMode ? "next in moodboard" : "Cycle Compare Pane")
                    ShortcutRow(key: "Z", action: workspace.isBeigeMode ? "focus in" : "Face Zoom")
                    ShortcutRow(key: "F", action: workspace.isBeigeMode ? "true detail" : "100% / Fit")
                    ShortcutRow(key: "Double Click", action: workspace.isBeigeMode ? "get closer" : "Zoom")
                    ShortcutRow(key: "W/A/S/D", action: workspace.isBeigeMode ? "drift" : "Pan Image")
                    ShortcutRow(key: "Cmd+I", action: workspace.isBeigeMode ? "toggle vibe check" : "Toggle Inspector")
                    ShortcutRow(key: "Cmd+0", action: workspace.isBeigeMode ? "toggle spaces" : "Toggle Sidebar")
                }
                .padding(.vertical, 4)
            }
            
            Section(workspace.isBeigeMode ? "winnow" : "Filters") {
                Toggle(isOn: $workspace.filterSettings.hideRejects) {
                    Label(workspace.isBeigeMode ? "hide what you let go" : "Hide Rejects", systemImage: "flag.slash")
                        .font(.body)
                }
                .toggleStyle(.switch)
                .help("Hide photos flagged as rejects (X) from all views.")
            }

            Section(workspace.isBeigeMode ? "vibes" : "Aesthetics") {
                Toggle(isOn: workspace.$isBeigeMode) {
                    Label(workspace.isBeigeMode ? "minimalist luxe ✨" : "Minimalist Luxe (Beige)", systemImage: workspace.isBeigeMode ? "heart.fill" : "sparkles")
                        .font(.body)
                }
                .toggleStyle(.switch)
                .help("Enable clean UI, scandi-beige, tongue-in-cheek aesthetic.")
            }
        }
        .scrollContentBackground(workspace.isBeigeMode ? .hidden : .visible)
        .background(workspace.isBeigeMode ? Color(red: 0.96, green: 0.94, blue: 0.91) : .clear)
        .searchable(text: $searchText, placement: .sidebar)
    }
    
    private func openBookmark(_ folder: BookmarkFolder) {
        Task {
            await workspace.openFolder(folder.url)
        }
    }
}
