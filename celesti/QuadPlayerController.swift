import AVFoundation
import Combine
import Foundation
import KSPlayer
import MediaToolbox
import OSLog
import SwiftUI
import UIKit

private let quadLog = Logger(subsystem: "com.gaulatti.celesti", category: "QuadPlayer")

private final class AudioPeakMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var format = AudioStreamBasicDescription()
    private var attached = false
    private weak var tappedNode: AVAudioNode?

    func attach(to item: AVPlayerItem, track: AVAssetTrack) {
        lock.lock()
        guard !attached else {
            lock.unlock()
            return
        }
        attached = true
        lock.unlock()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: nil,
            prepare: { tap, _, processingFormat in
                let monitor = Unmanaged<AudioPeakMonitor>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                monitor.setFormat(processingFormat.pointee)
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferList, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    numberFrames,
                    bufferList,
                    flagsOut,
                    nil,
                    numberFramesOut
                )
                guard status == noErr else { return }
                let monitor = Unmanaged<AudioPeakMonitor>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                monitor.capture(bufferList)
            }
        )

        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            // Capture before AVPlayer mute/volume effects, matching Pioggia's
            // audio-sink capture so every audio-only cell keeps metering.
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        ) == noErr, let tap else {
            markDetached()
            return
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    func attach(to engine: AVAudioEngine) {
        lock.lock()
        guard !attached else {
            lock.unlock()
            return
        }
        attached = true
        lock.unlock()

        let node = engine.mainMixerNode
        tappedNode = node
        node.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
    }

    func samplePeak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let current = peak
        peak *= 0.45
        return current
    }

    func reset() {
        tappedNode?.removeTap(onBus: 0)
        tappedNode = nil
        lock.lock()
        peak = 0
        attached = false
        lock.unlock()
    }

    private func markDetached() {
        lock.lock()
        attached = false
        lock.unlock()
    }

    private func setFormat(_ format: AudioStreamBasicDescription) {
        lock.lock()
        self.format = format
        lock.unlock()
    }

    private func capture(_ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        lock.lock()
        let streamFormat = format
        lock.unlock()

        var capturedPeak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            guard let data = buffer.mData else { continue }
            if streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for index in 0..<count {
                    capturedPeak = max(capturedPeak, abs(samples[index]))
                }
            } else if streamFormat.mBitsPerChannel == 16 {
                let samples = data.assumingMemoryBound(to: Int16.self)
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                for index in 0..<count {
                    capturedPeak = max(capturedPeak, Float(abs(Int(samples[index]))) / 32_768)
                }
            }
        }

        lock.lock()
        peak = max(peak, min(1, capturedPeak))
        lock.unlock()
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        var capturedPeak: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)

        if let channels = buffer.floatChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    capturedPeak = max(capturedPeak, abs(channels[channel][frame]))
                }
            }
        } else if let channels = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    capturedPeak = max(
                        capturedPeak,
                        Float(abs(Int(channels[channel][frame]))) / 32_768
                    )
                }
            }
        }

        lock.lock()
        peak = max(peak, min(1, capturedPeak))
        lock.unlock()
    }
}

// MARK: - Per-quadrant player

@MainActor
final class QuadrantPlayer: NSObject, ObservableObject {
    let quadrant: Quadrant

    let avPlayer = AVPlayer()
    @Published var ksCoordinator: KSVideoPlayer.Coordinator?
    @Published var isUsingKSPlayer = false

    @Published var isActive = false
    @Published var isBuffering = false
    @Published var isMuted = false
    @Published var isFailed = false
    @Published var isAudioOnly = false
    @Published var streamName: String?
    @Published var logoURL: URL?

    private var originalURL: URL?
    var currentURL: URL?
    private var currentM3U8File: URL?
    private var updateTask: Task<Void, Never>?
    private var trackDetectionTask: Task<Void, Never>?
    private var explicitlyAudioOnly = false
    private var errorObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private let audioPeakMonitor = AudioPeakMonitor()

    private let maxBitrate: Double = 800_000
    private var recoveryAttempt = 0
    private var lastTelemetryBuffering = false

    init(quadrant: Quadrant) {
        self.quadrant = quadrant
        super.init()
        avPlayer.isMuted = false
    }

