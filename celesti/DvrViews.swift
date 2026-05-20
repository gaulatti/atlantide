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
                    HStack(spacing: 16) {
                        let isLive = playback.duration <= 0

                        Text(isLive ? "LIVE" : formatTime(playback.currentTime))
                            .font(CelestiTypography.body(size: 16, weight: isLive ? .bold : .regular))
                            .foregroundStyle(isLive ? Color(red: 229 / 255, green: 57 / 255, blue: 57 / 255) : .white)
                            .monospacedDigit()

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.3))
                                    .frame(height: 6)

                                Capsule()
                                    .fill(isLive ? Color(red: 229 / 255, green: 57 / 255, blue: 57 / 255) : .white)
                                    .frame(width: max(6, proxy.size.width * progress), height: 6)
                            }
                        }
                        .frame(height: 6)

                        if !isLive {
                            Text(formatTime(playback.duration))
                                .font(CelestiTypography.body(size: 16))
                                .foregroundStyle(.white.opacity(0.7))
                                .monospacedDigit()
                        }

                        if playback.qualityTier >= 0, playback.qualityTier < Self.qualityLabels.count {
                            Text(Self.qualityLabels[playback.qualityTier])
                                .font(CelestiTypography.body(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 24)
                }
                .background(Color.black.opacity(0.6))
            }

            if dvrAction != .none {
                Text(actionSymbol)
                    .font(.system(size: 72))
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
                        .font(CelestiTypography.body(size: 12, weight: .bold))
                        .tracking(6)
                        .foregroundStyle(.white.opacity(0.6))

                    Spacer().frame(height: 14)

                    LinearGradient(
                        colors: [.clear, .white.opacity(0.4), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 340, height: 1)

                    Spacer().frame(height: 24)

                    Text(streamName ?? "Stream")
                        .font(CelestiTypography.brand(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(8)

                    Spacer().frame(height: 10)

                    Text("Could not connect to the stream.")
                        .font(CelestiTypography.body(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)

                    Spacer().frame(height: 24)

                    Text("Try again later.")
                        .font(CelestiTypography.body(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(minWidth: 400, maxWidth: 800)
                .padding(32)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                if let onRetry {
                    Spacer().frame(height: 32)
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.3))
                }
            }
        }
    }
}
