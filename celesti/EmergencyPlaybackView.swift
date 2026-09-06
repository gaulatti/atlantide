import AVFoundation
import Combine
import KSPlayer
import Sabella
import SwiftUI
import UIKit

struct EmergencyPlaybackView: View {
    @EnvironmentObject private var appModel: CelestiAppModel
    @StateObject private var ticker = EmergencyTickerModel()

    var body: some View {
        SabellaTVEmergencyLayout(
            allOffline: !appModel.emergencyPlayerController.assignedSlots.isEmpty
                && appModel.emergencyPlayerController.healthySlots.isEmpty
        ) {
                HStack(spacing: 0) {
                    channelCell(viewport: 0)
                    channelCell(viewport: 1)
                }
                .overlay(alignment: .bottom) {
                    if appModel.emergencyPlayerController.healthySlots.count > 2 {
                        SabellaTVCarouselDots(
                            items: appModel.emergencyPlayerController.healthySlots,
                            active: Set(appModel.emergencyPlayerController.visibleSlots.compactMap { $0 })
                        ).offset(y: 48)
                    }
                }
        } ticker: {
            SabellaTVMarquee(items: ticker.programItems)
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
        let player = controller.viewportPlayers[viewport]
        return SabellaTVBroadcastCell(
            selected: controller.visibleSlots[viewport] != nil && controller.focusedViewport == viewport,
            selectionColor: BleeckerPalette.dark.accentYellow,
            failure: player.isFailed ? "\(player.failureStatus) · \(player.streamName ?? "Stream")" : nil,
            buffering: player.isBuffering
        ) {
            ZStack {
                if let coordinator = player.ksCoordinator, let url = player.currentURL {
                    KSVideoPlayer(coordinator: coordinator, url: url, options: KSOptions()).opacity(player.isUsingKSPlayer ? 1 : 0)
                }
                SabellaTVPlayerSurface(player: player.avPlayer).opacity(player.isUsingKSPlayer ? 0 : 1)
            }
        } placeholder: {
            if !player.isActive || player.isAudioOnly {
                SabellaTVTestPattern(title: player.isActive ? (player.streamName ?? "Audio feed") : "No stream", logoURL: player.logoURL, audioLevel: player.samplePeak)
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
