import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import OSLog
import SwiftUI
import UIKit
import Combine
import VLCKitSPM

private let log = Logger(subsystem: "com.gaulatti.celesti", category: "CelestiStore")
private let resolverLog = Logger(subsystem: "com.gaulatti.celesti", category: "StreamResolver")

struct CelestiCommand: Decodable {
    let type: String
    let videoId: String?
    let url: String?
    let title: String?
    let name: String?
    let deviceCode: String?
    let nickname: String?
}

struct CallsignPresentation: Equatable {
    let deviceCode: String
    let nickname: String?
}

enum RegistrationState: Equatable {
    case pending
    case standby
    case demo
}

enum PlaybackSource: Equatable {
    case remoteCommand
    case demo
}

enum DvrAction: Equatable {
    case none
    case play
    case pause
    case rewind
    case fastForward
}

private let bitrateCaps: [Double] = [0, 3_500_000, 2_000_000, 1_200_000, 800_000, 400_000]
private let playerLog = Logger(subsystem: "com.gaulatti.celesti", category: "Player")

struct PlaybackPresentation: Equatable {
    var source: PlaybackSource
    var radioName: String?
    var streamTitle: String?
    var isAudioOnly: Bool
    var isBuffering: Bool
    var isPaused: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var qualityTier: Int = 3
    var isPlaybackFailed: Bool = false
    var failedStreamName: String? = nil
}

@MainActor
final class CelestiAppModel: ObservableObject {
    @Published var registrationState: RegistrationState = .pending
    @Published var nickname: String?
    @Published var playback: PlaybackPresentation?
    @Published var callsign: CallsignPresentation?

    let deviceId: String
    let playerController: PlayerController

    private let registrationService = RegistrationService()
    private let commandStream = CommandStreamClient()
    private var registrationTask: Task<Void, Never>?
    private var started = false

    init() {
        self.deviceId = DeviceIdentityStore.shared.deviceId
        log.log("AppModel init, deviceId: \(self.deviceId, privacy: .public)")
        self.playerController = PlayerController()
        self.playerController.onPresentationChanged = { [weak self] presentation in
            self?.playback = presentation
        }
        self.playerController.onDvrStateChanged = { [weak self] dvrAction in
            guard let self else { return }
            if let dvrAction {
                self.showDvrOverlay(action: dvrAction)
            } else {
                self.dvrVisible = false
                self.dvrAction = .none
            }
        }
    }

    func startIfNeeded() {
        guard !started else {
            log.log("startIfNeeded: already started, skipping")
            return
        }
        started = true
        log.log("startIfNeeded: beginning registration polling")
        startRegistrationPolling()
    }

    func showDemoMode() {
        log.log("showDemoMode entered")
        registrationTask?.cancel()
        commandStream.disconnect()
        nickname = nil
        registrationState = .demo

        Task {
            log.log("showDemoMode: starting demo playback")
            await playerController.playDemo()
        }
    }

    func exitDemoMode() {
        log.log("exitDemoMode entered")
        playerController.stop()
        registrationState = .pending
        startRegistrationPolling()
    }

    @Published var dvrVisible: Bool = false
    @Published var dvrAction: DvrAction = .none
    private var dvrAutoHideTask: Task<Void, Never>?

    func dismissPlayback() {
        dvrAutoHideTask?.cancel()
        dvrAutoHideTask = nil
        dvrVisible = false
        dvrAction = .none
        playerController.stop()
    }

    func togglePlayPause() {
        playerController.togglePlayPause()
        let isPaused = playerController.isPaused
        showDvrOverlay(action: isPaused ? .pause : .play)
    }

    func seekBackward() {
        playerController.seek(by: -10)
        let isPaused = playerController.isPaused
        showDvrOverlay(action: isPaused ? .pause : .rewind)
    }

    func seekForward() {
        playerController.seek(by: 10)
        let isPaused = playerController.isPaused
        showDvrOverlay(action: isPaused ? .pause : .fastForward)
    }

