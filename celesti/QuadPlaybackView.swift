import AVFoundation
import SwiftUI
import VLCKitSPM

struct QuadPlaybackView: View {
    @EnvironmentObject private var appModel: CelestiAppModel
    @FocusState private var focusedQuadrant: Quadrant?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                QuadrantCell(
                    quadrant: .topLeft,
                    player: appModel.quadPlayerController.player(for: .topLeft),
                    focusedQuadrant: $focusedQuadrant
                )
                QuadrantCell(
                    quadrant: .topRight,
                    player: appModel.quadPlayerController.player(for: .topRight),
                    focusedQuadrant: $focusedQuadrant
                )
            }
            HStack(spacing: 0) {
                QuadrantCell(
                    quadrant: .bottomLeft,
                    player: appModel.quadPlayerController.player(for: .bottomLeft),
                    focusedQuadrant: $focusedQuadrant
                )
                QuadrantCell(
                    quadrant: .bottomRight,
                    player: appModel.quadPlayerController.player(for: .bottomRight),
                    focusedQuadrant: $focusedQuadrant
                )
            }
        }
        .ignoresSafeArea()
        .onPlayPauseCommand {
            appModel.quadPlayerController.toggleMuteFocused()
        }
        .onLongPressGesture {
            appModel.quadPlayerController.removeFocused(deviceId: appModel.deviceId)
        }
        .onChange(of: focusedQuadrant) { _, newValue in
            if let newValue {
                appModel.quadPlayerController.focusedQuadrant = newValue
            }
        }
        .onAppear {
            focusedQuadrant = appModel.quadPlayerController.focusedQuadrant
        }
    }
}

private struct QuadrantCell: View {
    let quadrant: Quadrant
    @ObservedObject var player: QuadrantPlayer
    var focusedQuadrant: FocusState<Quadrant?>.Binding

    private var isFocused: Bool {
        focusedQuadrant.wrappedValue == quadrant
    }

    var body: some View {
        ZStack {
            Color.black

            ZStack {
                VLCPlayerView(player: player.vlcPlayer)
                    .opacity(player.isUsingVLC ? 1 : 0)
                AVVideoPlayerView(player: player.avPlayer)
                    .opacity(player.isUsingVLC ? 0 : 1)
            }

            if player.isFailed {
                Color(red: 139 / 255, green: 0, blue: 0)
                    .opacity(0.85)
                VStack(spacing: 12) {
                    Text("FAILED")
                        .font(CelestiTypography.body(size: 18, weight: .bold))
                        .tracking(6)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(player.streamName ?? "Stream")
                        .font(CelestiTypography.brand(size: 27, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            } else if player.isBuffering {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(.white)
            }

            VStack {
                Spacer()
                HStack {
                    if player.isMuted {
                        Text("MUTED")
                            .font(CelestiTypography.body(size: 15, weight: .bold))
                            .tracking(3)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.6), in: Capsule())
                    }
                    Spacer()
                }
                .padding(12)
            }

            if player.isActive, let name = player.streamName, !name.isEmpty {
                VStack {
                    HStack {
                        Text(name)
                            .font(CelestiTypography.body(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.5), in: Capsule())
                        Spacer()
                    }
                    .padding(12)
                    Spacer()
                }
            }

            if isFocused {
                Rectangle()
                    .stroke(Color.celestiSunset, lineWidth: 6)
            }
        }
        .focused(focusedQuadrant, equals: quadrant)
        .focusable()
        .clipped()
    }
}

private struct AVVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer.addSublayer(layer)
        context.coordinator.playerLayer = layer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.playerLayer?.frame = uiView.bounds
        context.coordinator.playerLayer?.player = player
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var playerLayer: AVPlayerLayer?
    }
}
