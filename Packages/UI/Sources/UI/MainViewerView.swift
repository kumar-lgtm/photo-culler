import SwiftUI
import Catalog
import Decode
import Sidecar
import AVKit

/// Shared label → colour mapping (was duplicated in three views).
func colorForLabel(_ label: ColorLabel) -> Color {
    switch label {
    case .red: return .red
    case .yellow: return .yellow
    case .green: return .green
    case .blue: return .blue
    case .purple: return .purple
    case .orange: return .orange
    case .cyan: return .cyan
    case .magenta: return .pink
    case .none: return .clear
    }
}

struct MainViewerView: View {
    @ObservedObject var workspace: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Main Content Area
            ZStack {
                if workspace.isBeigeMode {
                    Color(red: 0.96, green: 0.94, blue: 0.91)
                } else {
                    Color(NSColor.underPageBackgroundColor)
                }

                if workspace.isScanning && workspace.photos.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(workspace.isBeigeMode ? "gathering your images..." : "Scanning folder…")
                            .foregroundStyle(.secondary)
                    }
                } else if workspace.photos.isEmpty {
                    emptyState
                } else {
                    switch workspace.viewMode {
                    case .loupe:
                        LoupeView(workspace: workspace)
                    case .grid:
                        GeometryReader { proxy in
                            GridView(workspace: workspace, width: proxy.size.width)
                        }
                    case .compare:
                        CompareView(workspace: workspace)
                    }
                }
            }

            Divider()

            // Filmstrip (always visible)
            FilmstripView(workspace: workspace)
                .frame(height: 120)
                .background(workspace.isBeigeMode ? Color(red: 0.94, green: 0.92, blue: 0.88) : Color(NSColor.windowBackgroundColor))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: workspace.isBeigeMode ? "sparkles" : "photo.on.rectangle.angled")
                .font(.system(size: 80))
                .foregroundStyle(workspace.isBeigeMode ? AnyShapeStyle(Color(red: 0.8, green: 0.7, blue: 0.6)) : AnyShapeStyle(.tertiary))

            VStack(spacing: 8) {
                Text(workspace.isBeigeMode ? "welcome to photo culler ✨" : "Welcome to Photo Culler")
                    .font(workspace.isBeigeMode ? .custom("Times", size: 36).italic() : .largeTitle)
                    .fontWeight(.bold)
                Text(workspace.isBeigeMode ? "mindful, slow, intentional photo selection." : "Fast, focused photo culling and selection.")
                    .font(workspace.isBeigeMode ? .title3.italic() : .title3)
                    .foregroundStyle(workspace.isBeigeMode ? Color(red: 0.5, green: 0.45, blue: 0.4) : .secondary)
            }

            Button {
                workspace.shortcutManager.actionPublisher.send(.openFolder)
            } label: {
                Label(workspace.isBeigeMode ? "open a folder..." : "Open Folder...", systemImage: workspace.isBeigeMode ? "heart.fill" : "folder.badge.plus")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 12) {
                Text(workspace.isBeigeMode ? "mindful tips:" : "Quick Tips:")
                    .font(.headline)
                    .foregroundStyle(workspace.isBeigeMode ? Color(red: 0.5, green: 0.45, blue: 0.4) : .secondary)
                    .padding(.top, 16)

                ShortcutRow(key: "← / →", action: workspace.isBeigeMode ? "breathe & navigate" : "Navigate photos")
                ShortcutRow(key: "1-5", action: workspace.isBeigeMode ? "curate rating" : "Rate photo")
                ShortcutRow(key: "⇧C", action: workspace.isBeigeMode ? "add to moodboard" : "Add to selection & advance")
                ShortcutRow(key: "C", action: workspace.isBeigeMode ? "compare aesthetics" : "Compare selected")
                ShortcutRow(key: "Esc", action: workspace.isBeigeMode ? "let go (clear)" : "Clear selection")
            }
            .padding(24)
            .background(workspace.isBeigeMode ? AnyShapeStyle(Color.white.opacity(0.4)) : AnyShapeStyle(.regularMaterial))
            .clipShape(RoundedRectangle(cornerRadius: workspace.isBeigeMode ? 24 : 12, style: .continuous))
            .shadow(color: workspace.isBeigeMode ? Color(red: 0.6, green: 0.5, blue: 0.4).opacity(0.15) : .black.opacity(0.1), radius: 15, y: 8)
        }
        .padding()
    }
}