    func showDvrOverlay(action: DvrAction) {
        dvrAutoHideTask?.cancel()
        dvrAction = action
        dvrVisible = true
        dvrAutoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.dvrVisible = false
                self?.dvrAction = .none
            }
        }
    }

    func handleExitCommand() {
        if playback != nil {
            dismissPlayback()
        } else if registrationState == .demo {
            exitDemoMode()
        }
    }

    func retryPlayback() {
        playerController.retryFromFailure()
    }

    private func startRegistrationPolling() {
        log.log("Registration polling starting for device \(self.deviceId, privacy: .public)")
        registrationTask?.cancel()
        registrationState = .pending

        registrationTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let result = try await registrationService.checkRegistration(deviceId: self.deviceId)
                    log.log("Registration poll result: registered=\(result.isRegistered) nickname=\(result.nickname ?? "nil", privacy: .public)")
                    if result.isRegistered {
                        self.nickname = result.nickname
                        self.registrationState = .standby
                        log.log("Device registered! Starting command stream")
                        self.startCommandStream()
                        return
                    }
                } catch {
                    log.error("Registration polling error: \(error, privacy: .public)")
                }

                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func startCommandStream() {
        log.log("Connecting command stream for device \(self.deviceId, privacy: .public)")
        commandStream.connect(deviceId: deviceId) { [weak self] command in
            Task { @MainActor [weak self] in
                await self?.handle(command: command)
            }
        }
    }

    private func handle(command: CelestiCommand) async {
        log.log("Received command: type=\(command.type, privacy: .public) videoId=\(command.videoId ?? "nil", privacy: .public) url=\(command.url ?? "nil", privacy: .public) name=\(command.name ?? command.title ?? "nil", privacy: .public)")
        switch command.type {
        case "youtube":
            guard let videoId = command.videoId, !videoId.isEmpty else {
                log.error("youtube command missing videoId")
                return
            }
            log.log("Opening YouTube videoId: \(videoId, privacy: .public)")
            playerController.openYouTube(videoId: videoId)
        case "m3u":
            guard let url = command.url, !url.isEmpty else {
                log.error("m3u command missing url")
                return
            }
            log.log("Playing m3u stream: url=\(url, privacy: .public) name=\(command.name ?? command.title ?? "unknown", privacy: .public)")
            await playerController.playStream(urlString: url, radioName: command.name ?? command.title)
        case "stop":
            log.log("Stop command received")
            playerController.stop()
        case "callsign":
            log.log("Callsign received: code=\(command.deviceCode ?? "nil", privacy: .public) nickname=\(command.nickname ?? "nil", privacy: .public)")
            callsign = CallsignPresentation(
                deviceCode: command.deviceCode ?? "",
                nickname: command.nickname
            )
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_500_000_000)
                await MainActor.run {
                    self?.callsign = nil
                }
            }
        case "heartbeat":
            log.debug("Heartbeat received")
            break
        default:
            log.warning("Unknown command type: \(command.type, privacy: .public)")
            break
        }
    }
}

private struct RegistrationCheckResult {
    let isRegistered: Bool
    let nickname: String?
}

private struct RegistrationResponse: Decodable {
    let nickname: String?
}

private let registrationLog = Logger(subsystem: "com.gaulatti.celesti", category: "RegistrationService")

private final class RegistrationService {
    private let baseURL = URL(string: "https://api.celesti.gaulatti.com/devices/whoami")!

    func checkRegistration(deviceId: String) async throws -> RegistrationCheckResult {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        registrationLog.log("Checking registration for device \(deviceId, privacy: .public)")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            registrationLog.error("Registration response not HTTPURLResponse")
            throw URLError(.badServerResponse)
        }

        registrationLog.log("Registration response status: \(httpResponse.statusCode, privacy: .public)")
        switch httpResponse.statusCode {
        case 200:
            let payload = try? JSONDecoder().decode(RegistrationResponse.self, from: data)
            registrationLog.log("Device registered (200), nickname: \(payload?.nickname ?? "nil", privacy: .public)")
            return RegistrationCheckResult(isRegistered: true, nickname: payload?.nickname)
        case 204:
            registrationLog.log("Device registered (204)")
            return RegistrationCheckResult(isRegistered: true, nickname: nil)
        case 404:
            registrationLog.log("Device not yet registered (404)")
            return RegistrationCheckResult(isRegistered: false, nickname: nil)
        default:
            registrationLog.error("Unexpected status code: \(httpResponse.statusCode, privacy: .public)")
            throw URLError(.badServerResponse)
        }
    }
}

private let sseLog = Logger(subsystem: "com.gaulatti.celesti", category: "SSE")

private final class CommandStreamClient {
    private let baseURL = URL(string: "https://api.celesti.gaulatti.com/sse/events")!
    private var streamTask: Task<Void, Never>?

    func connect(deviceId: String, onCommand: @escaping (CelestiCommand) -> Void) {
        guard streamTask == nil else {
            sseLog.log("connect called but streamTask already exists, skipping")
            return
        }

        sseLog.log("Starting SSE connection for device \(deviceId, privacy: .public)")

        streamTask = Task {
            var backoff: UInt64 = 1_000_000_000

            while !Task.isCancelled {
                do {
                    let url = baseURL.appending(queryItems: [URLQueryItem(name: "device_code", value: deviceId)])
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    request.setValue("keep-alive", forHTTPHeaderField: "Connection")
                    request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

                    sseLog.log("Connecting to \(url.absoluteString, privacy: .public)")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        sseLog.error("SSE connection failed, status: \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                        throw URLError(.badServerResponse)
                    }

                    sseLog.log("SSE connected successfully, status: \(httpResponse.statusCode, privacy: .public)")
                    backoff = 1_000_000_000
                    var buffer = ""

                    for try await rawLine in bytes.lines {
                        if Task.isCancelled { break }
                        let line = String(rawLine)

                        if line.hasPrefix("data:") {
                            let fragment = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

                            if fragment.hasPrefix("{"), !buffer.isEmpty {
                                tryDecodeAndDispatch(buffer, onCommand: onCommand)
                                buffer = ""
                            }

                            if !buffer.isEmpty {
                                buffer.append("\n")
                            }
                            buffer.append(fragment)
                            sseLog.debug("SSE data fragment: \(fragment, privacy: .public)")

                            // Some SSE servers send single-line JSON events without
                            // a trailing blank line; decode immediately so the event
                            // doesn't sit in the buffer until the next event arrives.
                            if tryDecodeAndDispatch(buffer, onCommand: onCommand) {
                                buffer = ""
                            }
                        } else if line.isEmpty {
                            if !buffer.isEmpty {
                                tryDecodeAndDispatch(buffer, onCommand: onCommand)
                                buffer = ""
                            }
                        }
                    }

                    if !buffer.isEmpty {
                        tryDecodeAndDispatch(buffer, onCommand: onCommand)
                    }

                    sseLog.warning("SSE stream ended (server closed connection)")
                } catch {
                    if Task.isCancelled {
                        sseLog.log("SSE task cancelled, stopping reconnection")
                        break
                    }
                    sseLog.error("SSE error: \(error, privacy: .public), reconnecting in \(backoff / 1_000_000_000)s")
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, 30_000_000_000)
                    sseLog.log("SSE reconnecting with backoff \(backoff / 1_000_000_000)s")
                }
            }

            sseLog.log("SSE stream task finished")
        }
    }

    func disconnect() {
        sseLog.log("Disconnecting SSE stream")
        streamTask?.cancel()
        streamTask = nil
    }

    @discardableResult
    private func tryDecodeAndDispatch(_ buffer: String, onCommand: (CelestiCommand) -> Void) -> Bool {
        let data = Data(buffer.utf8)
        sseLog.debug("SSE parsing buffer: \(buffer, privacy: .public)")
        if let command = try? JSONDecoder().decode(CelestiCommand.self, from: data) {
            sseLog.log("SSE decoded command: type=\(command.type, privacy: .public)")
            onCommand(command)
            return true
        } else {
            sseLog.log("SSE buffer is not a CelestiCommand, skipping: \(buffer, privacy: .public)")
            return false
        }
    }
}

