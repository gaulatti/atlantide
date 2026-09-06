import AVKit
import Combine
import KSPlayer
import Sabella
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: CelestiAppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SabellaTVAmbientBackground(animated: appModel.playback == nil && appModel.layoutMode == .single)

            if appModel.layoutMode == .emergency {
                EmergencyPlaybackView()
                    .environmentObject(appModel)
            } else if appModel.layoutMode == .quad {
                QuadPlaybackView()
                    .environmentObject(appModel)
            } else if let playback = appModel.playback {
                PlaybackRootView(playback: playback)
            } else {
                registrationRoot
            }

            if let callsign = appModel.callsign {
                SabellaTVCallsignOverlay(nickname: callsign.nickname, deviceCode: callsign.deviceCode)
            }
        }
        .task {
            appModel.startIfNeeded()
        }
        .onExitCommand {
            appModel.handleExitCommand()
        }
    }

    @ViewBuilder
    private var registrationRoot: some View {
        VStack(spacing: 0) {
            SabellaTVChromeHeader(productName: "Celesti")
                .padding(.horizontal, 84)
                .padding(.vertical, 38)

            switch appModel.registrationState {
            case .pending:
                SabellaTVRegistration(deviceID: appModel.deviceId, demo: appModel.showDemoMode) {
                    if let image = QRCodeFactory.image(for: "https://api.celesti.gaulatti.com/register/\(appModel.deviceId)", size: 360) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.black)
                    }
                }
            case .standby:
                SabellaTVStandby(deviceID: appModel.deviceId, nickname: appModel.nickname)
            case .demo:
                SabellaTVLoadingState("Launching demo mode…")
            }
        }
    }
}

private struct PlaybackRootView: View {
    @EnvironmentObject private var appModel: CelestiAppModel

    let playback: PlaybackPresentation

    var body: some View {
        ZStack {
            if playback.isPlaybackFailed {
                SabellaTVPlaybackFailure(
                    title: playback.failedStreamName ?? "Stream",
                    message: "Could not connect to the stream."
                ) {
                    appModel.retryPlayback()
                }
            } else {
                // Keep KSVideoPlayer in hierarchy always so the underlying
                // view persists across play/stop cycles. Use opacity
                // to hide it when AVPlayer is active.
                if let coordinator = appModel.playerController.ksCoordinator,
                   let currentURL = appModel.playerController.currentURL {
                    KSVideoPlayer(coordinator: coordinator, url: currentURL, options: KSOptions())
                        .opacity(appModel.playerController.isUsingKSPlayer ? 1 : 0)
                        .ignoresSafeArea()
                }

                if !appModel.playerController.isUsingKSPlayer {
                    SabellaTVPlayerSurface(player: appModel.playerController.player, gravity: .resizeAspectFill)
                        .ignoresSafeArea()
                }
            }

            if playback.isAudioOnly {
                AudioPlaybackView(playback: playback)
            }

            if playback.source == .demo {
                SabellaTVDemoOverlay(productName: "Celesti", buffering: playback.isBuffering)
            }

            if appModel.dvrVisible {
                DvrOverlayView(
                    playback: playback,
                    player: appModel.playerController.player,
                    dvrAction: appModel.dvrAction
                )
            }

            if !playback.isPlaybackFailed, playback.isBuffering {
                ProgressView()
                    .scaleEffect(1.6)
                    .tint(.white)
            }
        }
        .ignoresSafeArea()
        .focusable()
        .onTapGesture {
            appModel.handlePlaybackSelect()
        }
        .onLongPressGesture {
            appModel.restartPlayback()
        }
        .onPlayPauseCommand {
            appModel.togglePlayPause()
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:
                appModel.seekBackward()
            case .right:
                appModel.seekForward()
            case .up, .down:
                appModel.showDvrOverlay(action: .none)
            default:
                break
            }
        }
    }
}

private struct AudioPlaybackView: View {
    let playback: PlaybackPresentation

    var body: some View {
        SabellaTVRadioNowPlaying(
            station: playback.radioName ?? "Connecting…",
            title: playback.streamTitle,
            buffering: playback.isBuffering,
            active: !playback.isPlaybackFailed
        )
    }
}


#Preview {
    ContentView()
        .environmentObject(CelestiAppModel())
}
