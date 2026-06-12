import AVFoundation
import SwiftUI

struct DvrOverlayView: View {
    let playback: PlaybackPresentation
    let player: AVPlayer
    let dvrAction: DvrAction

    private static let qualityLabels = ["AUTO", "HD", "SD", "MED", "LOW", "MIN"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 0) {
                    HStack(spacing: 24) {
                        let isLive = playback.duration <= 0

                        Text(isLive ? "LIVE" : formatTime(playback.currentTime))
                            .font(CelestiTypography.body(size: 24, weight: isLive ? .bold : .regular))
                            .foregroundStyle(isLive ? Color(red: 229 / 255, green: 57 / 255, blue: 53 / 255) : .white)
                            .monospacedDigit()

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.3))
                                    .frame(height: 9)

                                Capsule()
                                    .fill(isLive ? Color(red: 229 / 255, green: 57 / 255, blue: 53 / 255) : .white)
                                    .frame(width: max(9, proxy.size.width * progress), height: 9)
                            }
                        }
                        .frame(height: 9)

                        if !isLive {
                            Text(formatTime(playback.duration))
                                .font(CelestiTypography.body(size: 24))
                                .foregroundStyle(.white.opacity(0.7))
                                .monospacedDigit()
                        }

                        if playback.qualityTier >= 0, playback.qualityTier < Self.qualityLabels.count {
                            Text(Self.qualityLabels[playback.qualityTier])
                                .font(CelestiTypography.body(size: 18))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                                )
                        }
                    }
                    .padding(.horizontal, 72)
                    .padding(.vertical, 36)
                }
                .background(Color.black.opacity(0.6))
            }

            if dvrAction != .none {
                Text(actionSymbol)
                    .font(.system(size: 108))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var progress: CGFloat {
        guard playback.duration > 0 else { return 1 }
        return CGFloat(playback.currentTime / playback.duration).clamped(to: 0...1)
    }

    private var actionSymbol: String {
        switch dvrAction {
        case .play: return "\u{25B6}"
        case .pause: return "\u{23F8}"
        case .rewind: return "\u{23EE}"
        case .fastForward: return "\u{23ED}"
        case .none: return ""
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

struct PlaybackFailedView: View {
    let streamName: String?
    let onRetry: (() -> Void)?

    var body: some View {
        ZStack {
            Color(red: 139 / 255, green: 0, blue: 0)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text("PLAYBACK FAILED")
                        .font(CelestiTypography.body(size: 18, weight: .bold))
                        .tracking(9)
                        .foregroundStyle(.white.opacity(0.6))

                    Spacer().frame(height: 21)

                    LinearGradient(
                        colors: [.clear, .white.opacity(0.4), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 510, height: 1.5)

                    Spacer().frame(height: 36)

                    Text(streamName ?? "Stream")
                        .font(CelestiTypography.brand(size: 54, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(12)

                    Spacer().frame(height: 15)

                    Text("Could not connect to the stream.")
                        .font(CelestiTypography.body(size: 27, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)

                    Spacer().frame(height: 36)

                    Text("Try again later.")
                        .font(CelestiTypography.body(size: 21))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(minWidth: 600, maxWidth: 1200)
                .padding(48)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 36, style: .continuous))

                if let onRetry {
                    Spacer().frame(height: 48)
                    Button("Retry", action: onRetry)
                        .font(CelestiTypography.brand(size: 27))
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.3))
                }
            }
        }
    }
}