final class PlayerController: NSObject, ObservableObject {
    let player = AVPlayer()
    @Published var vlcPlayer = VLCMediaPlayer()
    @Published var isUsingVLC = false
    var onPresentationChanged: ((PlaybackPresentation?) -> Void)?
    var onDvrStateChanged: ((DvrAction?) -> Void)?

    private var currentPresentation: PlaybackPresentation? {
        didSet {
            onPresentationChanged?(currentPresentation)
        }
    }

    private var updateTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var currentSource: PlaybackSource?
    private var currentRadioName: String?
    private var currentURL: URL?
    private var originalURL: URL?
    private var currentM3U8File: URL?
    private var vlcStateObserver: NSObjectProtocol?

    // Quality management (0=AUTO, 1=HD, 2=SD, 3=MED, 4=LOW, 5=MIN)
    private var qualityTier: Int = 3 {
        didSet {
            applyQualityTier()
        }
    }
    private var lastTierChangeAt: Date = .distantPast
    private var lastInstabilityAt: Date = .distantPast

    // Watchdog
    private var watchdogTimer: Timer?
    private var bufferingStartedAt: Date?
    private var lastPlaybackPosition: CMTime = .zero
    private var lastPositionUpdateAt: Date = .distantPast
    private var recoveryAttempt: Int = 0
    private var hasEverReachedReady: Bool = false
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryTask: Task<Void, Never>?
    private var playbackStartedAt: Date?

    // DVR auto-show tracking
    private var lastKnownTime: Double = 0
    private var lastKnownBuffering: Bool = false

    private let watchdogInterval: TimeInterval = 3.0
    private let bufferingStallLimit: TimeInterval = 12.0
    private let positionStallLimit: TimeInterval = 8.0
    private let stableWindowForUpgrade: TimeInterval = 300.0

    var isPaused: Bool {
        if isUsingVLC {
            return vlcPlayer.state == .paused || vlcPlayer.state == .stopped
        }
        return player.rate == 0 && player.timeControlStatus != .waitingToPlayAtSpecifiedRate
    }

    var isPlaybackFailed: Bool = false
    private var failedStreamName: String?
    private var audioFallbackApplied = false

    func playDemo() async {
        let demoURLs = [
            "https://streamcdnc1-dd782ed59e2a4e86aabf6fc508674b59.msvdn.net/live/S97044836/tbbP8T1ZRPBL/playlist_video.m3u8",
            "https://jireh-4-hls-video-us-isp.dps.live/hls-video/339f69c6122f6d8f4574732c235f09b7683e31a5/bbtv/bbtv.smil/playlist.m3u8?dpssid=b2487492604697fbad33e661&sid=ba5t1l1xb21480979815697fbad4f29eb&ndvc=0"
        ]

        guard let selected = demoURLs.randomElement() else {
            playerLog.error("playDemo: no demo URLs available")
            return
        }
        playerLog.log("playDemo: selected URL \(selected, privacy: .public)")
        await play(urlString: selected, radioName: nil, source: .demo)
    }

    func playStream(urlString: String, radioName: String?) async {
        playerLog.log("playStream called: url=\(urlString, privacy: .public) name=\(radioName ?? "nil", privacy: .public)")
        await play(urlString: urlString, radioName: radioName, source: .remoteCommand)
    }

