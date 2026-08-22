import AVFoundation
import KSPlayer
import SwiftUI

struct QuadPlaybackView: View {
    @EnvironmentObject private var appModel: CelestiAppModel

    var body: some View {
        Group {
            if let expanded = appModel.quadPlayerController.expandedQuadrant {
                cell(expanded)
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        cell(.topLeft)
                        cell(.topRight)
                    }
                    HStack(spacing: 6) {
                        cell(.bottomLeft)
                        cell(.bottomRight)
                    }
                }
            }
        }
        .background(Color.white.opacity(0.533))
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard appModel.quadPlayerController.expandedQuadrant == nil else { return }
            appModel.quadPlayerController.moveFocus(direction: direction)
        }
        .onTapGesture {
            guard appModel.quadPlayerController.expandedQuadrant == nil else { return }
            appModel.quadPlayerController.showFocusedSingleView()
        }
        .onPlayPauseCommand {
            appModel.quadPlayerController.toggleMuteFocused()
        }
        .onLongPressGesture {
            appModel.quadPlayerController.restartFocused()
        }
        .onExitCommand {
            if !appModel.quadPlayerController.restoreQuadView() {
                appModel.dismissPlayback()
            }
        }
    }

    private func cell(_ quadrant: Quadrant) -> some View {
        QuadrantCell(
            quadrant: quadrant,
            player: appModel.quadPlayerController.player(for: quadrant),
            isSelected: appModel.quadPlayerController.expandedQuadrant == nil
                && appModel.quadPlayerController.isFocusBorderVisible
                && appModel.quadPlayerController.focusedQuadrant == quadrant
        )
    }
}

struct QuadrantCell: View {
    let quadrant: Quadrant
    @ObservedObject var player: QuadrantPlayer
    let isSelected: Bool
    var selectionColor = Color(red: 229 / 255, green: 57 / 255, blue: 53 / 255)

    var body: some View {
        ZStack {
            Color.black

            ZStack {
                if let coordinator = player.ksCoordinator,
                   let url = player.currentURL {
                    KSVideoPlayer(coordinator: coordinator, url: url, options: KSOptions())
                        .opacity(player.isUsingKSPlayer ? 1 : 0)
                }
                AVVideoPlayerView(player: player.avPlayer)
                    .opacity(player.isUsingKSPlayer ? 0 : 1)
            }

            if !player.isActive || player.isAudioOnly {
                QuadTestPatternView(
                    title: player.isActive ? (player.streamName ?? "Audio feed") : "No stream",
                    logoURL: player.logoURL,
                    isAudioOnly: player.isAudioOnly,
                    samplePeak: player.samplePeak
                )
            }

            if player.isFailed {
                Color(red: 139 / 255, green: 0, blue: 0)
                    .opacity(0.85)
                VStack(spacing: 12) {
                    Text(player.failureStatus)
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

        }
        .clipped()
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(selectionColor, lineWidth: 6)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct QuadTestPatternView: View {
    let title: String
    let logoURL: URL?
    let isAudioOnly: Bool
    let samplePeak: () -> Float

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        drawPattern(in: context, size: size, date: timeline.date, peak: samplePeak())
                    }
                }

                if let logoURL {
                    AsyncImage(url: logoURL) { phase in
                        identityCard {
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                VStack(spacing: 12) {
                                    Image("logo")
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .foregroundStyle(.black)
                                    Text(title)
                                        .font(.system(size: 18, weight: .regular))
                                        .foregroundStyle(Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255))
                                        .multilineTextAlignment(.center)
                                }
                            }
                        }
                    }
                } else {
                    identityCard {
                        VStack(spacing: 12) {
                            Image("logo")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.black)
                            Text(title)
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
        }
    }