struct LoupeView: View {
    @ObservedObject var workspace: WorkspaceViewModel
    @State private var currentImage: CGImage?
    @State private var imageLoadFinished: Bool = false
    @State private var fullQualityLoaded: Bool = false
    @StateObject private var zoomState = ZoomState()
    @State private var loadTask: Task<Void, Never>?
    @State private var fullQualityTask: Task<Void, Never>?
    @State private var faceZoomIndex: Int = 0
    @State private var faceZoomActive: Bool = false
    @State private var videoPlayer: AVPlayer?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let photo = workspace.currentPhoto, photo.isVideo {
                    CustomVideoPlayer(player: videoPlayer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                } else if let cgImage = currentImage {
                    Image(cgImage, scale: 1.0, label: Text(workspace.currentPhoto?.url.lastPathComponent ?? "Photo"))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width * zoomState.scale, height: proxy.size.height * zoomState.scale)
                        .offset(zoomState.offset)

                    VStack {
                        HStack {
                            Spacer()
                            Text(fullQualityLoaded ? "Full quality" : "Preview")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: .capsule)
                                .padding(12)
                        }
                        Spacer()
                    }
                } else if imageLoadFinished, let photo = workspace.currentPhoto {
                    VStack(spacing: 12) {
                        Image(systemName: "doc")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text(photo.url.lastPathComponent)
                            .font(.headline)
                        Text("Preview unavailable")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    ProgressView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        faceZoomActive = false   // manual zoom ends any face-zoom session
                        zoomState.scale = zoomState.lastScale * value
                        if zoomState.scale > 1.25 {
                            loadFullQualityIfNeeded()
                        }
                    }
                    .onEnded { _ in
                        zoomState.lastScale = zoomState.scale
                    }
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        zoomState.offset = CGSize(
                            width: zoomState.lastOffset.width + value.translation.width,
                            height: zoomState.lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        zoomState.lastOffset = zoomState.offset
                    }
            )
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                faceZoomActive = false   // manual zoom ends any face-zoom session
                withAnimation(.spring()) {
                    if zoomState.scale > 1.0 {
                        zoomState.reset()
                    } else {
                        let targetScale: CGFloat = 3.0
                        let viewCX = proxy.size.width / 2.0
                        let viewCY = proxy.size.height / 2.0

                        let offsetX = (1.0 - targetScale) * (location.x - viewCX)
                        let offsetY = (1.0 - targetScale) * (location.y - viewCY)

                        zoomState.scale = targetScale
                        zoomState.lastScale = targetScale
                        zoomState.offset = CGSize(width: offsetX, height: offsetY)
                        zoomState.lastOffset = zoomState.offset
                        loadFullQualityIfNeeded()
                    }
                }
            }
            // Keyed on identity, not index: re-sorting or filtering can put a *different*
            // photo at the same index, which used to leave the previous image on screen.
            .onChange(of: workspace.currentPhoto?.id) { _, _ in
                zoomState.reset()
                faceZoomActive = false
                loadImage(viewSize: proxy.size)
            }
            .task {
                loadImage(viewSize: proxy.size)
            }
            .onDisappear {
                loadTask?.cancel()
                fullQualityTask?.cancel()
                videoPlayer?.pause()
            }
            .onReceive(workspace.shortcutManager.actionPublisher) { action in
                switch action {
                case .toggleFaceZoom:
                    toggleFaceZoom(proxy: proxy)
                case .toggleActualSize:
                    toggleActualSize(proxy: proxy)
                case .panUp:
                    pan(dx: 0, dy: 100)
                case .panDown:
                    pan(dx: 0, dy: -100)
                case .panLeft:
                    pan(dx: 100, dy: 0)
                case .panRight:
                    pan(dx: -100, dy: 0)
                default:
                    break
                }
            }
        }
        .padding(1)
        .border(Color.secondary.opacity(0.3), width: 1)
        .padding()
    }

    private func pan(dx: CGFloat, dy: CGFloat) {
        guard zoomState.scale > 1.0 else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            zoomState.offset.width += dx
            zoomState.offset.height += dy
            zoomState.lastOffset = zoomState.offset
        }
        loadFullQualityIfNeeded()
    }

    /// Toggles between fit and ~100% (one image pixel per point) for tack-sharpness checks.
    private func toggleActualSize(proxy: GeometryProxy) {
        guard let cgImage = currentImage else { return }
        loadFullQualityIfNeeded()
        withAnimation(.spring()) {
            if zoomState.scale > 1.0 {
                zoomState.reset()
            } else {
                let iw = CGFloat(cgImage.width)
                let ih = CGFloat(cgImage.height)
                guard iw > 0, ih > 0 else { return }
                let fitScale = min(proxy.size.width / iw, proxy.size.height / ih)
                guard fitScale > 0 else { return }
                let targetScale = max(1.0, 1.0 / fitScale)
                zoomState.scale = targetScale
                zoomState.lastScale = targetScale
                zoomState.offset = .zero
                zoomState.lastOffset = .zero
                faceZoomIndex = 0
            }
        }
    }

    private func toggleFaceZoom(proxy: GeometryProxy) {
        guard let photo = workspace.currentPhoto,
              let cgImage = currentImage else { return }

        loadFullQualityIfNeeded()

        if let faces = workspace.faceDataCache[photo.id] {
            applyFaceZoom(faces: faces, cgImage: cgImage, proxy: proxy)
        } else {
            // Face detection now runs only when Z is actually pressed. Running it eagerly on
            // a 3200px preview for every photo you landed on cost 100–300ms of CPU per
            // navigation and starved the decode pipeline while arrowing through a shoot.
            let targetID = photo.id
            Task {
                let faces = await ImageAnalyzer.shared.detectFaces(in: cgImage)
                await MainActor.run {
                    workspace.faceDataCache[targetID] = faces
                    guard workspace.currentPhoto?.id == targetID else { return }
                    applyFaceZoom(faces: faces, cgImage: cgImage, proxy: proxy)
                }
            }
        }
    }

    private func applyFaceZoom(faces: [FaceData], cgImage: CGImage, proxy: GeometryProxy) {
        withAnimation(.spring()) {
            // No faces detected → fall back to a centered punch-in so Z still does something.
            guard !faces.isEmpty else {
                if faceZoomActive || zoomState.scale > 1.0 {
                    zoomState.reset()
                } else {
                    zoomState.scale = 2.5
                    zoomState.lastScale = 2.5
                    zoomState.offset = .zero
                    zoomState.lastOffset = .zero
                }
                faceZoomActive = false
                faceZoomIndex = 0
                return
            }

            if faceZoomActive {
                faceZoomIndex += 1
                if faceZoomIndex >= faces.count {
                    zoomState.reset()
                    faceZoomActive = false
                    faceZoomIndex = 0
                    return
                }
            } else {
                faceZoomActive = true
                faceZoomIndex = 0
            }

            let faceRect = faces[faceZoomIndex].boundingBox

            let iw = CGFloat(cgImage.width)
            let ih = CGFloat(cgImage.height)
            guard iw > 0, ih > 0 else { return }
            let fitScale = min(proxy.size.width / iw, proxy.size.height / ih)
            let rw = iw * fitScale
            let rh = ih * fitScale

            let renderedFaceHeight = max(faceRect.height * rh, 1)
            let targetScale = min(max((0.55 * proxy.size.height) / renderedFaceHeight, 1.8), 8.0)

            let offsetX = -targetScale * (faceRect.midX - 0.5) * rw
            let offsetY = -targetScale * (0.5 - faceRect.midY) * rh

            zoomState.scale = targetScale
            zoomState.lastScale = targetScale
            zoomState.offset = CGSize(width: offsetX, height: offsetY)
            zoomState.lastOffset = zoomState.offset
        }
    }

    private func loadImage(viewSize: CGSize) {
        loadTask?.cancel()
        fullQualityTask?.cancel()

        guard let photo = workspace.currentPhoto else {
            currentImage = nil
            imageLoadFinished = false
            fullQualityLoaded = false
            videoPlayer = nil
            return
        }

        currentImage = nil
        imageLoadFinished = false
        fullQualityLoaded = false
        fullQualityTask = nil
        videoPlayer = photo.isVideo ? AVPlayer(url: photo.url) : nil

        guard !photo.isVideo else {
            imageLoadFinished = true
            return
        }

        loadTask = Task {
            let ref = PhotoRef(id: photo.id, url: photo.url, pairedURL: photo.pairedURL)

            // Load thumbnail first for instant feedback
            if let thumb = await workspace.imageProvider.image(for: ref, tier: .thumbnail),
               workspace.currentPhoto?.id == photo.id {
                currentImage = thumb
            }

            guard !Task.isCancelled else { return }

            if let preview = await workspace.imageProvider.image(for: ref, tier: .preview),
               workspace.currentPhoto?.id == photo.id {
                currentImage = preview

                // Only escalate to native resolution when the preview would actually be
                // upscaled on this display. Decoding full-res for every non-RAW photo while
                // browsing cost ~200MB per 50MP JPEG on every navigation.
                let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                let neededPixels = max(viewSize.width, viewSize.height) * scale
                if CGFloat(max(preview.width, preview.height)) < neededPixels {
                    loadFullQualityIfNeeded()
                }
            }

            guard !Task.isCancelled else { return }

            if workspace.currentPhoto?.id == photo.id {
                imageLoadFinished = true
            }
        }
    }

    private func loadFullQualityIfNeeded() {
        guard fullQualityTask == nil,
              !fullQualityLoaded,
              let photo = workspace.currentPhoto,
              !photo.isVideo else { return }

        fullQualityTask = Task {
            let ref = PhotoRef(id: photo.id, url: photo.url, pairedURL: photo.pairedURL)
            let full = await workspace.imageProvider.image(for: ref, tier: .full)

            // Always clear the slot, so a failed or superseded decode doesn't permanently
            // block later attempts to escalate quality.
            defer { fullQualityTask = nil }

            guard !Task.isCancelled,
                  workspace.currentPhoto?.id == photo.id,
                  let full else { return }

            currentImage = full
            fullQualityLoaded = true
        }
    }
}

