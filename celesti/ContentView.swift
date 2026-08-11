import AVKit
import Combine
import KSPlayer
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: CelestiAppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            CelestiAmbientBackground(includeGradient: appModel.playback == nil && appModel.layoutMode == .single)

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
                CallsignOverlayView(callsign: callsign)
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

    @Environment(\.colorScheme) private var colorScheme

    private var qrCodeImage: UIImage? {
        QRCodeFactory.image(for: "https://api.celesti.gaulatti.com/register/\(deviceId)", size: 360)
    }

    var body: some View {
        HStack(spacing: 72) {
            VStack(alignment: .leading, spacing: 0) {
                Text("DEVICE LINK")
                    .font(CelestiTypography.body(size: 18, weight: .bold))
                    .tracking(6)
                    .foregroundStyle(Color.celestiPrimary(for: colorScheme))

                Spacer().frame(height: 21)

                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, Color.celestiPrimary(for: colorScheme).opacity(0.85), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.45, height: 1.5)
                }
                .frame(height: 1.5)

                Spacer().frame(height: 36)

                Text(deviceId)
                    .font(CelestiTypography.brand(size: 84, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Text("Enter this code in the app to register this device")
                    .font(CelestiTypography.body(size: 36))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .padding(.top, 36)

                Spacer().frame(height: 51)

                Button("Demo Mode", action: onDemoMode)
                    .font(CelestiTypography.brand(size: 27))
                    .buttonStyle(.borderedProminent)
                    .tint(Color.celestiPrimary(for: colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(54)
            .celestiCard()

            VStack(spacing: 0) {
                Text("QUICK REGISTER")
                    .font(CelestiTypography.body(size: 18, weight: .bold))
                    .tracking(6)
                    .foregroundStyle(Color.celestiPrimary(for: colorScheme))

                Spacer().frame(height: 33)

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
                .frame(width: 360, height: 360)
                .padding(27)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 33, style: .continuous))

                Text("Scan to register")
                    .font(CelestiTypography.body(size: 30))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .padding(.top, 30)
            }
            .frame(maxWidth: .infinity)
            .padding(54)
            .celestiCard()
        }
        .padding(.horizontal, 96)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StandbyView: View {
    let deviceId: String
    let nickname: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false
    @State private var blink = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.celestiPrimary(for: colorScheme).opacity(pulse ? 0.4 : 0.1), .clear],
                        center: .center,
                        startRadius: 18,
                        endRadius: 390
                    )
                )
                .frame(width: 690, height: 690)
                .scaleEffect(pulse ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: pulse)

            VStack(spacing: 39) {
                VStack(spacing: 0) {
                    Text("SYSTEM")
                        .font(CelestiTypography.body(size: 18, weight: .bold))
                        .tracking(6)
                        .foregroundStyle(Color.celestiPrimary(for: colorScheme))

                    Spacer().frame(height: 27)

                    Text("Standby")
                        .font(CelestiTypography.brand(size: 78, weight: .semibold))
                        .opacity(blink ? 1.0 : 0.4)
                        .animation(.linear(duration: 2).repeatForever(autoreverses: true), value: blink)

                    if let nickname, !nickname.isEmpty {
                        Spacer().frame(height: 21)
                        Text(nickname)
                            .font(CelestiTypography.brand(size: 48, weight: .medium))
                    }

                    Spacer().frame(height: 24)

                    Text(deviceId)
                        .font(CelestiTypography.body(size: 28, weight: .medium))
                        .tracking(1.5)
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                .frame(minWidth: 810, maxWidth: 1290)
                .padding(.horizontal, 57)
                .padding(.vertical, 51)

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
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Launching demo mode…")
                .font(CelestiTypography.body(size: 30, weight: .medium))
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
                    PlayerContainerView(player: appModel.playerController.player)
                        .ignoresSafeArea()
                }
            }

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

private struct DemoOverlay: View {
    let isBuffering: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 18) {
            CelestiHeader()

            HStack {
                CelestiStatusPill(
                    text: isBuffering ? "DEMO BUFFERING" : "DEMO LIVE",
                    color: isBuffering ? .celestiDesert : Color(red: 217 / 255, green: 79 / 255, blue: 79 / 255)
                )

                Spacer()
            }
            .padding(.horizontal, 84)

            Spacer()
        }
        .background(
            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: Color.celestiBackground(for: colorScheme).opacity(0.95), location: 0),
                        .init(color: Color.celestiBackground(for: colorScheme).opacity(0.88), location: 0.2),
                        .init(color: Color.celestiBackground(for: colorScheme).opacity(0.62), location: 0.4),
                        .init(color: Color.celestiBackground(for: colorScheme).opacity(0.26), location: 0.6),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.4)
            },
            alignment: .top
        )
    }
}

private let barCount = 24

private struct FrequencyBar: Identifiable {
    let id: Int
    var height: CGFloat
}

private struct AudioVisualizer: View {
    @State private var bars: [CGFloat] = (0..<barCount).map { _ in CGFloat.random(in: 0.05...0.15) }
    @State private var targetBars: [CGFloat] = (0..<barCount).map { _ in CGFloat.random(in: 0.05...0.15) }
    let isBuffering: Bool
    let isActive: Bool

    private let barColor = Color(red: 217 / 255, green: 79 / 255, blue: 79 / 255)
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 3
            let barWidth = (size.width - gap * CGFloat(barCount + 1)) / CGFloat(barCount)
            guard barWidth > 0 else { return }

