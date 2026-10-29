import SwiftUI

public enum HUDMessage: Equatable {
    case rating(Int)
    case label(String, Color)
    case message(String)
}

public struct HUDView: View {
    let message: HUDMessage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(val == 0 ? "Rating cleared" : "Rated \(val) out of 5 stars")
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
        .background {
            if reduceTransparency { Color(NSColor.windowBackgroundColor) }
            else { Rectangle().fill(.ultraThinMaterial) }
        }
        .clipShape(.rect(cornerRadius: 20))
        .shadow(radius: 10)
        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
    }
}
