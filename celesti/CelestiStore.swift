import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import OSLog
import Sabella
import SwiftUI
import UIKit
import Combine

private let log = Logger(subsystem: "com.gaulatti.celesti", category: "CelestiStore")
private let resolverLog = Logger(subsystem: "com.gaulatti.celesti", category: "StreamResolver")

struct CelestiCommand: Decodable {
    let type: String
    let videoId: String?
    let url: String?
    let title: String?
    let name: String?
    let logo: String?
    let delta: Int?
    let deviceCode: String?
    let nickname: String?
    let quadrant: Int?
    let layoutMode: String?
    let channelId: String?
    // Kept for compatibility with the short-lived Atlantide command shape.
    let mode: String?
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
    @Published private(set) var channelGroups: [CelestiChannelGroupSummary] = []
    @Published private(set) var channelGroupsLoading = false
    @Published private(set) var channelGroupsError: String?
    @Published var channelBrowserPage: SabellaTVChannelBrowserPage = .home
    @Published var focusedChannelGroupID: String?
    @Published var activeChannelGroup: CelestiChannelGroup?
    @Published var selectedChannelID: String?
    @Published var channelGuideVisible = false
    @Published private(set) var channelGuideLoadingMore = false

    let deviceId: String
    let playerController: PlayerController
    let quadPlayerController: QuadPlayerController
    let emergencyPlayerController: EmergencyPlayerController

    @Published var layoutMode: LayoutMode = .single

    private let registrationService = RegistrationService()
    private let channelLibraryService = ChannelLibraryService()
    private let commandStream = CommandStreamClient()
    private var registrationTask: Task<Void, Never>?
    private var activeChannelGroupSummary: CelestiChannelGroupSummary?
    private var activeChannelGroupPage = 0
    private var started = false

    init() {
        self.deviceId = DeviceIdentityStore.shared.deviceId
        log.log("AppModel init, deviceId: \(self.deviceId, privacy: .public)")
        self.playerController = PlayerController()
        self.quadPlayerController = QuadPlayerController()
        self.emergencyPlayerController = EmergencyPlayerController()
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
        quadPlayerController.stopAll()
        emergencyPlayerController.stopAll()
        layoutMode = .single
        activeChannelGroup = nil
        activeChannelGroupSummary = nil
        activeChannelGroupPage = 0
        selectedChannelID = nil
        channelGuideVisible = false
        channelGuideLoadingMore = false
    }

    func refreshChannelGroups() async {
        channelGroupsLoading = true
        channelGroupsError = nil
        do {
            channelGroups = try await channelLibraryService.groupSummaries(deviceID: deviceId)
            if let focusedChannelGroupID,
               !channelGroups.contains(where: { $0.id == focusedChannelGroupID }) {
                self.focusedChannelGroupID = nil
            }
        } catch {
            channelGroups = []
            channelGroupsError = error.localizedDescription
        }
        channelGroupsLoading = false
    }

    func selectChannelGroup(_ summary: CelestiChannelGroupSummary) async {
        guard summary.channelCount > 0 else { return }
        focusedChannelGroupID = summary.id
        channelGroupsLoading = true
        channelGroupsError = nil
        do {
            let group = try await channelLibraryService.channels(
                deviceID: deviceId,
                group: summary,
                page: 1
            )
            guard let first = group.channels.first else { throw URLError(.zeroByteResource) }
            playerController.stop()
            activeChannelGroupSummary = summary
            activeChannelGroupPage = 1
            activeChannelGroup = group
            channelGuideVisible = true
            selectLiveChannel(first)
        } catch {
            channelGroupsError = error.localizedDescription
        }
        channelGroupsLoading = false
    }

    func selectLiveChannel(_ channel: CelestiChannel) {
        selectedChannelID = channel.id
        TelemetryReporter.shared.setActiveChannel(channel.id)
    }