            for i in 0..<barCount {
                let h = max(0, bars[i] * size.height)
                guard h >= 1 else { continue }
                let alpha: CGFloat = 0.35 + (h / size.height) * 0.45
                let rect = CGRect(
                    x: gap + CGFloat(i) * (barWidth + gap),
                    y: size.height - h,
                    width: barWidth,
                    height: h
                )
                context.fill(Path(roundedRect: rect, cornerSize: CGSize(width: 1.5, height: 1.5)), with: .color(barColor.opacity(alpha.clamped(to: 0...0.8))))
            }
        }
        .onReceive(timer) { _ in
            updateBars()
        }
    }

    private func updateBars() {
        guard isActive else {
            for i in 0..<barCount {
                bars[i] *= 0.92
            }
            return
        }

        for i in 0..<barCount {
            if Bool.random(probability: 0.15) {
                let energy = isBuffering ? 0.4 : 1.0
                targetBars[i] = CGFloat.random(in: 0.05...0.7) * energy
            }
            bars[i] += (targetBars[i] - bars[i]) * 0.25
            bars[i] = max(0.02, bars[i])
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Bool {
    static func random(probability: Double) -> Bool {
        Double.random(in: 0...1) < probability
    }
}

private struct AudioPlaybackView: View {
    let playback: PlaybackPresentation

    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    var body: some View {
        ZStack {
            CelestiAmbientBackground(includeGradient: true)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.celestiPrimary(for: colorScheme).opacity(pulse ? 0.4 : 0.1), .clear],
                        center: .center,
                        startRadius: 18,
                        endRadius: 390
                    )
                )
                .frame(width: 690, height: 690)
                .scaleEffect(pulse ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: pulse)

            VStack(spacing: 0) {
                CelestiHeader()

                Spacer()

                VStack(spacing: 0) {
                    Text("LIVE RADIO")
                        .font(CelestiTypography.body(size: 18, weight: .bold))
                        .tracking(9)
                        .foregroundStyle(Color.celestiPrimary(for: colorScheme))

                    Spacer().frame(height: 21)

                    LinearGradient(
                        colors: [.clear, Color.celestiPrimary(for: colorScheme).opacity(0.8), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 510, height: 1.5)

                    Spacer().frame(height: 36)

                    Text(playback.radioName ?? "Connecting…")
                        .font(CelestiTypography.brand(size: 54, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineSpacing(12)

                    if let streamTitle = playback.streamTitle, !streamTitle.isEmpty {
                        Spacer().frame(height: 15)
                        Text(streamTitle)
                            .font(CelestiTypography.body(size: 27, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.primary.opacity(0.76))
                    }

                    Spacer().frame(height: 30)

                    CelestiStatusPill(
                        text: playback.isBuffering ? "BUFFERING" : "ON AIR",
                        color: playback.isBuffering ? .celestiDesert : Color(red: 217 / 255, green: 79 / 255, blue: 79 / 255)
                    )
                }
                .frame(minWidth: 600, maxWidth: 1200)
                .padding(48)
                .celestiCard(cornerRadius: 36)

                Spacer()
            }
            .padding(.bottom, 120)

            VStack {
                Spacer()
                AudioVisualizer(
                    isBuffering: playback.isBuffering,
                    isActive: !playback.isPlaybackFailed && !playback.isBuffering
                )
                .frame(height: 216)
            }
        }
        .onAppear {
            pulse = true
        }
    }
}

private struct CallsignOverlayView: View {
    let callsign: CallsignPresentation

    @State private var opacity: Double = 0

    private let fadeInDuration: Double = 0.5
    private let holdDuration: Double = 2.0
    private let fadeOutDuration: Double = 4.0

    var body: some View {
        GeometryReader { proxy in
            let hasNickname = callsign.nickname?.isEmpty == false
            let backdropHeight = max(hasNickname ? 330 : 260, proxy.size.height * 0.31)

            ZStack(alignment: .bottom) {
                // A real perimeter signal: crisp at the edge, soft toward the image.
                Rectangle()
                    .strokeBorder(Color.celestiSunset.opacity(0.9), lineWidth: 5)
                    .shadow(color: Color.celestiSunset.opacity(0.75), radius: 18)
                    .shadow(color: Color.celestiSunset.opacity(0.35), radius: 42)
                    .padding(3)

                // The scrim and content share one fixed-height region, so even a
                // two-line nickname can never escape into unprotected video.
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color.black.opacity(0.82), location: 0.3),
                            .init(color: Color.black.opacity(0.97), location: 0.62),
                            .init(color: Color.black.opacity(0.98), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    RadialGradient(
                        colors: [Color.celestiSunset.opacity(0.2), .clear],
                        center: .bottom,
                        startRadius: 0,
                        endRadius: proxy.size.width * 0.45
                    )

                    VStack(spacing: 15) {
                        if let nickname = callsign.nickname, !nickname.isEmpty {
                            Text(nickname)
                                .font(CelestiTypography.brand(size: 48, weight: .bold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.6)
                                .shadow(color: .black, radius: 8, y: 3)
                        }

                        Text(callsign.deviceCode.uppercased())
                            .font(CelestiTypography.body(size: 25, weight: .semibold))
                            .tracking(4)
                            .foregroundStyle(.white.opacity(0.92))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.45), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            )
                    }
                    .frame(maxWidth: 1500)
                    .padding(.horizontal, 120)
                    .padding(.bottom, 58)
                }
                .frame(height: backdropHeight)
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea()
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: fadeInDuration)) {
                opacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeInDuration + holdDuration) {
                withAnimation(.easeIn(duration: fadeOutDuration)) {
                    opacity = 0
                }
            }
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
