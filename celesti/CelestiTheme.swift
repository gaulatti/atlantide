import SwiftUI

extension Color {
    static let celestiLightSand = Color(red: 249 / 255, green: 246 / 255, blue: 242 / 255)
    static let celestiSand = Color(red: 230 / 255, green: 213 / 255, blue: 184 / 255)
    static let celestiDesert = Color(red: 193 / 255, green: 129 / 255, blue: 77 / 255)
    static let celestiSunset = Color(red: 1.0, green: 150 / 255, blue: 119 / 255)
    static let celestiSea = Color(red: 44 / 255, green: 87 / 255, blue: 132 / 255)
    static let celestiDarkModeAccentBlue = Color(red: 91 / 255, green: 163 / 255, blue: 245 / 255)
    static let celestiTextPrimary = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
    static let celestiDarkBackground = Color(red: 13 / 255, green: 24 / 255, blue: 33 / 255)
    static let celestiDarkSurface = Color(red: 26 / 255, green: 35 / 255, blue: 50 / 255)
    static let celestiDarkText = Color(red: 240 / 255, green: 244 / 255, blue: 248 / 255)

    static func celestiPrimary(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .celestiDarkModeAccentBlue : .celestiSea
    }

    static func celestiSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .celestiDarkSurface : .celestiSand
    }

    static func celestiBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .celestiDarkBackground : .celestiLightSand
    }
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
    var cornerRadius: CGFloat = 42
    
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(Color.celestiSurface(for: colorScheme).opacity(0.05), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1.5)
            )
    }
}

extension View {
    func celestiCard(cornerRadius: CGFloat = 42) -> some View {
        modifier(CelestiCardModifier(cornerRadius: cornerRadius))
    }
}

struct CelestiStatusPill: View {
    let text: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 15) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)

            Text(text)
                .font(CelestiTypography.body(size: 18, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Color.primary.opacity(0.82))
        }
        .padding(.horizontal, 21)
        .padding(.vertical, 10.5)
        .background(Color.celestiSurface(for: colorScheme).opacity(0.35), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1.5))
    }
}

struct CelestiHeader: View {
    var body: some View {
        HStack {
            HStack(spacing: 24) {
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .foregroundStyle(Color.primary.opacity(0.9))

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.primary.opacity(0), Color.primary.opacity(0.8), Color.primary.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1.5, height: 48)

                Text("celesti")
                    .font(CelestiTypography.brand(size: 36, weight: .bold))
                    .foregroundStyle(Color.primary)
            }

            Spacer()

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(CelestiTypography.body(size: 24, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(Color.primary.opacity(0.76))
            }
        }
        .padding(.horizontal, 84)
        .padding(.vertical, 57)
    }
}

struct CelestiAmbientBackground: View {
    let includeGradient: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var animateBg1 = false
    @State private var animateBg2 = false

    private var backgroundBase: Color {
        Color.celestiBackground(for: colorScheme)
    }

    private var themePrimary: Color {
        Color.celestiPrimary(for: colorScheme)
    }

    var body: some View {
        ZStack {
            backgroundBase
                .ignoresSafeArea()

            if includeGradient {
                LinearGradient(
                    stops: [
                        .init(color: animateBg1 ? themePrimary.opacity(0.28) : backgroundBase, location: 0),
                        .init(color: animateBg2 ? backgroundBase : themePrimary.opacity(0.22), location: 0.5),
                        .init(color: backgroundBase, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .onAppear {
                    withAnimation(.linear(duration: 8).repeatForever(autoreverses: true)) {
                        animateBg1 = true
                    }
                    withAnimation(.linear(duration: 12).repeatForever(autoreverses: true)) {
                        animateBg2 = true
                    }
                }
            }
        }
    }
}