    func leaveChannelGroupPlayback() {
        playerController.stop()
        activeChannelGroup = nil
        activeChannelGroupSummary = nil
        activeChannelGroupPage = 0
        selectedChannelID = nil
        channelGuideVisible = false
        channelGuideLoadingMore = false
    }

    func loadMoreChannelsIfNeeded() {
        guard !channelGuideLoadingMore,
              let summary = activeChannelGroupSummary,
              let group = activeChannelGroup,
              group.channels.count < group.total else { return }

        channelGuideLoadingMore = true
        let nextPage = activeChannelGroupPage + 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.channelGuideLoadingMore = false }
            do {
                let next = try await self.channelLibraryService.channels(
                    deviceID: self.deviceId,
                    group: summary,
                    page: nextPage
                )
                guard self.activeChannelGroupSummary?.id == summary.id,
                      let current = self.activeChannelGroup else { return }
                let known = Set(current.channels.map(\.id))
                let newChannels = next.channels.filter { !known.contains($0.id) }
                self.activeChannelGroup = CelestiChannelGroup(
                    id: current.id,
                    name: current.name,
                    channels: current.channels + newChannels,
                    total: next.total
                )
                self.activeChannelGroupPage = nextPage
            } catch {
                log.error("Could not load the next channel page: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func togglePlayPause() {
        playerController.togglePlayPause()
        let isPaused = playerController.isPaused
        showDvrOverlay(action: isPaused ? .pause : .play)
    }

    func handlePlaybackSelect() {
        if dvrVisible {
            togglePlayPause()
        } else {
            showDvrOverlay(action: .none)
        }
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

    func restartApplication() {
        log.log("Restart application command received; resetting app lifecycle")
        registrationTask?.cancel()
        registrationTask = nil
        commandStream.disconnect()
        dvrAutoHideTask?.cancel()
        dvrAutoHideTask = nil
        callsign = nil
        nickname = nil
        dvrVisible = false
        dvrAction = .none
        playerController.stop()
        quadPlayerController.stopAll()
        emergencyPlayerController.stopAll()
        layoutMode = .single
        registrationState = .pending
        started = false
        startIfNeeded()
    }

    func restartPlayback() {
        if layoutMode == .emergency {
            emergencyPlayerController.restartFocused()
        } else if layoutMode == .quad {
            quadPlayerController.restartFocused()
        } else {
            playerController.restart()
        }
    }

    func adjustVolume(by percent: Int) {
        if layoutMode == .emergency {
            emergencyPlayerController.adjustVolume(by: percent)
        } else if layoutMode == .quad {
            quadPlayerController.adjustVolume(by: percent)
        } else {
            playerController.adjustVolume(by: percent)
        }
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
                        await self.refreshChannelGroups()
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
            activeChannelGroup = nil
            activeChannelGroupSummary = nil
            activeChannelGroupPage = 0
            channelGuideVisible = false
            guard let videoId = command.videoId, !videoId.isEmpty else {
                log.error("youtube command missing videoId")
                return
            }
            log.log("Opening YouTube videoId: \(videoId, privacy: .public)")
            playerController.openYouTube(videoId: videoId)
        case "m3u", "dash":
            activeChannelGroup = nil
            activeChannelGroupSummary = nil
            activeChannelGroupPage = 0
            channelGuideVisible = false
            guard let url = command.url, !url.isEmpty else {
                log.error("\(command.type, privacy: .public) command missing url")
                return
            }
            TelemetryReporter.shared.setActiveChannel(command.channelId)
            let requestedLayout = LayoutMode.from(command.layoutMode)
            if requestedLayout == .emergency {
                guard let position = command.quadrant, (0..<8).contains(position) else {
                    log.error("emergency playback command missing valid pool position")
                    return
                }
                layoutMode = .emergency
                playerController.stop()
                quadPlayerController.stopAll()
                await emergencyPlayerController.play(
                    slot: position,
                    channelId: command.channelId,
                    urlString: url,
                    name: command.name ?? command.title,
                    logoURLString: command.logo
                )
            } else if requestedLayout == .quad {
                guard let quadrant = Quadrant.from(command.quadrant) else {
                    log.error("quad playback command missing valid quadrant")
                    return
                }
                layoutMode = .quad
                playerController.stop()
                emergencyPlayerController.stopAll()
                await quadPlayerController.play(
                    urlString: url,
                    name: command.name ?? command.title,
                    logoURLString: command.logo,
                    channelId: command.channelId,
                    quadrant: quadrant
                )
            } else {
                layoutMode = .single
                quadPlayerController.stopAll()
                emergencyPlayerController.stopAll()
                await playerController.playStream(urlString: url, radioName: command.name ?? command.title)
            }
        case "stop":
            if let position = command.quadrant,
               (0..<8).contains(position),
               layoutMode == .emergency {
                log.log("Stop command received for emergency pool position \(position)")
                await emergencyPlayerController.stop(slot: position)
            } else if let quadrant = Quadrant.from(command.quadrant), layoutMode == .quad {
                log.log("Stop command received for quadrant \(quadrant.rawValue)")
                quadPlayerController.stop(quadrant: quadrant)
            } else {
                log.log("Stop command received")
                playerController.stop()
                quadPlayerController.stopAll()
                emergencyPlayerController.stopAll()
                layoutMode = .single
            }
        case "seize":
            log.log("Seize command received")
            dismissPlayback()
        case "restart_stream":
            if let position = command.quadrant,
               (0..<8).contains(position),
               layoutMode == .emergency {
                emergencyPlayerController.restart(slot: position)
            } else if let quadrant = Quadrant.from(command.quadrant), layoutMode == .quad {
                quadPlayerController.restart(quadrant: quadrant)
            } else {
                restartPlayback()
            }
        case "focus_audio":
            if let position = command.quadrant,
               (0..<8).contains(position),
               layoutMode == .emergency {
                emergencyPlayerController.focusAudio(slot: position)
            } else if let quadrant = Quadrant.from(command.quadrant), layoutMode == .quad {
                quadPlayerController.focusAudio(quadrant: quadrant)
            } else {
                log.warning("focus_audio command missing a valid active stream")
            }
        case "volume":
            adjustVolume(by: command.delta ?? 0)
        case "reboot":
            // tvOS does not expose an API that lets a third-party app reboot the device.
            log.warning("Reboot command ignored: unavailable to tvOS applications")
        case "restart_app":
            // tvOS cannot terminate and relaunch a third-party app. Reset every
            // app-owned lifecycle resource and reconnect from registration instead.
            restartApplication()
        case "layout":
            activeChannelGroup = nil
            activeChannelGroupSummary = nil
            activeChannelGroupPage = 0
            channelGuideVisible = false
            let newMode = LayoutMode.from(command.mode)
            log.log("Layout command received: \(newMode.rawValue, privacy: .public)")
            layoutMode = newMode
            if newMode == .quad {
                playerController.stop()
                emergencyPlayerController.stopAll()
            } else if newMode == .emergency {
                playerController.stop()
                quadPlayerController.stopAll()
            } else {
                quadPlayerController.stopAll()
                emergencyPlayerController.stopAll()
            }
        case "quad":
            activeChannelGroup = nil
            activeChannelGroupSummary = nil
            activeChannelGroupPage = 0
            channelGuideVisible = false
            guard let url = command.url, !url.isEmpty, let quadrant = Quadrant.from(command.quadrant) else {
                log.error("quad command missing url or valid quadrant")
                return
            }
            log.log("Quad play command: quadrant=\(quadrant.rawValue) url=\(url, privacy: .public)")
            layoutMode = .quad
            playerController.stop()
            emergencyPlayerController.stopAll()
            await quadPlayerController.play(
                urlString: url,
                name: command.name ?? command.title,
                logoURLString: command.logo,
                channelId: command.channelId,
                quadrant: quadrant
            )
        case "quad_stop":
            guard let quadrant = Quadrant.from(command.quadrant) else {
                log.error("quad_stop command missing valid quadrant")
                return
            }
            log.log("Quad stop command: quadrant=\(quadrant.rawValue)")
            quadPlayerController.stop(quadrant: quadrant)
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
    @Published var ksCoordinator: KSVideoPlayer.Coordinator?
    @Published var isUsingKSPlayer = false
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
    var currentURL: URL?
    private var originalURL: URL?
    private var currentM3U8File: URL?

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
    private let bufferProfile = PlaybackBufferPolicy.profile(for: .single)
    private var lastHealthSnapshotAt: Date = .distantPast
    private var lastHealthTelemetryAt: Date = .distantPast
    private var lastAccessLogRequestCount = 0
    private var offlineProbeCount = 0
    private var offlineProbeTask: Task<Void, Never>?

    // DVR auto-show tracking
    private var lastKnownTime: Double = 0
    private var lastKnownBuffering: Bool = false

    // Telemetry buffering tracking
    private var lastTelemetryBuffering: Bool = false
    private var bufferingTelemetryCandidateAt: Date?
    private var bufferingTelemetryReported = false
    private var stablePlaybackStartedAt: Date?

    private let watchdogInterval: TimeInterval = 3.0
    private let bufferingStallLimit: TimeInterval = 12.0
    private let stableWindowForUpgrade: TimeInterval = 300.0

    var isPaused: Bool {
        if isUsingKSPlayer {
            return ksCoordinator?.state == .paused
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
        let stoppedStreamName = currentRadioName
        let hadPlayback = currentSource != nil || player.currentItem != nil || isUsingKSPlayer
        stopWatchdog()
        removeTimeObserver()
        updateTask?.cancel()
        updateTask = nil

        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        offlineProbeTask?.cancel()
        offlineProbeTask = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let errorObserver {
            NotificationCenter.default.removeObserver(errorObserver)
            self.errorObserver = nil
        }
        if isUsingKSPlayer {
            ksCoordinator?.resetPlayer()
            ksCoordinator = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isUsingKSPlayer = false
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
        lastHealthSnapshotAt = .distantPast
        lastHealthTelemetryAt = .distantPast
        lastAccessLogRequestCount = 0
        offlineProbeCount = 0
        bufferingTelemetryCandidateAt = nil
        bufferingTelemetryReported = false
        stablePlaybackStartedAt = nil
        isPlaybackFailed = false
        failedStreamName = nil
        audioFallbackApplied = false
        currentPresentation = nil

        if hadPlayback {
            TelemetryReporter.shared.report(
                deviceCode: DeviceIdentityStore.shared.deviceId,
                eventType: .playbackStop,
                streamName: stoppedStreamName,
                layoutMode: .single
            )
        }

        UIApplication.shared.isIdleTimerDisabled = PlaybackIdleTimerPolicy.isDisabled(for: .inactive)
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
        if isUsingKSPlayer {
            if ksCoordinator?.state.isPlaying == true {
                ksCoordinator?.playerLayer?.pause()
            } else {
                ksCoordinator?.playerLayer?.play()
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

    func restart() {
        guard let url = originalURL else { return }
        let name = currentRadioName
        let source = currentSource ?? .remoteCommand
        Task { await play(urlString: url.absoluteString, radioName: name, source: source) }
    }

    func adjustVolume(by percent: Int) {
        let delta = Float(percent) / 100
        if isUsingKSPlayer {
            let current = ksCoordinator?.playbackVolume ?? 1
            ksCoordinator?.playbackVolume = min(1, max(0, current + delta))
        } else {
            player.volume = min(1, max(0, player.volume + delta))
        }
    }

    func seek(by seconds: Double) {
        guard !isPlaybackFailed else {
            playerLog.log("seek: ignored, playback failed")
            return
        }
        if isUsingKSPlayer {
            playerLog.log("seek: KSPlayer seek not supported for live streams")
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
            playerLog.log("play: \(format) detected, using KSPlayer")
            playWithKSPlayer(url: resolved.url, radioName: radioName, contentType: resolved.contentType)
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
        item.preferredForwardBufferDuration = bufferProfile.preferredForwardDuration
        playerLog.info(
            "event=buffer_profile viewport=single layout=single physicalMemoryMB=\(self.bufferProfile.physicalMemoryMB) lowMemory=\(self.bufferProfile.lowMemory) preferredSeconds=\(self.bufferProfile.preferredForwardDuration) maximumSeconds=\(self.bufferProfile.maximumDuration)"
        )

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

            TelemetryReporter.shared.report(
                deviceCode: DeviceIdentityStore.shared.deviceId,
                eventType: .playbackError,
                streamName: self.currentRadioName,
                layoutMode: .single,
                decoderType: .hardware,
                errorCode: "AVPlayerItemFailedToPlayToEndTime"
            )

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

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .playbackStart,
            streamName: radioName ?? currentURL?.lastPathComponent,
            streamUrl: urlString,
            layoutMode: .single,
            decoderType: .hardware,
            decoderName: "AVPlayer"
        )

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = PlaybackIdleTimerPolicy.isDisabled(for: .playing)
        }
    }

    private func playWithKSPlayer(url: URL, radioName: String?, contentType: String? = nil) {
        let coordinator = KSVideoPlayer.Coordinator()
        ksCoordinator = coordinator
        isUsingKSPlayer = true

        let options = KSOptions()
        options.userAgent = "VLC/3.0.21 LibVLC/3.0.21"
        options.preferredForwardBufferDuration = bufferProfile.preferredForwardDuration
        options.maxBufferDuration = bufferProfile.maximumDuration
        if contentType?.contains("dash+xml") == true || url.absoluteString.contains(".mpd") {
            playerLog.log("playWithKSPlayer: DASH stream")
        }

        coordinator.onStateChanged = { [weak self] _, state in
            self?.handleKSStateChange(state: state)
        }
        coordinator.onPlay = { [weak self] currentTime, totalTime in
            guard let self else { return }
            guard var presentation = self.currentPresentation else { return }
            presentation.currentTime = currentTime
            presentation.duration = totalTime
            self.currentPresentation = presentation
        }
        coordinator.onFinish = { [weak self] _, error in
            guard let self else { return }
            if let error {
                playerLog.error("KSPlayer finished with error: \(error, privacy: .public)")
                self.performEmergencyRecovery(reason: "ksplayer_error")
            }
        }

        playerLog.log("playWithKSPlayer: starting KSPlayer playback")
        playbackStartedAt = Date()

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .playbackStart,
            streamName: currentRadioName ?? url.lastPathComponent,
            streamUrl: url.absoluteString,
            layoutMode: .single,
            decoderType: .software,
            decoderName: "KSPlayer/FFmpeg"
        )

        // Trigger player creation; the view will own the coordinator.
        _ = coordinator.makeView(url: url, options: options)

        updateTask = Task { [weak self] in
            guard let self else { return }
            playerLog.log("playWithKSPlayer: starting presentation update task")
            while !Task.isCancelled {
                self.refreshPresentationState()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        UIApplication.shared.isIdleTimerDisabled = PlaybackIdleTimerPolicy.isDisabled(for: .playing)
    }

    private func handleKSStateChange(state: KSPlayerState) {
        guard var presentation = currentPresentation else { return }
        playerLog.log("KSPlayer state: \(state.description)")

        switch state {
        case .error:
            playerLog.error("KSPlayer error state, triggering recovery")
            performEmergencyRecovery(reason: "ksplayer_error")
        case .buffering, .preparing:
            presentation.isBuffering = true
        case .readyToPlay, .bufferFinished:
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

        if isUsingKSPlayer {
            let state = ksCoordinator?.state ?? .initialized
            let currentTime = ksCoordinator?.playerLayer?.player.currentPlaybackTime ?? 0
            let nowBuffering = !(state == .bufferFinished || currentTime > 0)
            if lastTelemetryBuffering != nowBuffering {
                lastTelemetryBuffering = nowBuffering
            }
            reportBufferingIfNeeded(nowBuffering, decoderType: .software)
            if state == .bufferFinished || currentTime > 0 {
                presentation.isBuffering = false
            }
            presentation.isPaused = state == .paused
            presentation.currentTime = currentTime
            presentation.duration = ksCoordinator?.playerLayer?.player.duration ?? 0
            updatePresentationDvr(&presentation)
            currentPresentation = presentation
            logKSPlaybackHealth(position: currentTime, state: state)
            resetOfflineProbeAfterStablePlayback(isPlaying: state == .bufferFinished)
            return
        }

        let item = player.currentItem
        let presentationSize = item?.presentationSize ?? .zero
        let hasVideo = presentationSize != .zero

        presentation.isAudioOnly = !hasVideo && currentSource != .demo
        let wasBufferingPreviously = lastTelemetryBuffering
        presentation.isBuffering = player.timeControlStatus != .playing
        presentation.isPaused = isPaused
        presentation.qualityTier = qualityTier

        if wasBufferingPreviously != presentation.isBuffering {
            lastTelemetryBuffering = presentation.isBuffering
            if let t0 = playbackStartedAt {
                let elapsed = Date().timeIntervalSince(t0)
                playerLog.log("refreshPresentationState: buffering changed \(wasBufferingPreviously) -> \(presentation.isBuffering) after \(elapsed, privacy: .public)s, timeControlStatus=\(self.player.timeControlStatus.rawValue)")
            } else {
                playerLog.log("refreshPresentationState: buffering changed \(wasBufferingPreviously) -> \(presentation.isBuffering), timeControlStatus=\(self.player.timeControlStatus.rawValue)")
            }
        }
        reportBufferingIfNeeded(presentation.isBuffering, decoderType: .hardware)
        resetOfflineProbeAfterStablePlayback(isPlaying: player.timeControlStatus == .playing)

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

        if !isUsingKSPlayer, !audioFallbackApplied {
            checkAudioTracks()
        }
    }

    private func reportBufferingIfNeeded(
        _ buffering: Bool,
        decoderType: TelemetryDecoderType
    ) {
        if buffering {
            if bufferingTelemetryCandidateAt == nil { bufferingTelemetryCandidateAt = Date() }
            guard !bufferingTelemetryReported,
                  let candidate = bufferingTelemetryCandidateAt,
                  Date().timeIntervalSince(candidate) >= 1 else { return }
            bufferingTelemetryReported = true
            TelemetryReporter.shared.report(
                deviceCode: DeviceIdentityStore.shared.deviceId,
                eventType: .bufferingStart,
                streamName: currentRadioName,
                streamUrl: currentURL?.absoluteString,
                layoutMode: .single,
                decoderType: decoderType
            )
            return
        }

        bufferingTelemetryCandidateAt = nil
        guard bufferingTelemetryReported else { return }
        bufferingTelemetryReported = false
        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .bufferingEnd,
            streamName: currentRadioName,
            streamUrl: currentURL?.absoluteString,
            layoutMode: .single,
            decoderType: decoderType
        )
    }

    private func logKSPlaybackHealth(position: TimeInterval, state: KSPlayerState) {
        let now = Date()
        guard now.timeIntervalSince(lastHealthSnapshotAt) >= 5 else { return }
        lastHealthSnapshotAt = now
        let stateName = String(describing: state)
        let healthStream = currentRadioName ?? "unknown"
        playerLog.info(
            "event=health stream=\(healthStream, privacy: .public) viewport=single layout=single state=\(stateName, privacy: .public) positionMs=\(Int(position * 1_000))"
        )
        if PlaybackRecoveryPolicy.shouldEmitRoutineHealth(
            lastEmittedAt: lastHealthTelemetryAt,
            now: now
        ) {
            lastHealthTelemetryAt = now
            TelemetryReporter.shared.report(
                deviceCode: DeviceIdentityStore.shared.deviceId,
                eventType: .playbackHealth,
                streamName: currentRadioName,
                streamUrl: currentURL?.absoluteString,
                layoutMode: .single,
                decoderType: .software,
                metadata: [
                    "state": stateName,
                    "positionMs": String(Int(position * 1_000)),
                    "physicalMemoryMB": bufferProfile.physicalMemoryMB.description,
                    "preferredBufferMs": String(Int(bufferProfile.preferredForwardDuration * 1_000)),
                ]
            )
        }
    }

    private func resetOfflineProbeAfterStablePlayback(isPlaying: Bool) {
        guard isPlaying else {
            stablePlaybackStartedAt = nil
            return
        }
        if stablePlaybackStartedAt == nil { stablePlaybackStartedAt = Date() }
        guard offlineProbeCount > 0,
              PlaybackRecoveryPolicy.shouldResetCircuit(
                  claimsToBePlaying: isPlaying,
                  stablePlaybackStartedAt: stablePlaybackStartedAt,
                  now: Date()
              ) else { return }
        offlineProbeCount = 0
        recoveryAttempt = 0
        playerLog.info("event=recovery_circuit_reset viewport=single layout=single")
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
        logPlaybackHealth(item: item)

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
                if freezeDuration >= PlaybackRecoveryPolicy.freezeTimeout {
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

    private func logPlaybackHealth(item: AVPlayerItem) {
        let now = Date()
        guard now.timeIntervalSince(lastHealthSnapshotAt) >= 5 else { return }
        lastHealthSnapshotAt = now

        let position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        let bufferedEnd = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .map { CMTimeRangeGetEnd($0).seconds }
            .filter(\.isFinite)
            .max() ?? position
        let bufferedDuration = max(0, bufferedEnd - position)
        var metadata: [String: String] = [
            "state": player.timeControlStatus == .playing ? "ready" : "buffering",
            "positionMs": String(Int(position * 1_000)),
            "bufferedDurationMs": String(Int(bufferedDuration * 1_000)),
            "physicalMemoryMB": bufferProfile.physicalMemoryMB.description,
            "preferredBufferMs": String(Int(bufferProfile.preferredForwardDuration * 1_000)),
        ]

        if let event = item.accessLog()?.events.last {
            metadata["observedBitrate"] = String(Int(event.observedBitrate))
            metadata["indicatedBitrate"] = String(Int(event.indicatedBitrate))
            metadata["stalls"] = event.numberOfStalls.description
            if event.numberOfMediaRequests != lastAccessLogRequestCount {
                lastAccessLogRequestCount = event.numberOfMediaRequests
                TelemetryReporter.shared.report(
                    deviceCode: DeviceIdentityStore.shared.deviceId,
                    eventType: .streamLoad,
                    streamName: currentRadioName,
                    streamUrl: currentURL?.absoluteString,
                    layoutMode: .single,
                    decoderType: .hardware,
                    bitrate: event.observedBitrate,
                    durationMs: Int(event.transferDuration * 1_000),
                    metadata: [
                        "result": "success",
                        "mediaRequests": event.numberOfMediaRequests.description,
                        "bytesTransferred": event.numberOfBytesTransferred.description,
                    ]
                )
            }
        }

        let healthStream = currentRadioName ?? currentURL?.absoluteString ?? "unknown"
        playerLog.info(
            "event=health stream=\(healthStream, privacy: .public) viewport=single layout=single positionMs=\(Int(position * 1_000)) bufferedDurationMs=\(Int(bufferedDuration * 1_000))"
        )
        if PlaybackRecoveryPolicy.shouldEmitRoutineHealth(
            lastEmittedAt: lastHealthTelemetryAt,
            now: now
        ) {
            lastHealthTelemetryAt = now
            TelemetryReporter.shared.report(
                deviceCode: DeviceIdentityStore.shared.deviceId,
                eventType: .playbackHealth,
                streamName: currentRadioName,
                streamUrl: currentURL?.absoluteString,
                layoutMode: .single,
                decoderType: .hardware,
                metadata: metadata
            )
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
            let attempt = recoveryAttempt
            let task = Task {
                await play(urlString: url.absoluteString, radioName: name, source: source)
                // play() performs a full cleanup, so retain the recovery budget
                // across the final re-resolution attempt.
                recoveryAttempt = attempt
            }
            recoveryTask = task
        } else if isUsingKSPlayer, let url = currentURL {
            playerLog.log("performRetry: restarting KSPlayer with \(url.absoluteString, privacy: .public)")
            ksCoordinator?.resetPlayer()
            playWithKSPlayer(url: url, radioName: currentRadioName, contentType: nil)
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

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .bitrateChanged,
            streamName: currentRadioName,
            layoutMode: .single,
            decoderType: isUsingKSPlayer ? .software : .hardware,
            bitrate: cap
        )
    }

    private func failPlayback() {
        guard offlineProbeTask == nil, let retryURL = originalURL else { return }
        isPlaybackFailed = true
        failedStreamName = currentRadioName ?? currentURL?.lastPathComponent ?? "Unknown"
        offlineProbeCount += 1
        let delay = PlaybackRecoveryPolicy.probeDelay(forAttempt: offlineProbeCount)
        let failedDecoderType: TelemetryDecoderType = isUsingKSPlayer ? .software : .hardware
        let offlineStream = failedStreamName ?? "unknown"
        playerLog.error(
            "event=source_offline stream=\(offlineStream, privacy: .public) viewport=single layout=single probe=\(self.offlineProbeCount) nextProbeSeconds=\(delay)"
        )

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .playbackFailure,
            streamName: failedStreamName,
            layoutMode: .single,
            decoderType: failedDecoderType,
            errorReason: "source_offline",
            metadata: [
                "probe": offlineProbeCount.description,
                "nextProbeMs": String(Int(delay * 1_000)),
            ]
        )

        stopWatchdog()
        ksCoordinator?.resetPlayer()
        ksCoordinator = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isUsingKSPlayer = false
        recoveryAttempt = 0
        UIApplication.shared.isIdleTimerDisabled = PlaybackIdleTimerPolicy.isDisabled(for: .offlineProbe)
        currentPresentation = PlaybackPresentation(
            source: currentSource ?? .remoteCommand,
            radioName: currentRadioName,
            streamTitle: nil,
            isAudioOnly: false,
            isBuffering: false,
            isPlaybackFailed: true,
            failedStreamName: failedStreamName
        )

        let retryName = currentRadioName
        let retrySource = currentSource ?? .remoteCommand
        let probe = offlineProbeCount
        offlineProbeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.offlineProbeTask = nil
            await self.play(
                urlString: retryURL.absoluteString,
                radioName: retryName,
                source: retrySource
            )
            self.offlineProbeCount = probe
        }
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

struct ResolvedStream {
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

final class StreamResolver {
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
            // routes these to KSPlayer (FFmpeg-based, handles TS natively).
            if contentType == "video/mp2t" {
                resolverLog.log("resolve: content-type=video/mp2t, KSPlayer will handle natively")
                return ResolvedStream(url: url, headers: [:], contentType: contentType, playlist: nil)
            }

            // DASH manifest — route to KSPlayer for FFmpeg DASH demux
            if contentType.contains("dash+xml") || url.absoluteString.contains(".mpd") {
                resolverLog.log("resolve: DASH manifest detected, KSPlayer will handle")
                return ResolvedStream(url: url, headers: [:], contentType: contentType, playlist: nil)
            }

            // RTMP stream — KSPlayer handles via FFmpeg
            if let scheme = url.scheme?.lowercased(), scheme == "rtmp" || scheme == "rtmps" {
                resolverLog.log("resolve: RTMP stream detected, KSPlayer will handle")
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