    func stop() {
        playerLog.log("stop called")
        stopWatchdog()
        removeTimeObserver()
        updateTask?.cancel()
        updateTask = nil

        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryTask?.cancel()
        recoveryTask = nil

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
            // Don't nil the media — VLCKit retains it internally
            // and nil-setting causes libvlc_media_retain assertion
            // on the next play.
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isUsingVLC = false
        currentSource = nil
        currentRadioName = nil
        currentURL = nil
        originalURL = nil
        if let m3u8 = currentM3U8File {
            try? FileManager.default.removeItem(at: m3u8)
            currentM3U8File = nil
        }
        bufferingStartedAt = nil
        lastPlaybackPosition = .zero
        lastPositionUpdateAt = .distantPast
        recoveryAttempt = 0
        hasEverReachedReady = false
        isPlaybackFailed = false
        failedStreamName = nil
        audioFallbackApplied = false
        currentPresentation = nil

        UIApplication.shared.isIdleTimerDisabled = false
    }

    func openYouTube(videoId: String) {
        playerLog.log("openYouTube: videoId=\(videoId, privacy: .public)")
        let urls = [
            URL(string: "youtube://www.youtube.com/watch?v=\(videoId)"),
            URL(string: "https://youtube.com/watch?v=\(videoId)")
        ].compactMap { $0 }

        for url in urls {
            playerLog.log("openYouTube: trying URL \(url.absoluteString, privacy: .public)")
            UIApplication.shared.open(url)
            break
        }
    }

    func togglePlayPause() {
        guard !isPlaybackFailed else {
            playerLog.log("togglePlayPause: ignored, playback failed")
            return
        }
        if isUsingVLC {
            if vlcPlayer.isPlaying {
                vlcPlayer.pause()
            } else {
                vlcPlayer.play()
            }
            return
        }
        let wasPaused = player.timeControlStatus == .paused || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        playerLog.log("togglePlayPause: wasPaused=\(wasPaused)")
        if wasPaused {
            player.play()
        } else {
            player.pause()
        }
    }

    func seek(by seconds: Double) {
        guard !isPlaybackFailed else {
            playerLog.log("seek: ignored, playback failed")
            return
        }
        if isUsingVLC {
            playerLog.log("seek: VLC seek not supported for live streams")
            return
        }
        guard let item = player.currentItem, item.duration.seconds.isFinite else {
            playerLog.log("seek: no current item or duration not finite")
            return
        }
        let current = player.currentTime().seconds
        let duration = item.duration.seconds
        let newTime = CMTime(seconds: max(0, min(duration, current + seconds)), preferredTimescale: 600)
        playerLog.log("seek: by=\(seconds) current=\(current) new=\(newTime.seconds)")
        player.seek(to: newTime)
    }

    func retryFromFailure() {
        guard isPlaybackFailed, let url = originalURL else {
            playerLog.log("retryFromFailure: not in failed state or no original URL")
            return
        }
        playerLog.log("retryFromFailure: retrying URL \(url.absoluteString, privacy: .public)")
        isPlaybackFailed = false
        failedStreamName = nil
        recoveryAttempt = 0
        hasEverReachedReady = false
        bufferingStartedAt = nil
        lastPlaybackPosition = .zero
        lastPositionUpdateAt = .distantPast

        Task {
            let name = currentRadioName
            let source = currentSource ?? .remoteCommand
            await play(urlString: url.absoluteString, radioName: name, source: source)
        }
    }

    private func play(urlString: String, radioName: String?, source: PlaybackSource) async {
        guard let inputURL = URL(string: urlString) else {
            playerLog.error("play: invalid URL string: \(urlString, privacy: .public)")
            return
        }

        playerLog.log("play: url=\(urlString, privacy: .public) name=\(radioName ?? "nil", privacy: .public) source=\(source == .demo ? "demo" : "remote")")
        stop()
        audioFallbackApplied = false
        originalURL = inputURL
        currentSource = source
        currentRadioName = radioName
        qualityTier = 3
        lastTierChangeAt = Date()
        lastInstabilityAt = Date()
        currentPresentation = PlaybackPresentation(
            source: source,
            radioName: radioName,
            streamTitle: nil,
            isAudioOnly: false,
            isBuffering: true,
            qualityTier: qualityTier
        )

        playerLog.log("play: resolving stream URL")
        let resolved = await StreamResolver().resolve(url: inputURL)
        currentURL = resolved.url
        playerLog.log("play: resolved URL: \(resolved.url.absoluteString, privacy: .public) headers: \(resolved.headers, privacy: .public)")

        if resolved.contentType == "video/mp2t" || resolved.contentType == "rtmp" || resolved.contentType?.contains("dash+xml") == true || urlString.contains(".mpd") {
            let format = resolved.contentType == "video/mp2t" ? "MPEG-TS"
                       : resolved.contentType == "rtmp" ? "RTMP" : "DASH"
            playerLog.log("play: \(format) detected, using VLC player")
            playWithVLC(url: resolved.url, radioName: radioName, contentType: resolved.contentType)
            return
        }

        if resolved.url.absoluteString.contains("/hls_"), resolved.url.isFileURL {
            currentM3U8File = resolved.url
            playerLog.log("play: tracking temp m3u8 file: \(resolved.url.path)")
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
        playerLog.log("play: headers: \(headers, privacy: .public)")

        let assetOptions: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: resolved.url, options: assetOptions)
        playerLog.log("play: created AVURLAsset: \(asset, privacy: .public)")
        let item = AVPlayerItem(asset: asset)

        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        metadataOutput.setDelegate(MetadataCollector { [weak self] title in
            guard let self else { return }
            guard var presentation = self.currentPresentation else { return }
            presentation.streamTitle = title
            self.currentPresentation = presentation
        }, queue: DispatchQueue.main)
        item.add(metadataOutput)

        playerLog.log("play: replacing current item and calling play()")
        playbackStartedAt = Date()
        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()
        startWatchdog()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let shouldLoopDemo: Bool
            switch source {
            case .demo:
                shouldLoopDemo = true
            case .remoteCommand:
                shouldLoopDemo = false
            }

            playerLog.log("play: item played to end, looping=\(shouldLoopDemo)")
            if shouldLoopDemo {
                self.player.seek(to: .zero)
                self.player.play()
            }
        }

        errorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            playerLog.error("play: AVPlayerItemFailedToPlayToEndTime notification received")
            performEmergencyRecovery(reason: "playback_error")
        }

        updateTask = Task { [weak self] in
            guard let self else { return }
            playerLog.log("play: starting presentation update task (750ms interval)")
            while !Task.isCancelled {
                self.refreshPresentationState()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        playerLog.log("play: playback setup complete")

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func playWithVLC(url: URL, radioName: String?, contentType: String? = nil) {
        // Fresh player each session so video output pipeline is clean.
        // The old player may still have the previous drawable wired up.
        vlcPlayer = VLCMediaPlayer()
        isUsingVLC = true

        guard let media = VLCMedia(url: url) else {
            playerLog.error("playWithVLC: failed to create VLCMedia")
            failPlayback()
            return
        }
        media.addOption(":http-user-agent=VLC/3.0.21 LibVLC/3.0.21")
        if contentType?.contains("dash+xml") == true || url.absoluteString.contains(".mpd") {
            media.addOption(":demux=dash")
            playerLog.log("playWithVLC: added DASH demux option")
        }
        vlcPlayer.media = media

        vlcStateObserver = NotificationCenter.default.addObserver(
            forName: VLCMediaPlayer.stateChangedNotification,
            object: vlcPlayer,
            queue: .main
        ) { [weak self] _ in
            self?.handleVLCStateChange()
        }

        playerLog.log("playWithVLC: starting VLC playback")
        playbackStartedAt = Date()
        vlcPlayer.play()

        updateTask = Task { [weak self] in
            guard let self else { return }
            playerLog.log("playWithVLC: starting presentation update task")
            while !Task.isCancelled {
                self.refreshPresentationState()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func handleVLCStateChange() {
        guard var presentation = currentPresentation else { return }
        let state = vlcPlayer.state
        playerLog.log("VLC state: \(state.rawValue)")

        switch state {
        case .error:
            playerLog.error("VLC error state, triggering recovery")
            performEmergencyRecovery(reason: "vlc_error")
        case .buffering, .opening:
            presentation.isBuffering = true
        case .playing:
            presentation.isBuffering = false
        case .paused:
            presentation.isBuffering = false
        default:
            break
        }
        currentPresentation = presentation
    }

    private func refreshPresentationState() {
        guard var presentation = currentPresentation else {
            playerLog.debug("refreshPresentationState: no current presentation")
            return
        }
        guard !isPlaybackFailed else {
            presentation.isPlaybackFailed = true
            presentation.failedStreamName = failedStreamName
            presentation.isBuffering = false
            currentPresentation = presentation
            playerLog.log("refreshPresentationState: playback failed state")
            return
        }

        if isUsingVLC {
            let currentTime = (vlcPlayer.time.value?.doubleValue ?? 0) / 1000.0
            // Once time has advanced, VLC is rendering — clear buffering
            // even if the internal state still says .buffering (common
            // for live MPEG-TS streams).
            if currentTime > 0 {
                presentation.isBuffering = false
            }
            presentation.isPaused = vlcPlayer.state == .paused
            presentation.currentTime = currentTime
            if let dur = vlcPlayer.media?.length.value?.doubleValue {
                presentation.duration = dur / 1000.0
            }
            updatePresentationDvr(&presentation)
            currentPresentation = presentation
            return
        }

        let item = player.currentItem
        let presentationSize = item?.presentationSize ?? .zero
        let hasVideo = presentationSize != .zero

        presentation.isAudioOnly = !hasVideo && currentSource != .demo
        let wasBufferingPreviously = presentation.isBuffering
        presentation.isBuffering = player.timeControlStatus != .playing
        presentation.isPaused = isPaused
        presentation.qualityTier = qualityTier

        if wasBufferingPreviously != presentation.isBuffering {
            if let t0 = playbackStartedAt {
                let elapsed = Date().timeIntervalSince(t0)
                playerLog.log("refreshPresentationState: buffering changed \(wasBufferingPreviously) -> \(presentation.isBuffering) after \(elapsed, privacy: .public)s, timeControlStatus=\(self.player.timeControlStatus.rawValue)")
            } else {
                playerLog.log("refreshPresentationState: buffering changed \(wasBufferingPreviously) -> \(presentation.isBuffering), timeControlStatus=\(self.player.timeControlStatus.rawValue)")
            }
        }

        if let currentItem = item {
            let current = currentItem.currentTime()
            let dur = currentItem.duration
            presentation.currentTime = current.seconds.isFinite ? current.seconds : 0
            presentation.duration = dur.seconds.isFinite ? dur.seconds : 0
        }

        if presentation.radioName == nil {
            presentation.radioName = currentRadioName
        }

        updatePresentationDvr(&presentation)
        currentPresentation = presentation

        if !isUsingVLC, !audioFallbackApplied {
            checkAudioTracks()
        }
    }

    private func checkAudioTracks() {
        guard let item = player.currentItem else { return }
        let tracks = item.tracks
        let audioTracks = tracks.filter { $0.assetTrack?.mediaType == .audio }
        guard !audioTracks.isEmpty else { return }

        let enabledAudio = audioTracks.filter { $0.isEnabled }
        if enabledAudio.isEmpty {
            playerLog.warning("checkAudioTracks: no audio track enabled, attempting fallback")
            for track in audioTracks {
                guard let assetTrack = track.assetTrack else { continue }
                Task {
                    let isPlayable = try? await assetTrack.load(.isPlayable)
                    if isPlayable == true {
                        track.isEnabled = true
                        playerLog.log("checkAudioTracks: enabled audio track")
                        audioFallbackApplied = true
                    }
                }
            }
        } else {
            playerLog.debug("checkAudioTracks: \(enabledAudio.count) audio tracks enabled")
        }
    }

    private func updatePresentationDvr(_ presentation: inout PlaybackPresentation) {
        let wasBuffering = lastKnownBuffering
        lastKnownBuffering = presentation.isBuffering

        if wasBuffering && !presentation.isBuffering {
            onDvrStateChanged?(.play)
        } else if !wasBuffering && presentation.isBuffering && presentation.isPaused {
            onDvrStateChanged?(.pause)
        }

        let timeDelta = abs(presentation.currentTime - lastKnownTime)
        if timeDelta > 5 && !presentation.isBuffering {
            let direction: DvrAction = presentation.currentTime > lastKnownTime ? .fastForward : .rewind
            onDvrStateChanged?(direction)
        }
        lastKnownTime = presentation.currentTime
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        playerLog.log("startWatchdog: interval=\(self.watchdogInterval)s")
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkPlaybackHealth()
            self.maybeUpgradeQuality()
        }
    }

    private func stopWatchdog() {
        if watchdogTimer != nil {
            playerLog.log("stopWatchdog")
        }
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func checkPlaybackHealth() {
        guard !isPlaybackFailed else { return }
        guard let item = player.currentItem, player.timeControlStatus != .paused else {
            if player.currentItem == nil {
                playerLog.debug("checkPlaybackHealth: no current item")
            }
            return
        }

        let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let isBufferEmpty = item.isPlaybackBufferEmpty
        let isLikelyStalled = isWaiting || isBufferEmpty

        if isLikelyStalled {
            if bufferingStartedAt == nil {
                bufferingStartedAt = Date()
                playerLog.log("checkPlaybackHealth: stall detected, waiting=\(isWaiting) bufferEmpty=\(isBufferEmpty)")
            } else {
                let stallDuration = Date().timeIntervalSince(bufferingStartedAt!)
                if stallDuration > bufferingStallLimit {
                    playerLog.error("checkPlaybackHealth: buffering stall for \(stallDuration)s, recovering")
                    performEmergencyRecovery(reason: "buffering_stall")
                }
            }
        } else if player.timeControlStatus == .playing {
            if bufferingStartedAt != nil {
                playerLog.log("checkPlaybackHealth: recovered from buffering")
            }
            bufferingStartedAt = nil
            let currentPos = player.currentTime()
            if currentPos == lastPlaybackPosition {
                let freezeDuration = Date().timeIntervalSince(lastPositionUpdateAt)
                if freezeDuration > positionStallLimit {
                    playerLog.error("checkPlaybackHealth: frozen playback for \(freezeDuration)s, recovering")
                    performEmergencyRecovery(reason: "frozen_playback")
                }
            } else {
                if !hasEverReachedReady {
                    let elapsed = playbackStartedAt.map { Date().timeIntervalSince($0) }
                    playerLog.log("checkPlaybackHealth: first position change detected after \(elapsed ?? 0, privacy: .public)s, playback started")
                }
                lastPlaybackPosition = currentPos
                lastPositionUpdateAt = Date()
                if !hasEverReachedReady {
                    hasEverReachedReady = true
                }
            }
        }
    }

    private func performEmergencyRecovery(reason: String) {
        guard !isPlaybackFailed else {
            playerLog.log("performEmergencyRecovery: already failed, ignoring")
            return
        }

        let now = Date()
        lastInstabilityAt = now
        recoveryAttempt += 1

        playerLog.log("performEmergencyRecovery: reason=\(reason, privacy: .public) attempt=\(self.recoveryAttempt)/3 qualityTier=\(self.qualityTier)")

        if qualityTier < bitrateCaps.count - 1 {
            qualityTier += 1
            lastTierChangeAt = now
            playerLog.log("performEmergencyRecovery: degraded quality tier to \(self.qualityTier)")
        }

        guard recoveryAttempt <= 3 else {
            playerLog.error("performEmergencyRecovery: max attempts reached, failing playback")
            failPlayback()
            return
        }

        let delay: TimeInterval = recoveryAttempt == 1 ? 2.0 : (recoveryAttempt == 2 ? 5.0 : 0.0)
        let shouldReResolve = recoveryAttempt == 3

        playerLog.log("performEmergencyRecovery: retrying in \(delay)s with re-resolve=\(shouldReResolve)")

        recoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performRetry(shouldReResolve: shouldReResolve)
        }
        recoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performRetry(shouldReResolve: Bool) {
        guard !isPlaybackFailed else {
            playerLog.log("performRetry: already failed, ignoring")
            return
        }

        playerLog.log("performRetry: shouldReResolve=\(shouldReResolve)")

        bufferingStartedAt = nil
        lastPlaybackPosition = .zero
        lastPositionUpdateAt = .distantPast

        if shouldReResolve, let url = originalURL {
            playerLog.log("performRetry: re-resolving and replaying original URL \(url.absoluteString, privacy: .public)")
            let name = currentRadioName
            let source = currentSource ?? .remoteCommand
            let task = Task {
                await play(urlString: url.absoluteString, radioName: name, source: source)
            }
            recoveryTask = task
        } else if isUsingVLC, let url = currentURL {
            playerLog.log("performRetry: restarting VLC with \(url.absoluteString, privacy: .public)")
            vlcPlayer.stop()
            guard let media = VLCMedia(url: url) else {
                playerLog.error("performRetry: failed to create VLCMedia")
                failPlayback()
                return
            }
            media.addOption(":http-user-agent=VLC/3.0.21 LibVLC/3.0.21")
            vlcPlayer.media = media
            vlcPlayer.play()
        } else if let url = currentURL {
            playerLog.log("performRetry: replacing item with current URL \(url.absoluteString, privacy: .public)")
            var headers: [String: String] = [:]
            headers["User-Agent"] = "VLC/3.0.21 LibVLC/3.0.21"
            headers["Accept"] = "*/*"
            headers["Icy-MetaData"] = "1"

            let assetOptions: [String: Any]? = ["AVURLAssetHTTPHeaderFieldsKey": headers]
            let asset = AVURLAsset(url: url, options: assetOptions)
            let item = AVPlayerItem(asset: asset)
            let resumeTime = player.currentTime()

            player.replaceCurrentItem(with: item)
            if resumeTime.seconds.isFinite && resumeTime.seconds > 0 {
                player.seek(to: resumeTime)
            }
            player.play()
        }
    }

    private func applyQualityTier() {
        guard let item = player.currentItem else { return }
        let cap = bitrateCaps[qualityTier]
        item.preferredPeakBitRate = cap
    }

    private func failPlayback() {
        isPlaybackFailed = true
        failedStreamName = currentRadioName ?? currentURL?.lastPathComponent ?? "Unknown"
        playerLog.error("failPlayback: streamName=\(self.failedStreamName ?? "nil", privacy: .public)")
        player.pause()
        recoveryAttempt = 0
        UIApplication.shared.isIdleTimerDisabled = false
        currentPresentation = PlaybackPresentation(
            source: currentSource ?? .remoteCommand,
            radioName: currentRadioName,
            streamTitle: nil,
            isAudioOnly: false,
            isBuffering: false,
            isPlaybackFailed: true,
            failedStreamName: failedStreamName
        )
    }

    private func maybeUpgradeQuality() {
        guard qualityTier > 1 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastInstabilityAt) > stableWindowForUpgrade else { return }
        guard now.timeIntervalSince(lastTierChangeAt) > 60 else { return }
        qualityTier -= 1
        lastTierChangeAt = now
        playerLog.log("maybeUpgradeQuality: upgraded to tier \(self.qualityTier)")
    }
}

private final class MetadataCollector: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let onTitle: (String?) -> Void

    init(onTitle: @escaping (String?) -> Void) {
        self.onTitle = onTitle
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from playerItemTrack: AVPlayerItemTrack?) {
        let items = groups
            .flatMap(\.items)
            .filter { item in
                item.commonKey?.rawValue == "title" ||
                item.identifier?.rawValue.localizedCaseInsensitiveContains("title") == true
            }

        guard let firstItem = items.first else { return }

        Task {
            let title = try? await firstItem.load(.stringValue)
            await MainActor.run {
                self.onTitle(title)
            }
        }
    }
}

private struct ResolvedStream {
    let url: URL
    let headers: [String: String]
    let contentType: String?
    let playlist: String?
}

private final class HLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let streamURL: URL
    private let playlist: String

    init(streamURL: URL, playlist: String) {
        self.streamURL = streamURL
        self.playlist = playlist
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: URLError(.badURL))
            return true
        }

        if url.lastPathComponent == "playlist" {
            return respondWithPlaylist(loadingRequest)
        }

        proxyStream(loadingRequest)
        return true
    }

    private func respondWithPlaylist(_ loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let data = Data(playlist.utf8)
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = "application/x-mpegURL"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
        return true
    }

    private func proxyStream(_ loadingRequest: AVAssetResourceLoadingRequest) {
        Task {
            var request = URLRequest(url: streamURL)
            request.setValue("VLC/3.0.21 LibVLC/3.0.21", forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("1", forHTTPHeaderField: "Icy-MetaData")

            if let dataRequest = loadingRequest.dataRequest {
                let length = dataRequest.requestedLength
                if length > 0 {
                    let start = dataRequest.requestedOffset
                    request.setValue("bytes=\(start)-\(start + Int64(length) - 1)", forHTTPHeaderField: "Range")
                }
            }

            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                if let info = loadingRequest.contentInformationRequest {
                    info.contentType = response.mimeType ?? "video/mp2t"
                    info.contentLength = response.expectedContentLength
                    info.isByteRangeAccessSupported = false
                }

                var buffer = Data()
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 65536 {
                        loadingRequest.dataRequest?.respond(with: buffer)
                        buffer = Data()
                    }
                }
                if !buffer.isEmpty {
                    loadingRequest.dataRequest?.respond(with: buffer)
                }

                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
    }
}

