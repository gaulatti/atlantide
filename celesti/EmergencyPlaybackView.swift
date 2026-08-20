import AVFoundation
import Combine
import SwiftUI
import UIKit

struct EmergencyPlaybackView: View {
    @EnvironmentObject private var appModel: CelestiAppModel
    @StateObject private var ticker = EmergencyTickerModel()

    var body: some View {
        GeometryReader { proxy in
            let channelHeight = min(proxy.size.width / 2 * 9 / 16, proxy.size.height - 144)
            let headerTop = max(0, ((proxy.size.height - channelHeight) / 2 - 64) / 2)

            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(red: 184 / 255, green: 17 / 255, blue: 34 / 255),
                        Color(red: 102 / 255, green: 5 / 255, blue: 18 / 255),
                        Color(red: 31 / 255, green: 0, blue: 6 / 255),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                EmergencyHeader()
                    .frame(height: 64)
                    .offset(y: headerTop)

                HStack(spacing: 0) {
                    channelCell(viewport: 0)
                    channelCell(viewport: 1)
                }
                .frame(width: proxy.size.width, height: channelHeight)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                if !appModel.emergencyPlayerController.assignedSlots.isEmpty,
                   appModel.emergencyPlayerController.healthySlots.isEmpty {
                    VStack(spacing: 12) {
                        Text("ALL ASSIGNED FEEDS OFFLINE")
                            .font(.custom("EncodeSans-Bold", size: 30))
                        Text("Automatic recovery checks are running")
                            .font(.custom("LibreFranklin-Medium", size: 20))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }

                if appModel.emergencyPlayerController.healthySlots.count > 2 {
                    EmergencyCarouselDots(
                        healthySlots: appModel.emergencyPlayerController.healthySlots,
                        visibleSlots: appModel.emergencyPlayerController.visibleSlots
                    )
                    .frame(height: 24)
                    .position(x: proxy.size.width / 2, y: proxy.size.height - 66)
                }

                EmergencyMarqueeRepresentable(model: ticker)
                    .frame(width: proxy.size.width, height: 48)
                    .clipped()
                    .position(x: proxy.size.width / 2, y: proxy.size.height - 24)
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            appModel.emergencyPlayerController.moveSelection(direction)
        }
        .onTapGesture {
            appModel.emergencyPlayerController.focusAudioOnSelected()
        }
        .onPlayPauseCommand {
            appModel.emergencyPlayerController.focusAudioOnSelected()
        }
        .onLongPressGesture {
            appModel.emergencyPlayerController.restartFocused()
        }
        .onExitCommand {
            appModel.dismissPlayback()
        }
        .onAppear { ticker.start() }
        .onDisappear { ticker.stop() }
    }

    private func channelCell(viewport: Int) -> some View {
        let controller = appModel.emergencyPlayerController
        return QuadrantCell(
            quadrant: viewport == 0 ? .topLeft : .topRight,
            player: controller.viewportPlayers[viewport],
            isSelected: controller.visibleSlots[viewport] != nil
                && controller.focusedViewport == viewport,
            selectionColor: Color(red: 1, green: 213 / 255, blue: 79 / 255)
        )
    }
}

private struct EmergencyHeader: View {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                HStack {
                    Text(Self.dateFormatter.string(from: context.date))
                        .font(.custom("EncodeSans-Bold", size: 24))
                        .tracking(1.44)

                    Spacer()

                    Text(Self.timeFormatter.string(from: context.date))
                        .font(.custom("IBMPlexMono-Bold", size: 28))
                        .tracking(2.24)
                }
                .padding(.horizontal, 48)

                Image("logo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 46)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 8)
        }
    }
}

private struct EmergencyCarouselDots: View {
    let healthySlots: [Int]
    let visibleSlots: [Int?]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(healthySlots, id: \.self) { slot in
                let active = visibleSlots.contains(where: { $0 == slot })
                Circle()
                    .fill(Color.white.opacity(active ? 1 : 0.4))
                    .frame(width: active ? 8 : 6, height: active ? 8 : 6)
            }
        }
    }
}

@MainActor
private final class EmergencyTickerModel: ObservableObject {
    @Published private(set) var programItems: [String] = []
    private var previewItems: [String] = []
    private var refreshTask: Task<Void, Never>?

    var hasPreviewProgram: Bool {
        !previewItems.isEmpty && previewItems != programItems
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if let items = await self?.fetchHeadlines(), !items.isEmpty {
                    self?.updatePreview(items)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func promotePreview() -> [String]? {
        guard hasPreviewProgram else { return nil }
        programItems = previewItems
        return programItems
    }

    private func updatePreview(_ items: [String]) {
        previewItems = items
        if programItems.isEmpty {
            programItems = previewItems
        }
    }

    private func fetchHeadlines() async -> [String] {
        guard let url = URL(
            string: "https://api.monitor.gaulatti.com/posts/grouped?categories=relevant"
        ) else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return [] }
            let groups = try JSONDecoder().decode([MonitorGroup].self, from: data)
            var seen: Set<String> = []
            return groups
                .flatMap { $0.posts ?? [] }
                .compactMap { post -> String? in
                    let content = post.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard (post.relevance ?? 0) >= 7, !content.isEmpty else { return nil }
                    let author = post.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return author.isEmpty ? content : "\(author.uppercased()): \(content)"
                }
                .filter { seen.insert($0).inserted }
                .prefix(40)
                .map { $0 }
        } catch {
            return []
        }
    }
}

