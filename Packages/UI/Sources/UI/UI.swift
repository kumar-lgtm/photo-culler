import SwiftUI

struct ShortcutRow: View {
    let key: String
    let action: String
    
    var body: some View {
        HStack {
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.fill.tertiary)
                .clipShape(.rect(cornerRadius: 4))
        }
    }
}