    private func identityCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: 220, height: 150)
            .background(Color(red: 244 / 255, green: 244 / 255, blue: 244 / 255).opacity(0.92))
    }

    private func drawPattern(in context: GraphicsContext, size: CGSize, date: Date, peak: Float) {
        let width = size.width
        let height = size.height
        let dark = Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 212 / 255, green: 212 / 255, blue: 212 / 255)))

        var grid = Path()
        for step in 1...5 {
            grid.move(to: CGPoint(x: 0, y: height * CGFloat(step) / 6))
            grid.addLine(to: CGPoint(x: width, y: height * CGFloat(step) / 6))
            grid.move(to: CGPoint(x: width * CGFloat(step) / 6, y: 0))
            grid.addLine(to: CGPoint(x: width * CGFloat(step) / 6, y: height))
        }
        context.stroke(grid, with: .color(Color(red: 160 / 255, green: 160 / 255, blue: 160 / 255)), lineWidth: 1)

        context.fill(Path(CGRect(x: 0, y: 0, width: width, height: height * 0.075)), with: .color(dark))
        context.draw(
            Text(Self.dateFormatter.string(from: date)).font(.system(size: min(width, height) * 0.04)).foregroundStyle(.white),
            at: CGPoint(x: width * 0.03, y: height * 0.0375),
            anchor: .leading
        )
        context.draw(
            Text(Self.timeFormatter.string(from: date)).font(.system(size: min(width, height) * 0.04)).foregroundStyle(.white),
            at: CGPoint(x: width * 0.97, y: height * 0.0375),
            anchor: .trailing
        )

        let barColors: [Color] = [
            Color(red: 243 / 255, green: 229 / 255, blue: 44 / 255),
            Color(red: 61 / 255, green: 212 / 255, blue: 223 / 255),
            Color(red: 60 / 255, green: 189 / 255, blue: 78 / 255),
            Color(red: 206 / 255, green: 75 / 255, blue: 186 / 255),
            Color(red: 216 / 255, green: 80 / 255, blue: 79 / 255),
            Color(red: 55 / 255, green: 102 / 255, blue: 199 / 255)
        ]
        let barWidth = width * 0.095
        let barStart = (width - barWidth * CGFloat(barColors.count)) / 2
        for (index, color) in barColors.enumerated() {
            context.fill(
                Path(CGRect(x: barStart + barWidth * CGFloat(index), y: height * 0.075, width: barWidth, height: height * 0.095)),
                with: .color(color)
            )
        }

        let radius = min(width, height) * 0.34
        let center = CGPoint(x: width / 2, y: height / 2)
        let outerCircle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let innerRadius = radius * 0.74
        let innerCircle = CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
        context.fill(Path(ellipseIn: outerCircle), with: .color(Color(red: 244 / 255, green: 244 / 255, blue: 244 / 255)))
        context.stroke(Path(ellipseIn: outerCircle), with: .color(dark), lineWidth: 3)
        context.stroke(Path(ellipseIn: innerCircle), with: .color(dark), lineWidth: 1.5)
        var crosshair = Path()
        crosshair.move(to: CGPoint(x: center.x - radius, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - radius))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        context.stroke(crosshair, with: .color(dark), lineWidth: 1.5)

        let grayValues: [Double] = [245, 200, 150, 100, 55, 15]
        let grayWidth = width * 0.095
        let grayStart = (width - grayWidth * CGFloat(grayValues.count)) / 2
        for (index, value) in grayValues.enumerated() {
            context.fill(
                Path(CGRect(x: grayStart + grayWidth * CGFloat(index), y: height * 0.84, width: grayWidth, height: height * 0.08)),
                with: .color(Color(white: value / 255))
            )
        }

        context.fill(Path(CGRect(x: 0, y: 0, width: width * 0.014, height: height)), with: .color(dark))
        let displayedPeak = isAudioOnly ? min(1, max(0, CGFloat(peak))) : 0
        let meterColor: Color = displayedPeak > 0.9
            ? Color(red: 210 / 255, green: 40 / 255, blue: 40 / 255)
            : displayedPeak > 0.7
                ? Color(red: 220 / 255, green: 150 / 255, blue: 25 / 255)
                : Color(red: 35 / 255, green: 155 / 255, blue: 85 / 255)
        context.fill(
            Path(CGRect(x: 0, y: height * (1 - displayedPeak), width: width * 0.014, height: height * displayedPeak)),
            with: .color(meterColor)
        )
    }
}

struct AVVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> AVPlayerSurfaceView {
        let view = AVPlayerSurfaceView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: AVPlayerSurfaceView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class AVPlayerSurfaceView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            preconditionFailure("AVPlayerSurfaceView must use AVPlayerLayer")
        }
        return playerLayer
    }
}
