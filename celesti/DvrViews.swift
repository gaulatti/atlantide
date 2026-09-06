import AVFoundation
import Sabella
import SwiftUI

struct DvrOverlayView: View {
    let playback: PlaybackPresentation
    let player: AVPlayer
    let dvrAction: DvrAction

    private static let qualityLabels = ["AUTO", "HD", "SD", "MED", "LOW", "MIN"]

    var body: some View {
        SabellaTVDVROverlay(
            currentTime: playback.currentTime,
            duration: playback.duration,
            quality: qualityLabel,
            action: sabellaAction
        )
    }

    private var qualityLabel: String? {
        guard Self.qualityLabels.indices.contains(playback.qualityTier) else { return nil }
        return Self.qualityLabels[playback.qualityTier]
    }

    private var sabellaAction: SabellaTVDVRAction {
        switch dvrAction {
        case .none: .none
        case .play: .play
        case .pause: .pause
        case .rewind: .rewind
        case .fastForward: .fastForward
        }
    }
}
