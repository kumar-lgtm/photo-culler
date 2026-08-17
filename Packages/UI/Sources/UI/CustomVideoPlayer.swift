import SwiftUI
import AVKit

struct CustomVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
