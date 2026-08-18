import SwiftUI
import Catalog
import Sidecar
import Decode

struct InspectorView: View {
    @ObservedObject var workspace: WorkspaceViewModel

    var body: some View {
        List {
            if let photo = workspace.currentPhoto {
                Section(workspace.isBeigeMode ? "energy histogram" : "Histogram") {
                    HistogramView(photo: photo, workspace: workspace)
                        .frame(height: 60)
                        .padding(.vertical, 4)
                }
                
                Section(workspace.isBeigeMode ? "metadata vibes" : "Information") {
                    LabeledContent(workspace.isBeigeMode ? "file" : "File", value: workspace.isBeigeMode ? photo.url.lastPathComponent.lowercased() : photo.url.lastPathComponent)
                    LabeledContent(workspace.isBeigeMode ? "size" : "Size", value: formatSize(photo.fileSize))
                    LabeledContent(workspace.isBeigeMode ? "modified" : "Modified", value: formatDate(photo.modificationDate))
                }

                Section(workspace.isBeigeMode ? "curation & energy" : "Rating & Color") {
                    if workspace.canWriteMetadata(to: photo) {
                        HStack {
                            Text(workspace.isBeigeMode ? "stars" : "Rating")
                            Spacer()
                            EditableRatingView(rating: workspace.currentMetadata.rating) { newRating in
                                workspace.applyRating(newRating)
                            }
                        }

                        HStack {
                            Text(workspace.isBeigeMode ? "aura" : "Color")
                            Spacer()
                            EditableColorView(currentLabel: workspace.currentMetadata.label) { index in
                                workspace.applyColorLabel(index: index)
                            }
                        }
                    } else {
                        LabeledContent(workspace.isBeigeMode ? "metadata" : "Metadata", value: workspace.isBeigeMode ? "read-only vibes" : "Read-only sidecar")
                    }
                }
            } else {
                Text(workspace.isBeigeMode ? "awaiting focus..." : "No photo selected")
                    .foregroundStyle(.secondary)
                    .font(workspace.isBeigeMode ? .caption.italic() : .body)
            }
        }
        .scrollContentBackground(workspace.isBeigeMode ? .hidden : .visible)
        .background(workspace.isBeigeMode ? Color(red: 0.96, green: 0.94, blue: 0.91) : .clear)
        .navigationTitle(workspace.isBeigeMode ? "vibes inspector" : "Inspector")
        .safeAreaInset(edge: .bottom) {
            filterSection
                .padding()
                .background(.regularMaterial)
        }
    }
    
    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings & Filters").font(.headline)
            
            Toggle("Auto-advance after tagging", isOn: $workspace.autoAdvance)
            
            Picker("Sort By", selection: $workspace.sortOption) {
                ForEach(SortOption.allCases) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.menu)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("File Types:")
                    .font(.subheadline.weight(.semibold))

