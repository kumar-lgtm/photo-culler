import SwiftUI
import Sidecar

func photoReviewSummary(_ metadata: PhotoMetadata?, selected: Bool) -> String {
    let value = metadata ?? PhotoMetadata()
    var parts = ["\(value.rating) of 5 stars", value.label == .none ? "No color label" : value.label.rawValue + " label"]
    parts.append(value.flag == .none ? "Unflagged" : (value.flag == .pick ? "Picked" : "Rejected"))
    if selected { parts.append("Selected") }
    return parts.joined(separator: ", ")
}

struct ShortcutRow: View {
    let key: String
    let action: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
            Spacer(minLength: 4)
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(.rect(cornerRadius: 4))
        }
    }
}