struct GridView: View {
    @ObservedObject var workspace: WorkspaceViewModel
    let width: CGFloat

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: workspace.gridScale, maximum: workspace.gridScale * 1.5))], spacing: 16) {
                ForEach(workspace.photos, id: \.id) { photo in
                    thumbnail(for: photo)
                        .onTapGesture {
                            handleSelection(for: photo)
                        }
                }
            }
            .padding()
        }
        .onChange(of: width) { _, new in updateColumns(new) }
        .onChange(of: workspace.gridScale) { _, _ in updateColumns(width) }
        .onAppear { updateColumns(width) }
    }

    /// Values are passed as plain `let`s so each tile only re-renders when *its own* state
    /// changes. Handing every tile the whole view model meant one arrow key invalidated
    /// every visible thumbnail in the grid and the filmstrip at once.
    private func thumbnail(for photo: PhotoItem) -> some View {
        ThumbnailView(
            photo: photo,
            metadata: workspace.metadataCache[photo.id],
            isSelected: workspace.selection.contains(photo.id),
            isFocused: workspace.currentPhoto?.id == photo.id,
            selectionCount: workspace.selection.count,
            // The slider drove column width only, so thumbnails stayed 100pt tall no matter
            // where you put it.
            height: workspace.gridScale * 0.72,
            imageProvider: workspace.imageProvider,
            onOpenPreview: { workspace.openInPreview(photo) },
            onRevealInFinder: { workspace.revealInFinder(photo) }
        )
    }

    private func updateColumns(_ w: CGFloat) {
        let cols = max(1, Int((w + 16) / (workspace.gridScale + 16)))
        if workspace.gridColumnsCount != cols {
            Task { @MainActor in
                workspace.gridColumnsCount = cols
            }
        }
    }

    private func handleSelection(for photo: PhotoItem) {
        applyThumbnailSelection(photo: photo, workspace: workspace)
    }
}

