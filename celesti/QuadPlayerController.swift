import AVFoundation
import Combine
import Foundation
import KSPlayer
import MediaToolbox
import OSLog
import SwiftUI
import UIKit

private let quadLog = Logger(subsystem: "com.gaulatti.celesti", category: "QuadPlayer")
private let playbackHealthLog = Logger(subsystem: "com.gaulatti.celesti", category: "PlaybackHealth")

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
    let telemetryLayoutMode: TelemetryLayoutMode

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
    @Published var failureStatus = "RETRYING"
    var onPlaybackFailure: ((String?) -> Void)?
    var onStableRecovery: (() -> Void)?

    private var originalURL: URL?
    var currentURL: URL?
    private var currentM3U8File: URL?
    private var updateTask: Task<Void, Never>?
    private var trackDetectionTask: Task<Void, Never>?
    private var explicitlyAudioOnly = false
    private var errorObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private let audioPeakMonitor = AudioPeakMonitor()
    private let bufferProfile: PlaybackBufferProfile

    private let maxBitrate: Double = 800_000
    private var currentChannelId: String?
    private var recoveryAttempt = 0
    private var bufferingTelemetryReported = false
    private var bufferingCandidateAt: Date?
    private var offlineProbeTask: Task<Void, Never>?
    private var offlineProbeCount = 0
    private var recentRecoveryTimes: [Date] = []
    private var lastPlaybackErrorAt: Date?
    private var lastHealthSnapshotAt: Date = .distantPast
    private var lastHealthTelemetryAt: Date = .distantPast
    private var lastObservedPosition: TimeInterval = -1
    private var lastPositionAdvancedAt: Date = .distantPast
    private var lastStallRecoveryAt: Date = .distantPast
    private var lastAccessLogRequestCount = 0

    init(quadrant: Quadrant, layoutMode: TelemetryLayoutMode = .quad) {
        self.quadrant = quadrant
        self.telemetryLayoutMode = layoutMode
        self.bufferProfile = PlaybackBufferPolicy.profile(for: layoutMode)
        super.init()
        avPlayer.isMuted = false
    }

    func play(
        urlString: String,
        name: String?,
        logoURLString: String? = nil,
        channelId: String? = nil,
        preserveRecoveryState: Bool = false
    ) async {
        guard let inputURL = URL(string: urlString) else {
            quadLog.error("[\(self.quadrant.displayName)] invalid URL: \(urlString, privacy: .public)")
            isFailed = true
            isBuffering = false
            failureStatus = "INVALID FEED"
            onPlaybackFailure?("invalid_url")
            return
        }

        quadLog.log("[\(self.quadrant.displayName)] play: \(urlString, privacy: .public) name=\(name ?? "nil", privacy: .public)")
        let retainedProbeCount = offlineProbeCount
        let retainedRecoveryTimes = recentRecoveryTimes
        stop()
        if preserveRecoveryState {
            offlineProbeCount = retainedProbeCount
            recentRecoveryTimes = retainedRecoveryTimes
        }
        recoveryAttempt = 0
        originalURL = inputURL
        currentChannelId = channelId
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
        item.preferredForwardBufferDuration = bufferProfile.preferredForwardDuration

        playbackHealthLog.info(
            "event=buffer_profile stream=\(self.streamIdentity, privacy: .public) viewport=\(self.quadrant.rawValue) layout=\(self.telemetryLayoutMode.rawValue, privacy: .public) physicalMemoryMB=\(self.bufferProfile.physicalMemoryMB) lowMemory=\(self.bufferProfile.lowMemory) preferredSeconds=\(self.bufferProfile.preferredForwardDuration) maximumSeconds=\(self.bufferProfile.maximumDuration)"
        )

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
            channelId: currentChannelId,
            streamName: name ?? inputURL.lastPathComponent,
            streamUrl: urlString,
            quadrant: quadrant.rawValue,
            layoutMode: telemetryLayoutMode,
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
                    channelId: self.currentChannelId,
                    streamName: self.streamName,
                    quadrant: self.quadrant.rawValue,
                    layoutMode: self.telemetryLayoutMode,
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
        let stoppedChannelId = currentChannelId
        updateTask?.cancel()
        updateTask = nil
        offlineProbeTask?.cancel()
        offlineProbeTask = nil
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
        bufferingCandidateAt = nil
        bufferingTelemetryReported = false
        offlineProbeCount = 0
        recentRecoveryTimes.removeAll()
        lastPlaybackErrorAt = nil
        lastHealthTelemetryAt = .distantPast
        lastHealthSnapshotAt = .distantPast
        lastObservedPosition = -1
        lastPositionAdvancedAt = .distantPast
        lastStallRecoveryAt = .distantPast
        lastAccessLogRequestCount = 0
        audioPeakMonitor.reset()
        currentURL = nil
        originalURL = nil
        currentChannelId = nil
        logoURL = nil

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .playbackStop,
            channelId: stoppedChannelId,
            streamName: streamName,
            quadrant: quadrant.rawValue,
            layoutMode: telemetryLayoutMode
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
        let channelId = currentChannelId
        Task {
            await play(
                urlString: url.absoluteString,
                name: name,
                logoURLString: logo,
                channelId: channelId
            )
        }
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
        options.preferredForwardBufferDuration = bufferProfile.preferredForwardDuration
        options.maxBufferDuration = bufferProfile.maximumDuration
        playbackHealthLog.info(
            "event=buffer_profile stream=\(self.streamIdentity, privacy: .public) viewport=\(self.quadrant.rawValue) layout=\(self.telemetryLayoutMode.rawValue, privacy: .public) physicalMemoryMB=\(self.bufferProfile.physicalMemoryMB) lowMemory=\(self.bufferProfile.lowMemory) preferredSeconds=\(self.bufferProfile.preferredForwardDuration) maximumSeconds=\(self.bufferProfile.maximumDuration) engine=KSPlayer"
        )
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
            channelId: currentChannelId,
            streamName: streamName ?? url.lastPathComponent,
            streamUrl: url.absoluteString,
            quadrant: quadrant.rawValue,
            layoutMode: telemetryLayoutMode,
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
            updateBufferingTelemetry(nowBuffering, decoderType: .software)
            if state == .bufferFinished || currentTime > 0 {
                isBuffering = false
                updateKSPlayerMediaKind()
            }
            logHealthIfNeeded(position: currentTime, bufferedDuration: nil, decoderType: .software)
            detectFrozenPlayback(position: currentTime, claimsToBePlaying: state == .bufferFinished)
            resetRecoveryCircuitIfStable(claimsToBePlaying: state == .bufferFinished)
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
        updateBufferingTelemetry(isBuffering, decoderType: .hardware)
        let position = finiteSeconds(avPlayer.currentTime())
        let bufferedDuration = bufferedDurationForAVPlayer()
        logHealthIfNeeded(position: position, bufferedDuration: bufferedDuration, decoderType: .hardware)
        detectFrozenPlayback(
            position: position,
            claimsToBePlaying: avPlayer.timeControlStatus == .playing && avPlayer.rate > 0
        )
        resetRecoveryCircuitIfStable(claimsToBePlaying: avPlayer.timeControlStatus == .playing)
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

    private func updateBufferingTelemetry(
        _ buffering: Bool,
        decoderType: TelemetryDecoderType
    ) {
        if buffering {
            if bufferingCandidateAt == nil { bufferingCandidateAt = Date() }
            guard !bufferingTelemetryReported,
                  let candidate = bufferingCandidateAt,
                  Date().timeIntervalSince(candidate) >= 1 else { return }
            bufferingTelemetryReported = true
            TelemetryReporter.shared.report(
                deviceCode: DeviceIdentityStore.shared.deviceId,
                eventType: .bufferingStart,
                channelId: currentChannelId,
                streamName: streamName,
                quadrant: quadrant.rawValue,
                layoutMode: telemetryLayoutMode,
                decoderType: decoderType
            )
            return
        }

        bufferingCandidateAt = nil
        guard bufferingTelemetryReported else { return }
        bufferingTelemetryReported = false
        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .bufferingEnd,
            channelId: currentChannelId,
            streamName: streamName,
            quadrant: quadrant.rawValue,
            layoutMode: telemetryLayoutMode,
            decoderType: decoderType
        )
    }

    private func logHealthIfNeeded(
        position: TimeInterval,
        bufferedDuration: TimeInterval?,
        decoderType: TelemetryDecoderType
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastHealthSnapshotAt) >= 5 else { return }
        lastHealthSnapshotAt = now

        var metadata: [String: String] = [
            "state": playbackStateName,
            "isBuffering": isBuffering.description,
            "positionMs": milliseconds(position),
            "physicalMemoryMB": bufferProfile.physicalMemoryMB.description,
            "preferredBufferMs": milliseconds(bufferProfile.preferredForwardDuration),
        ]
        if let bufferedDuration {
            metadata["bufferedDurationMs"] = milliseconds(bufferedDuration)
        }
        if let item = avPlayer.currentItem,
           let event = item.accessLog()?.events.last {
            metadata["observedBitrate"] = String(Int(event.observedBitrate))
            metadata["indicatedBitrate"] = String(Int(event.indicatedBitrate))
            metadata["stalls"] = event.numberOfStalls.description
            if event.numberOfMediaRequests != lastAccessLogRequestCount {
                lastAccessLogRequestCount = event.numberOfMediaRequests
                TelemetryReporter.shared.report(
                    deviceCode: DeviceIdentityStore.shared.deviceId,
                    eventType: .streamLoad,
                    channelId: currentChannelId,
                    streamName: streamName,
                    streamUrl: currentURL?.absoluteString,
                    quadrant: quadrant.rawValue,
                    layoutMode: telemetryLayoutMode,
                    decoderType: decoderType,
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

        let healthChannelId = currentChannelId ?? "none"
        let healthBufferedDuration = metadata["bufferedDurationMs"] ?? "unknown"
        playbackHealthLog.info(
            "event=health stream=\(self.streamIdentity, privacy: .public) channelId=\(healthChannelId, privacy: .public) viewport=\(self.quadrant.rawValue) layout=\(self.telemetryLayoutMode.rawValue, privacy: .public) state=\(self.playbackStateName, privacy: .public) positionMs=\(self.milliseconds(position), privacy: .public) bufferedDurationMs=\(healthBufferedDuration, privacy: .public)"
        )
        if PlaybackRecoveryPolicy.shouldEmitRoutineHealth(
            lastEmittedAt: lastHealthTelemetryAt,
            now: now
        ) {
            lastHealthTelemetryAt = now
            TelemetryReporter.shared.report(
                deviceCode: DeviceIdentityStore.shared.deviceId,
                eventType: .playbackHealth,
                channelId: currentChannelId,
                streamName: streamName,
                streamUrl: currentURL?.absoluteString,
                quadrant: quadrant.rawValue,
                layoutMode: telemetryLayoutMode,
                decoderType: decoderType,
                metadata: metadata
            )
        }
    }

    private func detectFrozenPlayback(position: TimeInterval, claimsToBePlaying: Bool) {
        let now = Date()
        if lastObservedPosition < 0 || position > lastObservedPosition + 0.25 {
            lastObservedPosition = position
            lastPositionAdvancedAt = now
            return
        }
        guard PlaybackRecoveryPolicy.isFrozen(
            claimsToBePlaying: claimsToBePlaying,
            lastPositionAdvancedAt: lastPositionAdvancedAt,
            now: now
        ),
              now.timeIntervalSince(lastStallRecoveryAt) >= 20 else { return }
        lastStallRecoveryAt = now
        playbackHealthLog.warning(
            "event=frozen_recovery stream=\(self.streamIdentity, privacy: .public) viewport=\(self.quadrant.rawValue) layout=\(self.telemetryLayoutMode.rawValue, privacy: .public)"
        )
        recoverToLiveEdge()
    }

    private func recoverToLiveEdge() {
        let now = Date()
        lastPlaybackErrorAt = now
        recentRecoveryTimes = PlaybackRecoveryPolicy.recoveriesWithinWindow(
            recentRecoveryTimes,
            now: now
        )
        recentRecoveryTimes.append(now)
        if PlaybackRecoveryPolicy.shouldEnterOfflineProbe(after: recentRecoveryTimes, now: now) {
            recentRecoveryTimes.removeAll()
            enterOfflineProbe(reason: "unsustainable_live_window")
            return
        }

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .liveRecovery,
            channelId: currentChannelId,
            streamName: streamName,
            streamUrl: currentURL?.absoluteString,
            quadrant: quadrant.rawValue,
            layoutMode: telemetryLayoutMode,
            metadata: ["state": playbackStateName]
        )
        if isUsingKSPlayer {
            performRecovery(reason: "live_edge")
            return
        }
        guard let range = avPlayer.currentItem?.seekableTimeRanges.last?.timeRangeValue else {
            performRecovery(reason: "live_edge_unavailable")
            return
        }
        let liveEdge = CMTimeRangeGetEnd(range)
        let target = CMTimeSubtract(liveEdge, CMTime(seconds: 6, preferredTimescale: 600))
        avPlayer.seek(to: target > range.start ? target : range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        avPlayer.play()
    }

    private func performRecovery(reason: String = "playback_error") {
        guard let url = originalURL else {
            enterOfflineProbe(reason: reason)
            return
        }
        lastPlaybackErrorAt = Date()
        let nextAttempt = recoveryAttempt + 1
        recoveryAttempt = nextAttempt
        if nextAttempt > 3 {
            enterOfflineProbe(reason: reason)
            return
        }
        quadLog.log("[\(self.quadrant.displayName)] recovery attempt \(self.recoveryAttempt) reason=\(reason, privacy: .public)")
        Task {
            let name = streamName
            let logo = logoURL?.absoluteString
            let channelId = currentChannelId
            await play(
                urlString: url.absoluteString,
                name: name,
                logoURLString: logo,
                channelId: channelId,
                preserveRecoveryState: true
            )
            recoveryAttempt = nextAttempt
            lastPlaybackErrorAt = Date()
        }
    }

    private func enterOfflineProbe(reason: String) {
        guard offlineProbeTask == nil, let url = originalURL else { return }
        lastPlaybackErrorAt = Date()
        offlineProbeCount += 1
        let delay = PlaybackRecoveryPolicy.probeDelay(forAttempt: offlineProbeCount)
        isFailed = true
        isBuffering = false
        failureStatus = reason == "unsustainable_live_window" ? "FEED TOO SLOW" : "FEED OFFLINE"

        let failedDecoderType: TelemetryDecoderType = isUsingKSPlayer ? .software : .hardware
        releaseEnginesForOfflineProbe()
        playbackHealthLog.warning(
            "event=source_offline stream=\(self.streamIdentity, privacy: .public) viewport=\(self.quadrant.rawValue) layout=\(self.telemetryLayoutMode.rawValue, privacy: .public) reason=\(reason, privacy: .public) probe=\(self.offlineProbeCount) nextProbeSeconds=\(delay)"
        )

        TelemetryReporter.shared.report(
            deviceCode: DeviceIdentityStore.shared.deviceId,
            eventType: .playbackFailure,
            channelId: currentChannelId,
            streamName: streamName,
            streamUrl: currentURL?.absoluteString,
            quadrant: quadrant.rawValue,
            layoutMode: telemetryLayoutMode,
            decoderType: failedDecoderType,
            errorReason: reason,
            metadata: [
                "probe": offlineProbeCount.description,
                "nextProbeMs": milliseconds(delay),
            ]
        )
        onPlaybackFailure?(reason)

        let name = streamName
        let logo = logoURL?.absoluteString
        let channelId = currentChannelId
        offlineProbeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.offlineProbeTask = nil
            await self.play(
                urlString: url.absoluteString,
                name: name,
                logoURLString: logo,
                channelId: channelId,
                preserveRecoveryState: true
            )
        }
    }

    private func releaseEnginesForOfflineProbe() {
        updateTask?.cancel()
        updateTask = nil
        trackDetectionTask?.cancel()
        trackDetectionTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        endObserver = nil
        errorObserver = nil
        ksCoordinator?.resetPlayer()
        ksCoordinator = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        isUsingKSPlayer = false
        audioPeakMonitor.reset()
    }

    private func resetRecoveryCircuitIfStable(claimsToBePlaying: Bool) {
        guard let lastPlaybackErrorAt,
              PlaybackRecoveryPolicy.shouldResetCircuit(
                  claimsToBePlaying: claimsToBePlaying,
                  stablePlaybackStartedAt: lastPlaybackErrorAt,
                  now: Date()
              ) else { return }
        offlineProbeCount = 0
        recoveryAttempt = 0
        recentRecoveryTimes.removeAll()
        self.lastPlaybackErrorAt = nil
        isFailed = false
        playbackHealthLog.info(
            "event=recovery_circuit_reset stream=\(self.streamIdentity, privacy: .public) viewport=\(self.quadrant.rawValue) layout=\(self.telemetryLayoutMode.rawValue, privacy: .public)"
        )
        onStableRecovery?()
    }

    private var streamIdentity: String {
        streamName ?? currentURL?.absoluteString ?? originalURL?.absoluteString ?? "unknown"
    }

    private var playbackStateName: String {
        if isUsingKSPlayer { return String(describing: ksCoordinator?.state ?? .initialized) }
        switch avPlayer.timeControlStatus {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "buffering"
        case .playing: return "ready"
        @unknown default: return "unknown"
        }
    }

    private func bufferedDurationForAVPlayer() -> TimeInterval {
        guard let item = avPlayer.currentItem else { return 0 }
        let position = finiteSeconds(avPlayer.currentTime())
        let end = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .map { finiteSeconds(CMTimeRangeGetEnd($0)) }
            .max() ?? position
        return max(0, end - position)
    }

    private func finiteSeconds(_ time: CMTime) -> TimeInterval {
        let seconds = time.seconds
        return seconds.isFinite ? seconds : 0
    }

    private func milliseconds(_ seconds: TimeInterval) -> String {
        String(Int(max(0, seconds) * 1_000))
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

    func play(
        urlString: String,
        name: String?,
        logoURLString: String? = nil,
        channelId: String? = nil,
        quadrant: Quadrant
    ) async {
        isActive = true
        await player(for: quadrant).play(
            urlString: urlString,
            name: name,
            logoURLString: logoURLString,
            channelId: channelId
        )
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
