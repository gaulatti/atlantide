import SwiftUI

extension Color {
    static let celestiLightSand = Color(red: 249 / 255, green: 246 / 255, blue: 242 / 255)
    static let celestiSand = Color(red: 230 / 255, green: 213 / 255, blue: 184 / 255)
    static let celestiDesert = Color(red: 193 / 255, green: 129 / 255, blue: 77 / 255)
    static let celestiSunset = Color(red: 1.0, green: 150 / 255, blue: 119 / 255)
    static let celestiSea = Color(red: 44 / 255, green: 87 / 255, blue: 132 / 255)
    static let celestiTextPrimary = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
    static let celestiDarkBackground = Color(red: 13 / 255, green: 24 / 255, blue: 33 / 255)
    static let celestiDarkSurface = Color(red: 26 / 255, green: 35 / 255, blue: 50 / 255)
    static let celestiDarkText = Color(red: 240 / 255, green: 244 / 255, blue: 248 / 255)
}

enum CelestiTypography {
    static func brand(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        switch weight {
        case .bold, .semibold:
            return .custom("EncodeSans-SemiBold", size: size)
        default:
            return .custom("EncodeSans-Regular", size: size)
        }
    }

    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .bold:
            return .custom("LibreFranklin-Medium", size: size)
        case .medium, .semibold:
            return .custom("LibreFranklin-Medium", size: size)
        default:
            return .custom("LibreFranklin-Regular", size: size)
        }
    }
}

struct CelestiCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

extension View {
    func celestiCard(cornerRadius: CGFloat = 28) -> some View {
        modifier(CelestiCardModifier(cornerRadius: cornerRadius))
    }
}

struct CelestiStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(text)
                .font(CelestiTypography.body(size: 12, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.primary.opacity(0.82))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

struct CelestiHeader: View {
    var body: some View {
        HStack {
            HStack(spacing: 16) {
                CelestiBrandMark()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color.primary.opacity(0.9))

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.primary.opacity(0), Color.primary.opacity(0.8), Color.primary.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1, height: 32)

                Text("celesti")
                    .font(CelestiTypography.brand(size: 24, weight: .bold))
                    .foregroundStyle(Color.primary)
            }

            Spacer()

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(CelestiTypography.body(size: 16, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.primary.opacity(0.76))
            }
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 38)
    }
}

struct CelestiBrandMark: Shape {
    func path(in rect: CGRect) -> Path {
        let diameter = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = diameter * 0.46
        let innerRadius = diameter * 0.18

        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
        path.addEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))

        let wedges: [(CGFloat, CGFloat)] = [(-140, -40), (40, 140)]
        for (startDegrees, endDegrees) in wedges {
            var wedge = Path()
            wedge.addArc(center: center, radius: outerRadius, startAngle: .degrees(startDegrees), endAngle: .degrees(endDegrees), clockwise: false)
            wedge.addArc(center: center, radius: diameter * 0.64, startAngle: .degrees(endDegrees), endAngle: .degrees(startDegrees), clockwise: true)
            wedge.closeSubpath()
            path.addPath(wedge)
        }

        return path.eoFilled()
    }
}

private extension Path {
    func eoFilled() -> Path {
        var copy = self
        copy = copy.strokedPath(.init(lineWidth: 0))
        return self
    }
}

struct CelestiAmbientBackground: View {
    let includeGradient: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var animate = false

    private var backgroundBase: Color {
        colorScheme == .dark ? .celestiDarkBackground : .celestiLightSand
    }

    var body: some View {
        ZStack {
            backgroundBase
                .ignoresSafeArea()

            if includeGradient {
                LinearGradient(
                    colors: [
                        Color.primary.opacity(animate ? 0.25 : 0.12),
                        Color.celestiSunset.opacity(animate ? 0.12 : 0.04),
                        backgroundBase
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .animation(.linear(duration: 8).repeatForever(autoreverses: true), value: animate)
            }
        }
        .onAppear {
            animate = true
        }
    }
}