struct FilmstripView: View {
    @ObservedObject var workspace: WorkspaceViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(workspace.photos, id: \.id) { photo in
                        ThumbnailView(
                            photo: photo,
                            metadata: workspace.metadataCache[photo.id],
                            isSelected: workspace.selection.contains(photo.id),
                            isFocused: workspace.currentPhoto?.id == photo.id,
                            selectionCount: workspace.selection.count,
                            height: 100,
                            imageProvider: workspace.imageProvider,
                            onOpenPreview: { workspace.openInPreview(photo) },
                            onRevealInFinder: { workspace.revealInFinder(photo) }
                        )
                        .id(photo.id)
                        .onTapGesture {
                            applyThumbnailSelection(photo: photo, workspace: workspace)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            .onChange(of: workspace.currentPhotoIndex) { _, newValue in
                guard let idx = newValue, idx >= 0, idx < workspace.photos.count else { return }
                withAnimation {
                    proxy.scrollTo(workspace.photos[idx].id, anchor: .center)
                }
            }
        }
    }
}

/// Shared click behaviour for grid and filmstrip tiles (was duplicated verbatim).
@MainActor
func applyThumbnailSelection(photo: PhotoItem, workspace: WorkspaceViewModel) {
    let isCommandDown = NSEvent.modifierFlags.contains(.command)
    let isShiftDown = NSEvent.modifierFlags.contains(.shift)

    if isCommandDown {
        if workspace.selection.contains(photo.id) {
            workspace.selection.remove(photo.id)
        } else {
            workspace.selection.insert(photo.id)
        }
    } else if isShiftDown, let currentIdx = workspace.currentPhotoIndex,
              let targetIdx = workspace.photos.firstIndex(of: photo) {
        let minIdx = min(currentIdx, targetIdx)
        let maxIdx = max(currentIdx, targetIdx)
        workspace.selection = Set(workspace.photos[minIdx...maxIdx].map { $0.id })
    } else if workspace.viewMode == .compare {
        // In compare mode, plain click just changes focus
    } else {
        workspace.isCollectingSelection = false
        workspace.selection = [photo.id]
    }

    if let idx = workspace.photos.firstIndex(of: photo) {
        workspace.currentPhotoIndex = idx
    }
}

