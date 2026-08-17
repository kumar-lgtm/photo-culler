import SwiftUI

public class ZoomState: ObservableObject {
    @Published public var scale: CGFloat = 1.0
    @Published public var offset: CGSize = .zero
    
    @Published public var lastScale: CGFloat = 1.0
    @Published public var lastOffset: CGSize = .zero
    
    public init() {}
    
    public func reset() {
        scale = 1.0
        offset = .zero
        lastScale = 1.0
        lastOffset = .zero
    }
}
