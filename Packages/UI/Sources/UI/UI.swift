import SwiftUI

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
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.fill.tertiary)
                .clipShape(.rect(cornerRadius: 4))
        }
    }
}
