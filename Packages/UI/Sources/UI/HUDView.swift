import SwiftUI

public enum HUDMessage: Equatable {
    case rating(Int)
    case label(String, Color)
    case message(String)
}

public struct HUDView: View {
    let message: HUDMessage
    
    public var body: some View {
        VStack(spacing: 12) {
            switch message {
            case .rating(let val):
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= val ? "star.fill" : "star")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(i <= val ? .yellow : .secondary)
                    }
                }
            case .label(let text, let color):
                HStack {
                    Circle()
                        .fill(color)
                        .frame(width: 24, height: 24)
                    Text(text)
                        .font(.system(size: 24, weight: .bold))
                }
            case .message(let text):
                Text(text)
                    .font(.system(size: 24, weight: .bold))
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 20))
        .shadow(radius: 10)
        .transition(.scale.combined(with: .opacity))
    }
}