private let m3u8Log = Logger(subsystem: "com.gaulatti.celesti", category: "M3U8Generator")

private final class StreamResolver {
    func resolve(url: URL) async -> ResolvedStream {
        resolverLog.log("resolve: \(url.absoluteString, privacy: .public)")

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("VLC/3.0.21 LibVLC/3.0.21", forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            let contentType = (response as? HTTPURLResponse)?.allHeaderFields["Content-Type"] as? String ?? ""
            let isLikelyText = contentType.contains("text") ||
                               contentType.contains("mpegurl") ||
                               contentType.contains("application/x-mpegurl") ||
                               url.absoluteString.contains(".m3u")

            // For raw MPEG-TS, return the original URL — PlayerController
            // routes these to VLCKit (which handles TS natively like
            // ExoPlayer's TsExtractor).
            if contentType == "video/mp2t" {
                resolverLog.log("resolve: content-type=video/mp2t, VLC will handle natively")
                return ResolvedStream(url: url, headers: [:], contentType: contentType, playlist: nil)
            }

            // DASH manifest — route to VLCKit for native DASH demux
            if contentType.contains("dash+xml") || url.absoluteString.contains(".mpd") {
                resolverLog.log("resolve: DASH manifest detected, VLC will handle")
                return ResolvedStream(url: url, headers: [:], contentType: contentType, playlist: nil)
            }

            // RTMP stream — VLCKit handles natively
            if let scheme = url.scheme?.lowercased(), scheme == "rtmp" || scheme == "rtmps" {
                resolverLog.log("resolve: RTMP stream detected, VLC will handle")
                return ResolvedStream(url: url, headers: [:], contentType: "rtmp", playlist: nil)
            }

            guard isLikelyText else {
                resolverLog.log("resolve: content-type=\(contentType), not text/playlist, returning original URL")
                return ResolvedStream(url: url, headers: [:], contentType: contentType, playlist: nil)
            }

            var data = Data()
            for try await chunk in bytes {
                data.append(chunk)
            }

            let content = String(data: data, encoding: .utf8) ?? ""
            guard content.contains("#EXTM3U") else {
                resolverLog.log("resolve: not an EXTM3U playlist, returning original URL")
                return ResolvedStream(url: url, headers: [:], contentType: contentType, playlist: nil)
            }

            resolverLog.log("resolve: found #EXTM3U playlist, size=\(data.count) bytes")

            var targetURL = url
            var headers: [String: String] = [:]

            for rawLine in content.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("#EXTVLCOPT:http-referrer=") {
                    let value = String(line.dropFirst("#EXTVLCOPT:http-referrer=".count))
                    headers["Referer"] = value
                    resolverLog.log("resolve: found referrer header: \(value, privacy: .public)")
                } else if line.hasPrefix("#EXTVLCOPT:http-user-agent=") {
                    let value = String(line.dropFirst("#EXTVLCOPT:http-user-agent=".count))
                    headers["User-Agent"] = value
                    resolverLog.log("resolve: found user-agent header: \(value, privacy: .public)")
                } else if line.lowercased().hasPrefix("http"), let parsedURL = URL(string: line) {
                    targetURL = parsedURL
                    resolverLog.log("resolve: found stream URL: \(parsedURL.absoluteString, privacy: .public)")
                }
            }

            resolverLog.log("resolve: resolved to \(targetURL.absoluteString, privacy: .public) with \(headers.count) headers")
            return ResolvedStream(url: targetURL, headers: headers, contentType: contentType, playlist: content)
        } catch {
            resolverLog.error("resolve: failed: \(error, privacy: .public)")
            return ResolvedStream(url: url, headers: [:], contentType: nil, playlist: nil)
        }
    }

    private static func createTempM3U8(streamURL: URL) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let fileURL = dir.appendingPathComponent("hls_\(UUID().uuidString).m3u8")

        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:EVENT
        #EXTINF:10.000,
        \(streamURL.absoluteString)
        """

        try? playlist.write(to: fileURL, atomically: true, encoding: .utf8)
        m3u8Log.log("createTempM3U8: wrote \(fileURL.path)")
        return fileURL
    }
}

struct VLCPlayerView: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        player.drawable = uiView
    }
}

final class DeviceIdentityStore {
    static let shared = DeviceIdentityStore()

    let deviceId: String

    private let defaults = UserDefaults.standard
    private let key = "celesti.device_id"
    private let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

    private init() {
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            self.deviceId = stored
        } else {
            let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
            let generated = String((0..<10).compactMap { _ in alphabet.randomElement() })
            defaults.set(generated, forKey: key)
            self.deviceId = generated
        }
    }
}

extension URL {
    fileprivate func appending(queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}

enum QRCodeFactory {
    private static let context = CIContext()

    static func image(for string: String, size: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scale = max(size / outputImage.extent.width, size / outputImage.extent.height)
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
