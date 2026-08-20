import Combine
import Foundation
import OSLog
import SwiftUI
import UIKit

private let emergencyLog = Logger(subsystem: "com.gaulatti.celesti", category: "EmergencyPlayer")

struct EmergencyChannel: Equatable, Identifiable {
    let slot: Int
    let channelId: String?
    let urlString: String
    let name: String?
    let logoURLString: String?

    var id: Int { slot }
    var identity: String {
        if let channelId, !channelId.isEmpty { return channelId }
        return urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class EmergencyPlayerController: ObservableObject {
    @Published private(set) var viewportPlayers: [QuadrantPlayer]
    @Published private(set) var visibleSlots: [Int?] = [nil, nil]
    @Published private(set) var healthySlots: [Int] = []
    @Published private(set) var assignedSlots: [Int] = []
    @Published private(set) var offlineSlots: Set<Int> = []
    @Published private(set) var focusedViewport = 0

    private var channels: [Int: EmergencyChannel] = [:]
    private var channelOrder: [Int] = []
    private var windowStartSlot: Int?
    private var probePlayers: [Int: QuadrantPlayer] = [:]

    init() {
        viewportPlayers = [
            QuadrantPlayer(quadrant: .topLeft, layoutMode: .emergency),
            QuadrantPlayer(quadrant: .topRight, layoutMode: .emergency),
        ]
        bindCallbacks()
    }

    var hasChannels: Bool { !channels.isEmpty }

    func play(
        slot: Int,
        channelId: String?,
        urlString: String,
        name: String?,
        logoURLString: String?
    ) async {
        guard (0..<8).contains(slot) else {
            emergencyLog.warning("Emergency pool position must be between 0 and 7: \(slot)")
            return
        }

        let channel = EmergencyChannel(
            slot: slot,
            channelId: channelId,
            urlString: urlString,
            name: name,
            logoURLString: logoURLString
        )
        if channels[slot] != channel {
            probePlayers.removeValue(forKey: slot)?.stop()
            offlineSlots.remove(slot)
        }
        if let duplicate = channels.values.first(where: {
            $0.slot != slot && $0.identity == channel.identity
        }) {
            emergencyLog.warning(
                "Ignoring duplicate emergency channel at position \(slot); already at \(duplicate.slot)"
            )
            channels.removeValue(forKey: slot)
            channelOrder.removeAll { $0 == slot }
            probePlayers.removeValue(forKey: slot)?.stop()
            offlineSlots.remove(slot)
            if windowStartSlot == slot { windowStartSlot = duplicate.slot }
            await renderWindow()
            return
        }

        if channels[slot] == nil { channelOrder.append(slot) }
        channels[slot] = channel
        if windowStartSlot == nil { windowStartSlot = slot }

        if let viewport = visibleSlots.firstIndex(where: { $0 == slot }) {
            await viewportPlayers[viewport].play(
                urlString: urlString,
                name: name,
                logoURLString: logoURLString,
                channelId: channelId
            )
            publishCarouselState()
        } else {
            await renderWindow()
        }
    }

    func stop(slot: Int? = nil) async {
        guard let slot else {
            stopAll()
            return
        }
        guard (0..<8).contains(slot) else { return }

        let wasFirst = visibleSlots[0] == slot
        channels.removeValue(forKey: slot)
        channelOrder.removeAll { $0 == slot }
        probePlayers.removeValue(forKey: slot)?.stop()
        offlineSlots.remove(slot)
        if wasFirst { windowStartSlot = visibleSlots[1] }
        await renderWindow()
    }

    func stopAll() {
        channels.removeAll()
        channelOrder.removeAll()
        probePlayers.values.forEach { $0.stop() }
        probePlayers.removeAll()
        offlineSlots.removeAll()
        windowStartSlot = nil
        visibleSlots = [nil, nil]
        healthySlots = []
        assignedSlots = []
        focusedViewport = 0
        viewportPlayers.forEach { $0.stop() }
        updateIdleTimer()
    }

    func restart(slot: Int) {
        if let probePlayer = probePlayers[slot] {
            probePlayer.restart()
            return
        }
        if let viewport = visibleSlots.firstIndex(where: { $0 == slot }) {
            viewportPlayers[viewport].restart()
        } else if channels[slot] != nil {
            windowStartSlot = slot
            Task { await renderWindow() }
        }
    }

    func restartFocused() {
        guard visibleSlots[focusedViewport] != nil else { return }
        viewportPlayers[focusedViewport].restart()
    }

    func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .left || direction == .right else { return }
        let lastVisibleViewport = visibleSlots[1] == nil ? 0 : 1
        let canMoveInsideWindow = direction == .left
            ? focusedViewport > 0
            : focusedViewport < lastVisibleViewport

        if canMoveInsideWindow {
            focusedViewport += direction == .right ? 1 : -1
            applyAudioFocus()
            return
        }

        Task { await rotateWindow(direction) }
    }

    func focusAudio(slot: Int) {
        guard channels[slot] != nil else { return }
        if let viewport = visibleSlots.firstIndex(where: { $0 == slot }) {
            focusedViewport = viewport
            applyAudioFocus()
        } else {
            windowStartSlot = slot
            focusedViewport = 0
            Task { await renderWindow() }
        }
    }

    func focusAudioOnSelected() {
        applyAudioFocus()
    }

    func adjustVolume(by percent: Int) {
        viewportPlayers.filter(\.isActive).forEach { $0.adjustVolume(by: percent) }
    }

    private func rotateWindow(_ direction: MoveCommandDirection) async {
        let healthy = healthyChannels()
        guard healthy.count > 2 else { return }
        let currentIndex = healthy.firstIndex(where: { $0.slot == windowStartSlot }) ?? 0
        let delta = direction == .right ? 1 : -1
        let nextIndex = (currentIndex + delta + healthy.count) % healthy.count
        windowStartSlot = healthy[nextIndex].slot
        await renderWindow()
    }

    private func healthyChannels() -> [EmergencyChannel] {
        EmergencyCarouselPolicy.healthySlots(
            assignedSlots: channelOrder,
            offlineSlots: offlineSlots
        ).compactMap { channels[$0] }
    }

    private func renderWindow() async {
        let healthy = healthyChannels()
        guard !healthy.isEmpty else {
            visibleSlots = [nil, nil]
            viewportPlayers.forEach { $0.stop() }
            windowStartSlot = nil
            focusedViewport = 0
            publishCarouselState()
            return
        }

        let startIndex = healthy.firstIndex(where: { $0.slot == windowStartSlot }) ?? 0
        windowStartSlot = healthy[startIndex].slot
        let targets: [EmergencyChannel?] = [
            healthy[startIndex],
            healthy.count > 1 ? healthy[(startIndex + 1) % healthy.count] : nil,
        ]

        if targets[0]?.slot == visibleSlots[1] || targets[1]?.slot == visibleSlots[0] {
            viewportPlayers.swapAt(0, 1)
            visibleSlots.swapAt(0, 1)
        }

        for viewport in 0..<2 {
            guard let channel = targets[viewport] else {
                if visibleSlots[viewport] != nil { viewportPlayers[viewport].stop() }
                visibleSlots[viewport] = nil
                continue
            }
            if visibleSlots[viewport] != channel.slot {
                viewportPlayers[viewport].stop()
                visibleSlots[viewport] = channel.slot
                await viewportPlayers[viewport].play(
                    urlString: channel.urlString,
                    name: channel.name,
                    logoURLString: channel.logoURLString,
                    channelId: channel.channelId
                )
            }
        }

        focusedViewport = min(focusedViewport, visibleSlots[1] == nil ? 0 : 1)
        applyAudioFocus()
        publishCarouselState()
    }

    private func bindCallbacks() {
        for player in viewportPlayers {
            player.onPlaybackFailure = { [weak self, weak player] reason in
                guard let self, let player else { return }
                self.handlePlaybackFailure(player: player, reason: reason)
            }
            player.onStableRecovery = { [weak self, weak player] in
                guard let self, let player else { return }
                self.handleStableRecovery(player: player)
            }
        }
    }

    private func handlePlaybackFailure(player: QuadrantPlayer, reason: String?) {
        guard let viewport = viewportPlayers.firstIndex(where: { $0 === player }),
              let failedSlot = visibleSlots[viewport] else { return }

        let failureReason = reason ?? "unknown"
        offlineSlots.insert(failedSlot)
        probePlayers[failedSlot] = player
        let replacement = QuadrantPlayer(
            quadrant: viewport == 0 ? .topLeft : .topRight,
            layoutMode: .emergency
        )
        viewportPlayers[viewport] = replacement
        visibleSlots[viewport] = nil
        bindCallbacks(for: replacement)
        emergencyLog.error(
            "Emergency position \(failedSlot) remains assigned and will be probed again; reason=\(failureReason)"
        )
        Task { await renderWindow() }
    }

    private func handleStableRecovery(player: QuadrantPlayer) {
        guard let recoveredSlot = probePlayers.first(where: { $0.value === player })?.key else {
            return
        }
        probePlayers.removeValue(forKey: recoveredSlot)
        offlineSlots.remove(recoveredSlot)
        player.stop()
        if windowStartSlot == nil { windowStartSlot = recoveredSlot }
        emergencyLog.info("Emergency position \(recoveredSlot) recovered and returned to the carousel")
        Task { await renderWindow() }
    }

    private func bindCallbacks(for player: QuadrantPlayer) {
        player.onPlaybackFailure = { [weak self, weak player] reason in
            guard let self, let player else { return }
            self.handlePlaybackFailure(player: player, reason: reason)
        }
        player.onStableRecovery = { [weak self, weak player] in
            guard let self, let player else { return }
            self.handleStableRecovery(player: player)
        }
    }

    private func applyAudioFocus() {
        for (viewport, player) in viewportPlayers.enumerated() {
            player.setMuted(viewport != focusedViewport)
        }
    }

    private func publishCarouselState() {
        assignedSlots = channelOrder.filter { channels[$0] != nil }
        healthySlots = healthyChannels().map(\.slot)
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !channels.isEmpty
    }

}