struct ThumbnailView: View {
    let photo: PhotoItem
    let metadata: PhotoMetadata?
    let isSelected: Bool
    let isFocused: Bool
    let selectionCount: Int
    let height: CGFloat
    let imageProvider: ImageProvider
    let onOpenPreview: () -> Void
    let onRevealInFinder: () -> Void

    @State private var image: CGImage?
    @State private var imageLoadFinished: Bool = false

    private var fileExtBadge: (label: String, color: Color) {
        let ext = photo.url.pathExtension.lowercased()

        if rawExtensions.contains(ext) {
            return (ext.uppercased(), .orange)
        } else if jpegExtensions.contains(ext) {
            return ("JPG", .green)
        } else if ext == "heic" || ext == "heif" {
            return (ext.uppercased(), .teal)
        } else if ext == "png" {
            return ("PNG", .blue)
        } else if videoExtensions.contains(ext) {
            return (ext.uppercased(), .purple)
        } else {
            return (ext.uppercased(), .gray)
        }
    }

    /// A real selection set — not the lone auto-selection that follows the cursor.
    private var isMultiSelected: Bool {
        isSelected && selectionCount > 1
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let cgImage = image {
                Image(cgImage, scale: 1.0, label: Text(photo.url.lastPathComponent))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .aspectRatio(1.5, contentMode: .fit)
                    .overlay {
                        if imageLoadFinished {
                            VStack(spacing: 4) {
                                Image(systemName: "doc")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.secondary)
                                Text(photo.fileExtension.uppercased())
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView()
                        }
                    }
            }

            if photo.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .shadow(radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !isFocused && !isSelected {
                Color.black.opacity(0.5)
            }

            let badge = fileExtBadge
            Text(badge.label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(badge.color.opacity(0.85), in: .rect(cornerRadius: 3))
                .padding(4)

            if isMultiSelected {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .padding(4)
                    }
                    Spacer()
                }
            }

            if let metadata, metadata.label != .none {
                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(colorForLabel(metadata.label))
                            .frame(width: 10, height: 10)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(.top, isMultiSelected ? 26 : 4)
                            .padding(.trailing, 4)
                    }
                    Spacer()
                }
            }

            if let metadata, metadata.rating > 0 {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 1) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.yellow)
                            Text("\(metadata.rating)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: .rect(cornerRadius: 3))
                        .padding(3)
                    }
                }
            }

            if let metadata, metadata.flag != .none {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: metadata.flag == .pick ? "flag.fill" : "flag.slash.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white, metadata.flag == .pick ? Color.green : Color.red)
                            .padding(3)
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 3))
                            .padding(3)
                        Spacer()
                    }
                }
            }

            if isSelected && !isFocused {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 3)
            }

            if isFocused {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 4)
                RoundedRectangle(cornerRadius: 3)
                    .inset(by: 3)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
            }
        }
        .clipShape(.rect(cornerRadius: 4))
        .opacity(metadata?.flag == .reject ? 0.4 : 1.0)
        .shadow(
            color: isFocused ? Color.accentColor.opacity(0.75) : .clear,
            radius: isFocused ? 11 : 0
        )
        .scaleEffect(isFocused ? 1.1 : (isMultiSelected ? 1.03 : 1.0))
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .zIndex(isFocused ? 3 : (isSelected ? 2 : 0))
        .frame(height: height)
        .contextMenu {
            Button("Open in Preview", action: onOpenPreview)
            Button("Reveal in Finder", action: onRevealInFinder)
        }
        .task(id: photo.id) {
            imageLoadFinished = false
            let ref = PhotoRef(id: photo.id, url: photo.url, pairedURL: photo.pairedURL)
            image = await imageProvider.image(for: ref, tier: .thumbnail)
            imageLoadFinished = true
        }
    }
}
