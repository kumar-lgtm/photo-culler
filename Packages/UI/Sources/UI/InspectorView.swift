import SwiftUI
import Catalog
import Sidecar
import Decode

struct InspectorView: View {
    @ObservedObject var workspace: WorkspaceViewModel

    var body: some View {
        List {
            if let photo = workspace.currentPhoto {
                Section("Photo information") {
                    LabeledContent("File", value: photo.url.lastPathComponent)
                        .textSelection(.enabled)
                    LabeledContent("Size", value: formatSize(photo.fileSize))
                    LabeledContent("Modified", value: formatDate(photo.modificationDate))
                    HistogramView(photo: photo, workspace: workspace)
                        .frame(height: 60).padding(.vertical, 4)
                        .accessibilityLabel("Image brightness histogram")
                }
                Section("Review photo") {
                    if workspace.canWriteMetadata(to: photo) {
                        HStack {
                            Text("Rating")
                            Spacer()
                            EditableRatingView(rating: workspace.currentMetadata.rating, onChange: workspace.applyRating)
                        }
                        .accessibilityElement(children: .contain)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Color label")
                            EditableColorView(currentLabel: workspace.currentMetadata.label, onChange: workspace.applyColorLabel)
                        }
                        .accessibilityElement(children: .contain)
                        HStack {
                            Button("Pick", systemImage: "flag") { workspace.applyFlag(.pick) }.help("Pick photo (P)")
                            Button("Reject", systemImage: "flag.slash") { workspace.applyFlag(.reject) }.help("Reject photo (X)")
                            Button("Unflag") { workspace.applyFlag(.none) }
                                .disabled(workspace.currentMetadata.flag == .none).help("Clear flag (U)")
                        }.controlSize(.small)
                        .accessibilityElement(children: .contain)
                        Text(workspace.currentMetadata.flag == .none ? "Unflagged" : (workspace.currentMetadata.flag == .pick ? "Picked" : "Rejected"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Select a photo to inspect it.").foregroundStyle(.secondary)
            }
            Section("Culling") {
                Toggle("Auto-advance after tagging", isOn: $workspace.autoAdvance)
                Picker("Sort by", selection: $workspace.sortOption) {
                    ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
            }
            Section {
                filterSection
            } header: {
                HStack {
                    Text("Filters")
                    Spacer()
                    Button("Clear", action: workspace.clearFilters)
                        .accessibilityLabel("Clear all photo filters")
                        .disabled(!workspace.hasActiveFilters)
                }
            }
        }
        .scrollContentBackground(workspace.isBeigeMode ? .hidden : .visible)
        .background(workspace.isBeigeMode ? Color(red: 0.96, green: 0.94, blue: 0.91) : .clear)
        .navigationTitle("Inspector")
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Hide rejects", isOn: $workspace.filterSettings.hideRejects)
            VStack(alignment: .leading, spacing: 8) {
                Text("File types").font(.subheadline.weight(.semibold))
                if workspace.availableFileExtensions.isEmpty {
                    Text("Open a folder to see file types.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("All types", action: workspace.selectAllFileExtensions)
                        Button("No types", action: workspace.clearFileExtensions)
                    }.controlSize(.small)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(workspace.availableFileExtensions, id: \.self) { ext in
                            Toggle(isOn: fileExtensionBinding(ext)) {
                                Text("\(ext.uppercased()) (\(fileExtensionCount(ext)))").font(.callout)
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Show \(ext.uppercased()) files")
                            .help("\(fileExtensionCount(ext)) \(ext.uppercased()) files in this folder")
                        }
                    }
                }
                if !workspace.pairedJPGItems.isEmpty {
                    Toggle("Keep RAW + JPEG pairs together", isOn: $workspace.filterSettings.keepRAWAndJPEGPairsTogether)
                        .toggleStyle(.checkbox)
                        .help("Matching RAW and JPEG files appear as one photo when both types are shown.")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(workspace.filterSettings.minRating == 0 ? "Any rating" : "At least \(workspace.filterSettings.minRating) stars")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    ForEach(0...5, id: \.self) { rating in
                        Button { workspace.filterSettings.minRating = rating } label: {
                            Image(systemName: rating == 0 ? "line.3.horizontal.decrease.circle" : (rating <= workspace.filterSettings.minRating ? "star.fill" : "star"))
                                .foregroundStyle(rating > 0 && rating <= workspace.filterSettings.minRating ? Color.accentColor : .secondary)
                                .frame(width: 26, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(rating == 0 ? "Show all ratings" : "Show photos rated at least \(rating) stars")
                        .accessibilityValue(workspace.filterSettings.minRating == rating ? "Selected" : "Not selected")
                        .help(rating == 0 ? "Show all ratings" : "At least \(rating) stars")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Color filters").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach([ColorLabel.red, .yellow, .green, .blue, .purple, .orange, .cyan, .magenta], id: \.self) { label in
                        Toggle(label.rawValue, isOn: Binding(
                            get: { workspace.filterSettings.colors.contains(label) },
                            set: { enabled in
                                if enabled { workspace.filterSettings.colors.insert(label) }
                                else { workspace.filterSettings.colors.remove(label) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Filter by \(label.rawValue)")
                    }
                }
                Text(workspace.filterSettings.colors.isEmpty ? "All colors" : workspace.filterSettings.colors.map(\.rawValue).sorted().joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo filters")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo star rating")
    }
}

struct EditableRatingView: View {
    let rating: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                Button { onChange(index == rating ? 0 : index) } label: {
                    Image(systemName: index <= rating ? "star.fill" : "star")
                        .foregroundStyle(index <= rating ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(index == rating ? "Clear photo rating" : "Rate photo \(index) stars")
                .accessibilityValue("Current rating: \(rating) out of 5")
                .help(index == rating ? "Clear rating (0)" : "Rate \(index) stars (\(index))")
            }
        }
    }
}

struct EditableColorView: View {
    let currentLabel: ColorLabel
    let onChange: (Int) -> Void
    private let labels: [ColorLabel] = [.red, .yellow, .green, .blue, .purple, .orange, .cyan, .magenta]

    var body: some View {
        Picker("", selection: Binding(
            get: { currentLabel },
            set: { label in onChange(labels.firstIndex(of: label).map { $0 + 1 } ?? 0) }
        )) {
            Text("No label").tag(ColorLabel.none)
            ForEach(labels, id: \.self) { label in Text(label.rawValue).tag(label) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Photo color label")
        .accessibilityValue(currentLabel == .none ? "No label" : currentLabel.rawValue)
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
