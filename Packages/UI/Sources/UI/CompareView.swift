import SwiftUI
import Catalog
import Decode
import Sidecar

public struct CompareView: View {
    @ObservedObject var workspace: WorkspaceViewModel
    @StateObject private var zoomState = ZoomState()
    
    public var body: some View {
        let selectedPhotos = workspace.photos.filter { workspace.selection.contains($0.id) }
        let displayPhotos = Array(selectedPhotos.prefix(4))

        // Identify the sharpest of the compared set — only once at least two panes are scored,
        // so the badge doesn't flicker onto whichever loads first.
        let scored = displayPhotos.filter { workspace.sharpnessCache[$0.id] != nil }
        let sharpestID: UUID? = scored.count >= 2
            ? scored.max(by: { (workspace.sharpnessCache[$0.id] ?? 0) < (workspace.sharpnessCache[$1.id] ?? 0) })?.id
            : nil


        GeometryReader { proxy in
            if displayPhotos.count < 2 {
                VStack(spacing: 16) {
                    Image(systemName: "square.split.2x2")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                        .padding()
                    Text("Select 2-4 photos to compare")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Press ⇧C to add photos, then C to compare  •  Esc to clear")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    // Quick-select: compare current with neighbors
                    if let idx = workspace.currentPhotoIndex, workspace.photos.count > 1 {
                        Button {
                            selectNeighborsForCompare(centerIndex: idx)
                        } label: {
                            Label("Compare with neighbors", systemImage: "rectangle.split.2x1")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let count = displayPhotos.count
                let columns = count > 2 ? 2 : count
                let rows = count > 1 ? (count + 1) / 2 : 1
                
                VStack(spacing: 2) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<columns, id: \.self) { col in
                                let index = row * columns + col
                                if index < count {
                                    ComparePane(
                                        photo: displayPhotos[index],
                                        workspace: workspace,
                                        zoomState: zoomState,
                                        isPrimary: workspace.currentPhoto?.id == displayPhotos[index].id,
                                        isSharpest: sharpestID == displayPhotos[index].id
                                    )
                                } else {
                                    Color.clear
                                }
                            }
                        }
                    }
                }
                .background(workspace.isBeigeMode ? Color(red: 0.85, green: 0.82, blue: 0.77) : Color(NSColor.separatorColor))
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoomState.scale = zoomState.lastScale * value
                        }
                        .onEnded { value in
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
                        .onEnded { value in
                            zoomState.lastOffset = zoomState.offset
                        }
                )
            }
        }
    }
    
    /// Selects the current photo and its immediate neighbors for compare mode.
    private func selectNeighborsForCompare(centerIndex: Int) {
        let count = workspace.photos.count
        var indices: [Int] = []
        
        // Previous
        if centerIndex > 0 {
            indices.append(centerIndex - 1)
        }
        // Current
        indices.append(centerIndex)
        // Next
        if centerIndex + 1 < count {
            indices.append(centerIndex + 1)
        }
        // Add one more if we only have 2
        if indices.count < 3 && centerIndex + 2 < count {
            indices.append(centerIndex + 2)
        }
        
        workspace.selection = Set(indices.map { workspace.photos[$0].id })
    }
}

struct ComparePane: View {
    let photo: PhotoItem
    @ObservedObject var workspace: WorkspaceViewModel
    @ObservedObject var zoomState: ZoomState
    let isPrimary: Bool
    var isSharpest: Bool = false

    @State private var image: CGImage?
    @State private var imageLoadFinished = false
    @State private var isHovered = false
    @State private var loadTask: Task<Void, Never>?
    @State private var faceZoomIndex: Int = 0
    @State private var faceZoomActive: Bool = false
    @State private var paneLocalOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if workspace.isBeigeMode {
                    Color(red: 0.96, green: 0.94, blue: 0.91)
                } else {
                    Color(NSColor.underPageBackgroundColor)
                }
                
