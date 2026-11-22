import Sabella
import SwiftUI

struct QuadPlaybackView: View {
    @EnvironmentObject private var appModel: CelestiAppModel

    var body: some View {
        SabellaTVQuadLayout(expandedIndex: appModel.quadPlayerController.expandedQuadrant?.rawValue) { index in
            cell(Quadrant(rawValue: index)!)
        }
        .focusable().focusEffectDisabled()
        .onMoveCommand { direction in
            guard appModel.quadPlayerController.expandedQuadrant == nil else { return }
            appModel.quadPlayerController.moveFocus(direction: direction)
        }
        .onTapGesture {
            guard appModel.quadPlayerController.expandedQuadrant == nil else { return }
            appModel.quadPlayerController.showFocusedSingleView()
        }
        .onPlayPauseCommand { appModel.quadPlayerController.toggleMuteFocused() }
        .onLongPressGesture { appModel.quadPlayerController.restartFocused() }
        .onExitCommand {
            if !appModel.quadPlayerController.restoreQuadView() { appModel.dismissPlayback() }
        }
    }

    private func cell(_ quadrant: Quadrant) -> some View {
        let player = appModel.quadPlayerController.player(for: quadrant)
        let selected = appModel.quadPlayerController.expandedQuadrant == nil
            && appModel.quadPlayerController.isFocusBorderVisible
            && appModel.quadPlayerController.focusedQuadrant == quadrant
        return SabellaTVBroadcastCell(
            selected: selected,
            failure: player.isFailed ? "\(player.failureStatus) · \(player.streamName ?? "Stream")" : nil,
            buffering: player.isBuffering
        ) {
            ZStack {
                if let coordinator = player.ksCoordinator, let url = player.currentURL {
                    KSVideoPlayer(coordinator: coordinator, url: url, options: KSOptions()).opacity(player.isUsingKSPlayer ? 1 : 0)
                }
                SabellaTVPlayerSurface(player: player.avPlayer).opacity(player.isUsingKSPlayer ? 0 : 1)
                if player.isReconnecting { ReconnectingBadge() }
            }
        } placeholder: {
            if !player.isActive || player.isAudioOnly {
                SabellaTVTestPattern(
                    title: player.isActive ? (player.streamName ?? "Audio feed") : "No stream",
                    logoURL: player.logoURL,
                    audioLevel: player.samplePeak
                )
            }
        }
    }
}

/// Shown on a tile while its stall watchdog restarts the stream (gaulatti/atlantide#27).
struct ReconnectingBadge: View {
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityLabel("Reconnecting")
            }
            Spacer()
        }
        .padding(16)
        .allowsHitTesting(false)
    }
}