    func play(urlString: String, name: String?, logoURLString: String? = nil) async {
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
        logoURL = logoURLString.flatMap(URL.init(string:))
        isActive = true
        isBuffering = true
        isFailed = false
        isAudioOnly = false

        let resolved = await StreamResolver().resolve(url: inputURL)
        currentURL = resolved.url
        explicitlyAudioOnly = resolved.contentType?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("audio/") == true
        isAudioOnly = explicitlyAudioOnly

        if resolved.contentType == "video/mp2t" || resolved.contentType == "rtmp" || resolved.contentType?.contains("dash+xml") == true || urlString.contains(".mpd") {
            playWithKSPlayer(url: resolved.url, contentType: resolved.contentType)
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

        // A live HLS asset may initially report zero video tracks even when it
        // contains video. Only positive video evidence is authoritative here;
        // an audio MIME type is handled immediately above.
        trackDetectionTask = Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                async let videoTracksResult = asset.loadTracks(withMediaType: .video)
                async let audioTracksResult = asset.loadTracks(withMediaType: .audio)
                let (videoTracks, audioTracks) = try await (videoTracksResult, audioTracksResult)
                guard self.avPlayer.currentItem === item else { return }
                if !videoTracks.isEmpty {
                    self.isAudioOnly = false
                }
                if let audioTrack = audioTracks.first {
                    self.audioPeakMonitor.attach(to: item, track: audioTrack)
                } else {
                    // HLS frequently exposes its selected audio track only on
                    // AVPlayerItem after playback has started.
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard self.avPlayer.currentItem === item else { return }
                        if let audioTrack = item.tracks
                            .compactMap(\.assetTrack)
                            .first(where: { $0.mediaType == .audio }) {
                            self.audioPeakMonitor.attach(to: item, track: audioTrack)
                            break
                        }
                    }
                }
                quadLog.log("[\(self.quadrant.displayName)] asset video tracks=\(videoTracks.count)")
            } catch {
                quadLog.warning("[\(self.quadrant.displayName)] unable to inspect tracks: \(error, privacy: .public)")
            }
        }

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .playbackStart,
            streamName: name ?? inputURL.lastPathComponent,
            streamUrl: urlString,
            quadrant: quadrant.rawValue,
            layoutMode: .quad,
            decoderType: .hardware,
            decoderName: "AVPlayer"
        )

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
                TelemetryReporter.shared.report(
                    deviceCode: DeviceIdentityStore.shared.deviceId,
                    eventType: .playbackError,
                    streamName: self.streamName,
                    quadrant: self.quadrant.rawValue,
                    layoutMode: .quad,
                    decoderType: .hardware,
                    errorCode: "AVPlayerItemFailedToPlayToEndTime"
                )
                self.performRecovery()
            }
        }

        startUpdateLoop()
    }

    func stop() {
        quadLog.log("[\(self.quadrant.displayName)] stop")
        updateTask?.cancel()
        updateTask = nil
        trackDetectionTask?.cancel()
        trackDetectionTask = nil

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
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        isUsingKSPlayer = false

        if let m3u8 = currentM3U8File {
            try? FileManager.default.removeItem(at: m3u8)
            currentM3U8File = nil
        }

        isActive = false
        isBuffering = false
        isFailed = false
        isAudioOnly = false
        explicitlyAudioOnly = false
        audioPeakMonitor.reset()
        currentURL = nil
        originalURL = nil
        logoURL = nil

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .playbackStop,
            streamName: streamName,
            quadrant: quadrant.rawValue,
            layoutMode: .quad
        )
    }

    func toggleMute() {
        isMuted.toggle()
        if isUsingKSPlayer {
            ksCoordinator?.isMuted = isMuted
        } else {
            avPlayer.isMuted = isMuted
        }
        quadLog.log("[\(self.quadrant.displayName)] mute=\(self.isMuted)")
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if isUsingKSPlayer {
            ksCoordinator?.isMuted = isMuted
        } else {
            avPlayer.isMuted = isMuted
        }
    }

    func restart() {
        guard let url = originalURL else { return }
        let name = streamName
        let logo = logoURL?.absoluteString
        Task { await play(urlString: url.absoluteString, name: name, logoURLString: logo) }
    }

    func adjustVolume(by percent: Int) {
        let delta = Float(percent) / 100
        if isUsingKSPlayer {
            let current = ksCoordinator?.playbackVolume ?? 1
            ksCoordinator?.playbackVolume = min(1, max(0, current + delta))
        } else {
            avPlayer.volume = min(1, max(0, avPlayer.volume + delta))
        }
    }

    func samplePeak() -> Float {
        audioPeakMonitor.samplePeak()
    }

    private func playWithKSPlayer(url: URL, contentType: String?) {
        let coordinator = KSVideoPlayer.Coordinator()
        ksCoordinator = coordinator
        isUsingKSPlayer = true

        let options = KSOptions()
        options.userAgent = "VLC/3.0.21 LibVLC/3.0.21"
        if contentType?.contains("dash+xml") == true || url.absoluteString.contains(".mpd") {
            quadLog.log("[\(self.quadrant.displayName)] DASH stream")
        }

        coordinator.onStateChanged = { [weak self] _, state in
            Task { @MainActor [weak self] in
                self?.handleKSStateChange(state: state)
            }
        }
        coordinator.onFinish = { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil {
                    quadLog.error("[\(self.quadrant.displayName)] KSPlayer finished with error")
                    self.performRecovery()
                }
            }
        }

        coordinator.isMuted = isMuted
        _ = coordinator.makeView(url: url, options: options)
        startUpdateLoop()

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .playbackStart,
            streamName: streamName ?? url.lastPathComponent,
            streamUrl: url.absoluteString,
            quadrant: quadrant.rawValue,
            layoutMode: .quad,
            decoderType: .software,
            decoderName: "KSPlayer/FFmpeg"
        )
    }

    private func handleKSStateChange(state: KSPlayerState) {
        switch state {
        case .error:
            quadLog.error("[\(self.quadrant.displayName)] KSPlayer error state")
            performRecovery()
        case .buffering, .preparing:
            isBuffering = true
        case .readyToPlay, .bufferFinished:
            isBuffering = false
            updateKSPlayerMediaKind()
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
        if isUsingKSPlayer {
            let state = ksCoordinator?.state ?? .initialized
            let currentTime = ksCoordinator?.playerLayer?.player.currentPlaybackTime ?? 0
            let nowBuffering = !(state == .bufferFinished || currentTime > 0)
            if lastTelemetryBuffering != nowBuffering {
                lastTelemetryBuffering = nowBuffering
                TelemetryReporter.shared.report(
                    deviceCode: DeviceIdentityStore.shared.deviceId,
                    eventType: nowBuffering ? .bufferingStart : .bufferingEnd,
                    streamName: streamName,
                    quadrant: quadrant.rawValue,
                    layoutMode: .quad,
                    decoderType: .software
                )
            }
            if state == .bufferFinished || currentTime > 0 {
                isBuffering = false
                updateKSPlayerMediaKind()
            }
            return
        }

        let item = avPlayer.currentItem
        if item?.presentationSize != .zero {
            isAudioOnly = false
        } else if explicitlyAudioOnly {
            isAudioOnly = true
        }
        let wasBuffering = isBuffering
        isBuffering = avPlayer.timeControlStatus != .playing
        if wasBuffering != isBuffering {
            quadLog.log("[\(self.quadrant.displayName)] buffering \(wasBuffering) -> \(self.isBuffering)")
        }
        if lastTelemetryBuffering != isBuffering {
            lastTelemetryBuffering = isBuffering
            TelemetryReporter.shared.report(
                deviceCode: DeviceIdentityStore.shared.deviceId,
                eventType: isBuffering ? .bufferingStart : .bufferingEnd,
                streamName: streamName,
                quadrant: quadrant.rawValue,
                layoutMode: .quad,
                decoderType: .hardware
            )
        }
    }

    private func updateKSPlayerMediaKind() {
        guard let mediaPlayer = ksCoordinator?.playerLayer?.player else { return }
        if let enginePlayer = (mediaPlayer as? KSMEPlayer)?.audioOutput as? AudioEnginePlayer {
            audioPeakMonitor.attach(to: enginePlayer.engine)
        }
        let videoTracks = mediaPlayer.tracks(mediaType: .video)
        let audioTracks = mediaPlayer.tracks(mediaType: .audio)
        // Wait until the demuxer has exposed at least one track before deciding.
        if !videoTracks.isEmpty || !audioTracks.isEmpty {
            isAudioOnly = videoTracks.isEmpty
        }
    }

    private func performRecovery() {
        guard let url = originalURL else {
            markFailed()
            return
        }
        let nextAttempt = recoveryAttempt + 1
        recoveryAttempt = nextAttempt
        if nextAttempt > 3 {
            markFailed()
            return
        }
        quadLog.log("[\(self.quadrant.displayName)] recovery attempt \(self.recoveryAttempt)")
        Task {
            let name = streamName
            let logo = logoURL?.absoluteString
            await play(urlString: url.absoluteString, name: name, logoURLString: logo)
            recoveryAttempt = nextAttempt
        }
    }

    private func markFailed() {
        isFailed = true
        isBuffering = false

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .playbackFailure,
            streamName: streamName,
            quadrant: quadrant.rawValue,
            layoutMode: .quad,
            decoderType: isUsingKSPlayer ? .software : .hardware,
            errorReason: "max_recovery_attempts"
        )
    }
}

