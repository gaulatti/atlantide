import AVFoundation
import Combine
import Foundation
import OSLog
import SwiftUI
import UIKit
import VLCKitSPM

private let quadLog = Logger(subsystem: "com.gaulatti.celesti", category: "QuadPlayer")

// MARK: - Per-quadrant player

@MainActor
final class QuadrantPlayer: NSObject, ObservableObject {
    let quadrant: Quadrant

    let avPlayer = AVPlayer()
    @Published var vlcPlayer = VLCMediaPlayer()
    @Published var isUsingVLC = false

    @Published var isActive = false
    @Published var isBuffering = false
    @Published var isMuted = false
    @Published var isFailed = false
    @Published var streamName: String?

    private var originalURL: URL?
    private var currentURL: URL?
    private var currentM3U8File: URL?
    private var updateTask: Task<Void, Never>?
    private var errorObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var vlcStateObserver: NSObjectProtocol?

    private let maxBitrate: Double = 800_000
    private var recoveryAttempt = 0

    init(quadrant: Quadrant) {
        self.quadrant = quadrant
        super.init()
        avPlayer.isMuted = false
    }

    func play(urlString: String, name: String?) async {
        guard let inputURL = URL(string: urlString) else {
            quadLog.error("[\(self.quadrant.displayName)] invalid URL: \(urlString, privacy: .public)")
            markFailed()
            return
        }

        quadLog.log("[\(self.quadrant.displayName)] play: \(urlString, privacy: .public) name=\(name ?? "nil", privacy: .public)")
        stop()
        recoveryAttempt = 0
        originalURL = inputURL
        streamName = name ?? inputURL.lastPathComponent
        isActive = true
        isBuffering = true
        isFailed = false

        let resolved = await StreamResolver().resolve(url: inputURL)
        currentURL = resolved.url

        if resolved.contentType == "video/mp2t" || resolved.contentType == "rtmp" || resolved.contentType?.contains("dash+xml") == true || urlString.contains(".mpd") {
            playWithVLC(url: resolved.url, contentType: resolved.contentType)
            return
        }

        if resolved.url.absoluteString.contains("/hls_"), resolved.url.isFileURL {
            currentM3U8File = resolved.url
        }

        var headers = resolved.headers
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = "VLC/3.0.21 LibVLC/3.0.21"
        }
        if headers["Accept"] == nil {
            headers["Accept"] = "*/*"
        }
        if headers["Icy-MetaData"] == nil {
            headers["Icy-MetaData"] = "1"
        }

        let assetOptions: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: resolved.url, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        item.preferredPeakBitRate = maxBitrate
        item.preferredMaximumResolution = CGSize(width: 854, height: 480)

        avPlayer.replaceCurrentItem(with: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        avPlayer.isMuted = isMuted
        avPlayer.play()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.avPlayer.seek(to: .zero)
            self?.avPlayer.play()
        }

        errorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                quadLog.error("[\(self.quadrant.displayName)] AVPlayer item failed")
                self.performRecovery()
            }
        }

        startUpdateLoop()
    }

    func stop() {
        quadLog.log("[\(self.quadrant.displayName)] stop")
        updateTask?.cancel()
        updateTask = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let errorObserver {
            NotificationCenter.default.removeObserver(errorObserver)
            self.errorObserver = nil
        }
        if let vlcStateObserver {
            NotificationCenter.default.removeObserver(vlcStateObserver)
            self.vlcStateObserver = nil
        }

        if isUsingVLC {
            vlcPlayer.stop()
            vlcPlayer.drawable = nil
        }
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        isUsingVLC = false

        if let m3u8 = currentM3U8File {
            try? FileManager.default.removeItem(at: m3u8)
            currentM3U8File = nil
        }

        isActive = false
        isBuffering = false
        isFailed = false
        currentURL = nil
        originalURL = nil
    }

    func toggleMute() {
        isMuted.toggle()
        if isUsingVLC {
            vlcPlayer.audio?.volume = isMuted ? 0 : 100
        } else {
            avPlayer.isMuted = isMuted
        }
        quadLog.log("[\(self.quadrant.displayName)] mute=\(self.isMuted)")
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if isUsingVLC {
            vlcPlayer.audio?.volume = isMuted ? 0 : 100
        } else {
            avPlayer.isMuted = isMuted
        }
    }

    private func playWithVLC(url: URL, contentType: String?) {
        isUsingVLC = true
        vlcPlayer.stop()

        guard let media = VLCMedia(url: url) else {
            quadLog.error("[\(self.quadrant.displayName)] failed to create VLCMedia")
            markFailed()
            return
        }
        media.addOption(":http-user-agent=VLC/3.0.21 LibVLC/3.0.21")
        if contentType?.contains("dash+xml") == true || url.absoluteString.contains(".mpd") {
            media.addOption(":demux=dash")
        }
        vlcPlayer.media = media
        vlcPlayer.audio?.volume = isMuted ? 0 : 100

        vlcStateObserver = NotificationCenter.default.addObserver(
            forName: VLCMediaPlayer.stateChangedNotification,
            object: vlcPlayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleVLCStateChange()
            }
        }

        vlcPlayer.play()
        startUpdateLoop()
    }

    private func handleVLCStateChange() {
        let state = vlcPlayer.state
        switch state {
        case .error:
            quadLog.error("[\(self.quadrant.displayName)] VLC error state")
            performRecovery()
        case .buffering, .opening:
            isBuffering = true
        case .playing:
            isBuffering = false
        case .paused:
            isBuffering = false
        default:
            break
        }
    }

    private func startUpdateLoop() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshState()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    private func refreshState() {
        if isUsingVLC {
            let currentTime = (vlcPlayer.time.value?.doubleValue ?? 0) / 1000.0
            if currentTime > 0 {
                isBuffering = false
            }
            return
        }

        let item = avPlayer.currentItem
        let hasVideo = item?.presentationSize != .zero
        let wasBuffering = isBuffering
        isBuffering = avPlayer.timeControlStatus != .playing
        if wasBuffering != isBuffering {
            quadLog.log("[\(self.quadrant.displayName)] buffering \(wasBuffering) -> \(self.isBuffering)")
        }
        if !hasVideo && isActive {
            // Audio-only stream in a quad cell is not expected; keep it running.
        }
    }

    private func performRecovery() {
        guard let url = originalURL else {
            markFailed()
            return
        }
        recoveryAttempt += 1
        if recoveryAttempt > 3 {
            markFailed()
            return
        }
        quadLog.log("[\(self.quadrant.displayName)] recovery attempt \(self.recoveryAttempt)")
        Task {
            let name = streamName
            await play(urlString: url.absoluteString, name: name)
        }
    }

    private func markFailed() {
        isFailed = true
        isBuffering = false
    }
}

// MARK: - Quad manager

@MainActor
final class QuadPlayerController: ObservableObject {
    @Published var focusedQuadrant: Quadrant = .topLeft
    @Published var isActive = false

    private var players: [Quadrant: QuadrantPlayer] = [:]

    func player(for quadrant: Quadrant) -> QuadrantPlayer {
        if let existing = players[quadrant] {
            return existing
        }
        let newPlayer = QuadrantPlayer(quadrant: quadrant)
        players[quadrant] = newPlayer
        return newPlayer
    }

    func play(urlString: String, name: String?, quadrant: Quadrant) async {
        isActive = true
        await player(for: quadrant).play(urlString: urlString, name: name)
    }

    func stop(quadrant: Quadrant) {
        players[quadrant]?.stop()
        checkActive()
    }

    func stopAll() {
        for player in players.values {
            player.stop()
        }
        isActive = false
        focusedQuadrant = .topLeft
    }

    func moveFocus(direction: MoveDirection) {
        var row = focusedQuadrant.row
        var col = focusedQuadrant.column

        switch direction {
        case .up:
            row = max(0, row - 1)
        case .down:
            row = min(1, row + 1)
        case .left:
            col = max(0, col - 1)
        case .right:
            col = min(1, col + 1)
        }

        if let next = Quadrant.allCases.first(where: { $0.row == row && $0.column == col }) {
            focusedQuadrant = next
        }
    }

    func toggleMuteFocused() {
        players[focusedQuadrant]?.toggleMute()
    }

    func removeFocused(deviceId: String) {
        guard players[focusedQuadrant]?.isActive == true else { return }
        remove(focusedQuadrant, deviceId: deviceId)
    }

    func remove(_ quadrant: Quadrant, deviceId: String) {
        players[quadrant]?.stop()
        notifyBackendStop(quadrant: quadrant, deviceId: deviceId)
        checkActive()
    }

    private func checkActive() {
        let anyActive = players.values.contains { $0.isActive }
        isActive = anyActive
        if !anyActive {
            focusedQuadrant = .topLeft
        }
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isActive
    }

    private func notifyBackendStop(quadrant: Quadrant, deviceId: String) {
        guard let url = URL(string: "https://api.celesti.gaulatti.com/devices/quad/stop/\(quadrant.rawValue)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        quadLog.log("Notifying backend quad stop for quadrant \(quadrant.rawValue)")
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    quadLog.log("Backend quad stop response: \(http.statusCode)")
                }
            } catch {
                quadLog.error("Backend quad stop failed: \(error, privacy: .public)")
            }
        }
    }
}

enum MoveDirection {
    case up
    case down
    case left
    case right
}