private struct MonitorGroup: Decodable, Sendable {
    let posts: [MonitorPost]?
}

private struct MonitorPost: Decodable, Sendable {
    let relevance: Double?
    let content: String?
    let author: String?
}

private struct EmergencyMarqueeRepresentable: UIViewRepresentable {
    @ObservedObject var model: EmergencyTickerModel

    func makeUIView(context: Context) -> EmergencyMarqueeUIView {
        let view = EmergencyMarqueeUIView()
        view.shouldDrainProgram = { [weak model] in model?.hasPreviewProgram == true }
        view.promotePreview = { [weak model] in model?.promotePreview() }
        view.setProgram(model.programItems, enterFromRight: false)
        return view
    }

    func updateUIView(_ uiView: EmergencyMarqueeUIView, context: Context) {
        uiView.setProgram(model.programItems, enterFromRight: uiView.hasProgram)
    }

    static func dismantleUIView(_ uiView: EmergencyMarqueeUIView, coordinator: ()) {
        uiView.stop()
    }
}

@MainActor
private final class EmergencyMarqueeUIView: UIView {
    private let label = UILabel()
    private var items: [String] = []
    private var cycleWidth: CGFloat = 0
    private var animationGeneration = 0
    private var pendingEntrance = false
    private var waitingForLayout = false

    var shouldDrainProgram: (() -> Bool)?
    var promotePreview: (() -> [String]?)?
    var hasProgram: Bool { !items.isEmpty }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        label.numberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(
            x: 0,
            y: (bounds.height - label.intrinsicContentSize.height) / 2,
            width: max(cycleWidth * 2, 1),
            height: label.intrinsicContentSize.height
        )
        if waitingForLayout, bounds.width > 0 {
            waitingForLayout = false
            startProgram(enterFromRight: pendingEntrance)
        }
    }

    func setProgram(_ nextItems: [String], enterFromRight: Bool) {
        guard !nextItems.isEmpty, nextItems != items else { return }
        items = nextItems
        animationGeneration += 1
        label.layer.removeAllAnimations()
        label.transform = .identity

        let cycle = makeStyledCycle(items)
        let doubled = NSMutableAttributedString(attributedString: cycle)
        doubled.append(cycle)
        label.attributedText = doubled
        cycleWidth = ceil(cycle.size().width)
        pendingEntrance = enterFromRight
        waitingForLayout = true
        setNeedsLayout()
        layoutIfNeeded()
    }

    func stop() {
        animationGeneration += 1
        label.layer.removeAllAnimations()
    }

    private func startProgram(enterFromRight: Bool) {
        if enterFromRight {
            startEntrance()
        } else {
            startLoop()
        }
    }

    private func startLoop() {
        let generation = animationGeneration
        label.transform = .identity
        UIView.animate(
            withDuration: duration(for: cycleWidth),
            delay: 0,
            options: [.curveLinear, .allowUserInteraction],
            animations: {
                self.label.transform = CGAffineTransform(translationX: -self.cycleWidth, y: 0)
            },
            completion: { [weak self] finished in
                guard let self, finished, generation == self.animationGeneration else { return }
                if self.shouldDrainProgram?() == true {
                    self.startDrain()
                } else {
                    self.startLoop()
                }
            }
        )
    }

    private func startDrain() {
        let generation = animationGeneration
        label.transform = CGAffineTransform(translationX: -cycleWidth, y: 0)
        UIView.animate(
            withDuration: duration(for: cycleWidth),
            delay: 0,
            options: [.curveLinear, .allowUserInteraction],
            animations: {
                self.label.transform = CGAffineTransform(translationX: -self.cycleWidth * 2, y: 0)
            },
            completion: { [weak self] finished in
                guard let self, finished, generation == self.animationGeneration else { return }
                if let nextProgram = self.promotePreview?() {
                    self.setProgram(nextProgram, enterFromRight: true)
                } else {
                    self.startLoop()
                }
            }
        )
    }

    private func startEntrance() {
        let generation = animationGeneration
        label.transform = CGAffineTransform(translationX: bounds.width, y: 0)
        UIView.animate(
            withDuration: duration(for: bounds.width),
            delay: 0,
            options: [.curveLinear, .allowUserInteraction],
            animations: {
                self.label.transform = .identity
            },
            completion: { [weak self] finished in
                guard let self, finished, generation == self.animationGeneration else { return }
                self.startLoop()
            }
        )
    }

    private func duration(for distance: CGFloat) -> TimeInterval {
        max(1, distance / 60)
    }

    private func makeStyledCycle(_ items: [String]) -> NSAttributedString {
        let baseFont = UIFont(name: "EncodeSans-Regular", size: 20)
            ?? UIFont.systemFont(ofSize: 20)
        let outletFont = UIFont(name: "EncodeSans-Bold", size: 20)
            ?? UIFont.boldSystemFont(ofSize: 20)
        let result = NSMutableAttributedString()

        for item in items {
            let segment = NSMutableAttributedString(
                string: item,
                attributes: [.font: baseFont, .foregroundColor: UIColor.white]
            )
            if let separator = item.range(of: ": ") {
                let authorLength = item.distance(from: item.startIndex, to: separator.lowerBound)
                segment.addAttribute(
                    .font,
                    value: outletFont,
                    range: NSRange(location: 0, length: authorLength)
                )
            }
            result.append(segment)
            result.append(
                NSAttributedString(
                    string: "     ◆     ",
                    attributes: [.font: baseFont, .foregroundColor: UIColor.white]
                )
            )
        }
        return result
    }
}
