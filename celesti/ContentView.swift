import AVKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: CelestiAppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            CelestiAmbientBackground(includeGradient: appModel.playback == nil)

            if let playback = appModel.playback {
                PlaybackRootView(playback: playback)
            } else {
                registrationRoot
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
            CelestiHeader()

            switch appModel.registrationState {
            case .pending:
                PendingRegistrationView(
                    deviceId: appModel.deviceId,
                    onDemoMode: appModel.showDemoMode
                )
            case .standby:
                StandbyView(deviceId: appModel.deviceId, nickname: appModel.nickname)
            case .demo:
                DemoLoadingView()
            }
        }
    }
}

private struct PendingRegistrationView: View {
    let deviceId: String
    let onDemoMode: () -> Void

    private var qrCodeImage: UIImage? {
        QRCodeFactory.image(for: "https://api.celesti.gaulatti.com/register/\(deviceId)", size: 240)
    }

    var body: some View {
        HStack(spacing: 48) {
            VStack(alignment: .leading, spacing: 0) {
                Text("DEVICE LINK")
                    .font(CelestiTypography.body(size: 12, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(Color.primary)

                Spacer().frame(height: 14)

                LinearGradient(
                    colors: [.clear, Color.primary.opacity(0.85), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 340, height: 1)

                Spacer().frame(height: 24)

                Text(deviceId)
                    .font(CelestiTypography.brand(size: 56, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Text("Enter this code in the app to register this device")
                    .font(CelestiTypography.body(size: 24))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .padding(.top, 24)

                Spacer().frame(height: 34)

                Button("Demo Mode", action: onDemoMode)
                    .buttonStyle(.borderedProminent)
                    .tint(.celestiSea)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(36)
            .celestiCard()

            VStack(spacing: 0) {
                Text("QUICK REGISTER")
                    .font(CelestiTypography.body(size: 12, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(Color.primary)

                Spacer().frame(height: 22)

                Group {
                    if let qrCodeImage {
                        Image(uiImage: qrCodeImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                            .tint(.black)
                    }
                }
                .frame(width: 240, height: 240)
                .padding(18)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("Scan to register")
                    .font(CelestiTypography.body(size: 20))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .padding(.top, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(36)
            .celestiCard()
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StandbyView: View {
    let deviceId: String
    let nickname: String?

    @State private var pulse = false
    @State private var blink = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.primary.opacity(pulse ? 0.4 : 0.1), .clear],
                        center: .center,
                        startRadius: 12,
                        endRadius: 260
                    )
                )
                .frame(width: 460, height: 460)
                .scaleEffect(pulse ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: pulse)

            VStack(spacing: 26) {
                VStack(spacing: 0) {
                    Text("SYSTEM")
                        .font(CelestiTypography.body(size: 12, weight: .bold))
                        .tracking(4)
                        .foregroundStyle(Color.primary)

                    Spacer().frame(height: 18)

                    Text("Standby")
                        .font(CelestiTypography.brand(size: 52, weight: .semibold))
                        .opacity(blink ? 1.0 : 0.4)
                        .animation(.linear(duration: 2).repeatForever(autoreverses: true), value: blink)

                    if let nickname, !nickname.isEmpty {
                        Spacer().frame(height: 14)
                        Text(nickname)
                            .font(CelestiTypography.brand(size: 32, weight: .medium))
                    }

                    Spacer().frame(height: 16)

                    Text(deviceId)
                        .font(CelestiTypography.body(size: 19, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                .frame(minWidth: 540, maxWidth: 860)
                .padding(.horizontal, 38)
                .padding(.vertical, 34)

                CelestiStatusPill(text: "READY", color: Color(red: 217 / 255, green: 79 / 255, blue: 79 / 255))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            pulse = true
            blink = true
        }
    }
}

private struct DemoLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Launching demo mode…")
                .font(CelestiTypography.body(size: 20, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.76))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PlaybackRootView: View {
    @EnvironmentObject private var appModel: CelestiAppModel

    let playback: PlaybackPresentation

    var body: some View {
        ZStack {
            if playback.isPlaybackFailed {
                PlaybackFailedView(streamName: playback.failedStreamName) {
                    appModel.retryPlayback()
                }
            } else {
                PlayerContainerView(player: appModel.playerController.player)
                    .ignoresSafeArea()

                if playback.isAudioOnly {
                    AudioPlaybackView(playback: playback)
                }

                if playback.source == .demo {
                    DemoOverlay(isBuffering: playback.isBuffering)
                }

                if appModel.dvrVisible {
                    DvrOverlayView(
                        playback: playback,
                        player: appModel.playerController.player,
                        dvrAction: appModel.dvrAction
                    )
                }
            }

            if !playback.isPlaybackFailed, playback.isBuffering {
                ProgressView()
                    .scaleEffect(1.6)
                    .tint(.white)
            }
        }
        .ignoresSafeArea()
    }
}

private struct DemoOverlay: View {
    let isBuffering: Bool

    var body: some View {
        VStack(spacing: 12) {
            CelestiHeader()

            HStack {
                CelestiStatusPill(
                    text: isBuffering ? "DEMO BUFFERING" : "DEMO LIVE",
                    color: isBuffering ? .celestiDesert : Color(red: 217 / 255, green: 79 / 255, blue: 79 / 255)
                )

                Spacer()
            }
            .padding(.horizontal, 56)

            Spacer()
        }
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.95), location: 0),
                    .init(color: Color.black.opacity(0.88), location: 0.2),
                    .init(color: Color.black.opacity(0.62), location: 0.4),
                    .init(color: Color.black.opacity(0.26), location: 0.6),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxHeight: 420),
            alignment: .top
        )
    }
}

private struct AudioPlaybackView: View {
    let playback: PlaybackPresentation

    @State private var pulse = false

    var body: some View {
        ZStack {
            CelestiAmbientBackground(includeGradient: true)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.primary.opacity(pulse ? 0.4 : 0.1), .clear],
                        center: .center,
                        startRadius: 12,
                        endRadius: 260
                    )
                )
                .frame(width: 460, height: 460)
                .scaleEffect(pulse ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: pulse)

            VStack(spacing: 0) {
                CelestiHeader()

                Spacer()

                VStack(spacing: 0) {
                    Text("LIVE RADIO")
                        .font(CelestiTypography.body(size: 12, weight: .bold))
                        .tracking(6)
                        .foregroundStyle(Color.primary)

                    Spacer().frame(height: 14)

                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(0.8), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 340, height: 1)

                    Spacer().frame(height: 24)

                    Text(playback.radioName ?? "Connecting…")
                        .font(CelestiTypography.brand(size: 36, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineSpacing(8)

                    if let streamTitle = playback.streamTitle, !streamTitle.isEmpty {
                        Spacer().frame(height: 10)
                        Text(streamTitle)
                            .font(CelestiTypography.body(size: 18, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.primary.opacity(0.76))
                    }

                    Spacer().frame(height: 20)

                    CelestiStatusPill(
                        text: playback.isBuffering ? "BUFFERING" : "ON AIR",
                        color: playback.isBuffering ? .celestiDesert : Color(red: 217 / 255, green: 79 / 255, blue: 79 / 255)
                    )
                }
                .frame(minWidth: 400, maxWidth: 800)
                .padding(32)
                .celestiCard(cornerRadius: 24)

                Spacer()
            }
            .padding(.bottom, 80)
        }
        .onAppear {
            pulse = true
        }
    }
}

private struct PlayerContainerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

#Preview {
    ContentView()
        .environmentObject(CelestiAppModel())
}