// MARK: - Quad manager

@MainActor
final class QuadPlayerController: ObservableObject {
    @Published var focusedQuadrant: Quadrant = .topLeft
    @Published var isFocusBorderVisible = true
    @Published var isActive = false
    @Published var expandedQuadrant: Quadrant?

    private var players: [Quadrant: QuadrantPlayer] = [:]
    private var unmutedByUser: Set<Quadrant> = []
    private var hideFocusTask: Task<Void, Never>?

    func player(for quadrant: Quadrant) -> QuadrantPlayer {
        if let existing = players[quadrant] {
            return existing
        }
        let newPlayer = QuadrantPlayer(quadrant: quadrant)
        players[quadrant] = newPlayer
        return newPlayer
    }

    func play(urlString: String, name: String?, logoURLString: String? = nil, quadrant: Quadrant) async {
        isActive = true
        await player(for: quadrant).play(urlString: urlString, name: name, logoURLString: logoURLString)
        applyVolumes()
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
        isFocusBorderVisible = true
        hideFocusTask?.cancel()
        hideFocusTask = nil
        expandedQuadrant = nil
        unmutedByUser.removeAll()
    }

    func moveFocus(direction: MoveCommandDirection) {
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
        @unknown default:
            return
        }

        if let next = Quadrant.allCases.first(where: { $0.row == row && $0.column == col }) {
            focusedQuadrant = next
            applyVolumes()
            revealFocusBorderTemporarily()
        }
    }

    func toggleMuteFocused() {
        if unmutedByUser.contains(focusedQuadrant) {
            unmutedByUser.remove(focusedQuadrant)
        } else {
            unmutedByUser.insert(focusedQuadrant)
        }
        applyVolumes()
        revealFocusBorderTemporarily()
    }

    func focus(_ quadrant: Quadrant) {
        focusedQuadrant = quadrant
        applyVolumes()
        revealFocusBorderTemporarily()
    }

    func showFocusedSingleView() {
        guard expandedQuadrant == nil else { return }
        expandedQuadrant = focusedQuadrant
        applyVolumes()
    }

    @discardableResult
    func restoreQuadView() -> Bool {
        guard expandedQuadrant != nil else { return false }
        expandedQuadrant = nil
        applyVolumes()
        revealFocusBorderTemporarily()
        return true
    }

    func restartFocused() {
        players[focusedQuadrant]?.restart()
    }

    func restart(quadrant: Quadrant) {
        players[quadrant]?.restart()
    }

    func focusAudio(quadrant: Quadrant) {
        guard players[quadrant]?.isActive == true else { return }
        focusedQuadrant = quadrant
        unmutedByUser.removeAll()
        applyVolumes()
        revealFocusBorderTemporarily()
        quadLog.log("Audio focused on \(quadrant.displayName, privacy: .public)")
    }

    func adjustVolume(by percent: Int) {
        players.values.filter(\.isActive).forEach { $0.adjustVolume(by: percent) }
    }

    private func applyVolumes() {
        for (quadrant, player) in players {
            let audible = quadrant == (expandedQuadrant ?? focusedQuadrant) || unmutedByUser.contains(quadrant)
            player.setMuted(!audible)
        }
    }

    private func revealFocusBorderTemporarily() {
        isFocusBorderVisible = true
        hideFocusTask?.cancel()
        hideFocusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.isFocusBorderVisible = false
        }
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