                if workspace.availableFileExtensions.isEmpty {
                    Text("Open a folder to see file types")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Button("All") {
                            workspace.selectAllFileExtensions()
                        }
                        .controlSize(.small)

                        Button("None") {
                            workspace.clearFileExtensions()
                        }
                        .controlSize(.small)
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(workspace.availableFileExtensions, id: \.self) { ext in
                                Toggle(isOn: fileExtensionBinding(ext)) {
                                    HStack(spacing: 4) {
                                        Text(ext.uppercased())
                                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        Text("\(fileExtensionCount(ext))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .help("Show .\(ext) files")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 120)
                }

                if workspace.pairedJPGItems.count > 0 {
                    Toggle("Keep RAW + JPEG pairs together", isOn: $workspace.filterSettings.keepRAWAndJPEGPairsTogether)
                        .toggleStyle(.checkbox)
                        .help("When both RAW and JPEG are enabled, show matching pairs as one culling item. Turn this off to show the RAW and JPEG as separate items.")
                }
            }
            
            HStack {
                Text("Min Rating:")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0...5, id: \.self) { rating in
                        Button {
                            workspace.filterSettings.minRating = rating
                        } label: {
                            Image(systemName: rating == 0 ? "xmark.circle" : (rating <= workspace.filterSettings.minRating ? "star.fill" : "star"))
                                .foregroundColor(rating <= workspace.filterSettings.minRating && rating > 0 ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Color Labels:")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([ColorLabel.red, .yellow, .green, .blue, .purple, .orange, .cyan, .magenta], id: \.self) { label in
                            Circle()
                                .fill(color(for: label))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle().stroke(Color.primary, lineWidth: workspace.filterSettings.colors.contains(label) ? 2 : 0)
                                )
                                .onTapGesture {
                                    if workspace.filterSettings.colors.contains(label) {
                                        workspace.filterSettings.colors.remove(label)
                                    } else {
                                        workspace.filterSettings.colors.insert(label)
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func fileExtensionBinding(_ ext: String) -> Binding<Bool> {
        Binding(
            get: { workspace.filterSettings.enabledFileExtensions.contains(ext.lowercased()) },
            set: { workspace.setFileExtension(ext, enabled: $0) }
        )
    }

    /// Counts are computed once at scan time. This used to filter the entire catalog per
    /// extension on every render — and the Inspector re-renders on every arrow key.
    private func fileExtensionCount(_ ext: String) -> Int {
        workspace.count(forExtension: ext)
    }
    
    private func color(for label: ColorLabel) -> Color {
        switch label {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .orange: return .orange
        case .cyan: return .cyan
        case .magenta: return .pink
        case .none: return .primary
        }
    }
}

struct RatingView: View {
    let rating: Int
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= rating ? "star.fill" : "star")
                    .foregroundColor(index <= rating ? .yellow : .secondary.opacity(0.5))
            }
        }
    }
}

struct EditableRatingView: View {
    let rating: Int
    let onChange: (Int) -> Void
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                Button {
                    onChange(index == rating ? 0 : index)
                } label: {
                    Image(systemName: index <= rating ? "star.fill" : "star")
                        .foregroundColor(index <= rating ? .yellow : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct EditableColorView: View {
    let currentLabel: ColorLabel
    let onChange: (Int) -> Void
    
    private let labels: [(ColorLabel, Int, Color, String)] = [
        (.red, 1, .red, "Red"), (.yellow, 2, .yellow, "Yellow"), (.green, 3, .green, "Green"),
        (.blue, 4, .blue, "Blue"), (.purple, 5, .purple, "Purple"), (.orange, 6, .orange, "Orange"),
        (.cyan, 7, .cyan, "Cyan"), (.magenta, 8, .pink, "Magenta")
    ]
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(labels, id: \.1) { label, index, color, _ in
                    Circle()
                        .fill(color)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle().stroke(Color.primary, lineWidth: currentLabel == label ? 2 : 0)
                        )
                        .scaleEffect(currentLabel == label ? 1.25 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: currentLabel)
                        .onTapGesture {
                            onChange(currentLabel == label ? 0 : index)
                        }
                }
            }
            
            if let active = labels.first(where: { $0.0 == currentLabel }) {
                Text(active.3)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active.2)
            }
        }
    }
}

struct HistogramView: View {
    let photo: PhotoItem
    @ObservedObject var workspace: WorkspaceViewModel
    
    @State private var histogramData: [CGFloat] = []
    
    var body: some View {
        VStack {
            if histogramData.isEmpty {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 4))
            } else {
                GeometryReader { proxy in
                    Path { path in
                        let width = proxy.size.width
                        let height = proxy.size.height
                        
                        let step = width / CGFloat(histogramData.count)
                        let maxVal = histogramData.max() ?? 1.0
                        
                        path.move(to: CGPoint(x: 0, y: height))
                        
                        for (index, value) in histogramData.enumerated() {
                            let x = CGFloat(index) * step
                            let y = height - (value / maxVal) * height
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [.gray.opacity(0.8), .gray.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                }
            }
        }
        .task(id: photo.id) {
            await computeHistogram()
        }
    }
    
    private func computeHistogram() async {
        let ref = PhotoRef(id: photo.id, url: photo.url, pairedURL: photo.pairedURL,
                           prefersEmbeddedPreview: photo.isRAW && photo.pairedURL == nil)
        guard let cgImage = await workspace.imageProvider.image(for: ref, tier: .thumbnail) else { return }
        
        let data = await Task.detached(priority: .background) { () -> [CGFloat] in
            let width = 100
            let height = 100
            let colorSpace = CGColorSpaceCreateDeviceGray()

            // Let CoreGraphics own the buffer. Passing `&rawData` let the pointer escape the
            // inout scope — `context.draw` then ran against a pointer that was formally
            // invalid. It usually worked, which is exactly what made it dangerous.
            guard let context = CGContext(data: nil,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let buffer = context.data else { return [] }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height)
            var bins = [CGFloat](repeating: 0, count: 64)
            for index in 0..<(width * height) {
                let bin = Int(pixels[index]) / 4
                bins[min(bin, 63)] += 1.0
            }
            
            // Smooth the bins slightly for a nicer UI curve
            var smoothed = [CGFloat](repeating: 0, count: 64)
            for i in 0..<64 {
                let prev = i > 0 ? bins[i-1] : bins[i]
                let next = i < 63 ? bins[i+1] : bins[i]
                smoothed[i] = (prev + bins[i] * 2 + next) / 4.0
            }
            
            return smoothed
        }.value
        
        withAnimation {
            self.histogramData = data
        }
    }
}