                if let cgImage = image {
                    Image(cgImage, scale: 1.0, label: Text(photo.url.lastPathComponent))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width * zoomState.scale, height: proxy.size.height * zoomState.scale)
                        .offset(CGSize(
                            width: zoomState.offset.width + paneLocalOffset.width,
                            height: zoomState.offset.height + paneLocalOffset.height
                        ))
                } else if imageLoadFinished {
                    VStack(spacing: 10) {
                        Image(systemName: "doc")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text(photo.fileExtension.uppercased())
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }

                // Dim inactive panes so the active (Tab-focused) one is unmistakable
                // among near-identical shots.
                if !isPrimary {
                    Color.black.opacity(0.28)
                        .allowsHitTesting(false)
                }

                // Overlay: filename + rating/label + flag + sharpness
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        let meta = workspace.metadataCache[photo.id]

                        if let meta, meta.flag != .none {
                            Image(systemName: meta.flag == .pick ? "flag.fill" : "flag.slash.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(meta.flag == .pick ? Color.green : Color.red)
                        }

                        Text(photo.url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let meta, meta.rating > 0 {
                            HStack(spacing: 1) {
                                ForEach(0..<meta.rating, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                        if let meta, meta.label != .none {
                            Circle()
                                .fill(colorForLabel(meta.label))
                                .frame(width: 8, height: 8)
                        }

                        Spacer()

                        // Sharpness score (relative within the compared set)
                        if let score = workspace.sharpnessCache[photo.id] {
                            HStack(spacing: 3) {
                                Image(systemName: "scope")
                                    .font(.system(size: 8))
                                Text(sharpnessLabel(score))
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(isSharpest ? Color.green : Color.white.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                }

                // "Sharpest of set" pill (top-leading)
                if isSharpest {
                    VStack {
                        HStack {
                            Label("Sharpest", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green, in: .capsule)
                                .padding(8)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // Selection border
                if isPrimary {
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 3)
                } else if isHovered {
                    Rectangle()
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                faceZoomActive = false   // manual zoom ends any face-zoom session
                withAnimation(.spring()) {
                    if zoomState.scale > 1.0 {
                        zoomState.reset()
                    } else {
                        let targetScale: CGFloat = 3.0
                        let viewWidth = proxy.size.width
                        let viewHeight = proxy.size.height
                        
                        let offsetX = (1.0 - targetScale) * (location.x - viewWidth / 2.0)
                        let offsetY = (1.0 - targetScale) * (location.y - viewHeight / 2.0)
                        
                        zoomState.scale = targetScale
                        zoomState.lastScale = targetScale
                        paneLocalOffset = CGSize(width: offsetX, height: offsetY)
                        zoomState.offset = .zero
                        zoomState.lastOffset = .zero
                    }
                }
            }
            .onTapGesture(count: 1) {
                // Set as the "active" pane for ratings without breaking multi-selection
                if let idx = workspace.photos.firstIndex(where: { $0.id == photo.id }) {
                    workspace.currentPhotoIndex = idx
                }
            }
            .task(id: photo.id) {
                // Reload image whenever photo.id changes (task identity)
                loadPaneImage()
            }
            .onDisappear {
                loadTask?.cancel()
            }
            .onChange(of: zoomState.scale) { old, new in
                if new <= 1.0 {
                    paneLocalOffset = .zero
                }
            }
            .onReceive(workspace.shortcutManager.actionPublisher) { action in
                // Only global panning actions should be restricted to primary
                switch action {
                case .toggleFaceZoom:
                    toggleFaceZoom(proxy: proxy)
                case .panUp, .panDown, .panLeft, .panRight:
                    guard isPrimary else { return }
                    if action == .panUp { pan(dx: 0, dy: 100) }
                    else if action == .panDown { pan(dx: 0, dy: -100) }
                    else if action == .panLeft { pan(dx: 100, dy: 0) }
                    else if action == .panRight { pan(dx: -100, dy: 0) }
                default:
                    break
                }
            }
        }
    }
    
    private func pan(dx: CGFloat, dy: CGFloat) {
        guard zoomState.scale > 1.0 else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            zoomState.offset.width += dx
            zoomState.offset.height += dy
            zoomState.lastOffset = zoomState.offset
        }
    }
    
    private func loadPaneImage() {
        loadTask?.cancel()
        image = nil
        imageLoadFinished = false
        faceZoomActive = false   // new photo in this pane → fresh face-zoom session

        loadTask = Task {
            let ref = PhotoRef(id: photo.id, url: photo.url, pairedURL: photo.pairedURL,
                               prefersEmbeddedPreview: photo.isRAW && photo.pairedURL == nil)

            // Preview first for instant feedback.
            if let preview = await workspace.imageProvider.image(for: ref, tier: .preview) {
                guard !Task.isCancelled else { return }
                image = preview
                imageLoadFinished = true
            }

            guard !Task.isCancelled else { return }

            // Then escalate to native resolution. Compare mode exists to judge critical
            // focus at 4× magnification — doing that against a 3200px preview means
            // inspecting an upscaled image, which can't answer the question being asked.
            guard let full = await workspace.imageProvider.image(for: ref, tier: .full) else {
                imageLoadFinished = true
                return
            }
            guard !Task.isCancelled else { return }
            image = full
            imageLoadFinished = true

            // Score sharpness from the full-resolution image, on the detected face when
            // there is one — that's the region a photographer is actually judging.
            if workspace.sharpnessCache[photo.id] == nil {
                var faces = workspace.faceDataCache[photo.id]
                if faces == nil {
                    faces = await ImageAnalyzer.shared.detectFaces(in: full)
                }
                let resolved = faces ?? []
                let region = resolved.first.map { expand($0.boundingBox, by: 1.4) }
                let score = await ImageAnalyzer.shared.sharpness(of: full, region: region)
                await MainActor.run {
                    workspace.faceDataCache[photo.id] = resolved
                    workspace.sharpnessCache[photo.id] = score
                }
            }
        }
    }

    /// Pads a face box so the score includes eyes/hair edges, clamped to the frame.
    private func expand(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        let dw = rect.width * (factor - 1) / 2
        let dh = rect.height * (factor - 1) / 2
        return rect.insetBy(dx: -dw, dy: -dh)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    
    /// Compact rendering of the (arbitrary-scale) sharpness score; higher = sharper.
    private func sharpnessLabel(_ score: Double) -> String {
        if score >= 1000 { return String(format: "%.1fk", score / 1000) }
        return "\(Int(score.rounded()))"
    }

    private func toggleFaceZoom(proxy: GeometryProxy) {
        guard let cgImage = image else { return }

        if let faces = workspace.faceDataCache[photo.id] {
            applyFaceZoom(faces: faces, cgImage: cgImage, proxy: proxy)
        } else {
            // Failsafe: Z was pressed before async face detection finished. Detect on
            // demand against the displayed image and then zoom, instead of silently
            // doing nothing (the old behavior, which forced a navigate-away-and-back).
            let targetID = photo.id
            Task {
                let faces = await ImageAnalyzer.shared.detectFaces(in: cgImage)
                await MainActor.run {
                    workspace.faceDataCache[targetID] = faces
                    // Pane may have been reused for a different photo while we detected.
                    guard photo.id == targetID, workspace.selection.contains(targetID) else { return }
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
                    if isPrimary { zoomState.reset() }
                    paneLocalOffset = .zero
                } else if isPrimary {
                    zoomState.scale = 2.5
                    zoomState.lastScale = 2.5
                    zoomState.offset = .zero
                    zoomState.lastOffset = .zero
                    paneLocalOffset = .zero
                }
                faceZoomActive = false
                faceZoomIndex = 0
                return
            }

            // Session-based entry: a fresh press always starts on the largest face (sorted
            // largest-first), independent of any prior manual zoom; further presses cycle.
            if faceZoomActive {
                faceZoomIndex += 1
                if faceZoomIndex >= faces.count {
                    if isPrimary { zoomState.reset() }
                    paneLocalOffset = .zero
                    faceZoomActive = false
                    faceZoomIndex = 0
                    return
                }
            } else {
                faceZoomActive = true
                faceZoomIndex = 0
            }

            let faceRect = faces[faceZoomIndex].boundingBox

            let viewWidth = proxy.size.width
            let viewHeight = proxy.size.height
            let iw = CGFloat(cgImage.width)
            let ih = CGFloat(cgImage.height)

            // Compare panes have no extra padding so use full pane size.
            let fitScale = min(viewWidth / iw, viewHeight / ih)
            let rw = iw * fitScale
            let rh = ih * fitScale

            // Fixed scale across all panes so the comparison stays a fair, equal-magnification
            // side-by-side; each pane still centers on its own face.
            let targetScale: CGFloat = 4.0

            // Center on face: after scaleEffect(s) + offset(o), point p → p*s + o.
            // Solve for o so face lands at center: o = -s * p
            let offsetX = -targetScale * (faceRect.midX - 0.5) * rw
            let offsetY = -targetScale * (0.5 - faceRect.midY) * rh

            if isPrimary {
                zoomState.scale = targetScale
                zoomState.lastScale = targetScale
                zoomState.offset = .zero
                zoomState.lastOffset = .zero
            }

            paneLocalOffset = CGSize(width: offsetX, height: offsetY)
        }
    }
}
