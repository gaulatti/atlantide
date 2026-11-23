import Foundation
import Testing
@testable import AtlantideResilience

@Test func bufferProfilesMatchAcceptedLowAndHighMemoryPolicy() {
    #expect(PlaybackBufferPolicy.profile(for: .single, physicalMemoryMB: 2_048) == profile(15, 30, 2_048, true))
    #expect(PlaybackBufferPolicy.profile(for: .single, physicalMemoryMB: 4_096) == profile(20, 45, 4_096, false))
    #expect(PlaybackBufferPolicy.profile(for: .quad, physicalMemoryMB: 2_048) == profile(8, 18, 2_048, true))
    #expect(PlaybackBufferPolicy.profile(for: .quad, physicalMemoryMB: 4_096) == profile(12, 25, 4_096, false))
    #expect(PlaybackBufferPolicy.profile(for: .emergency, physicalMemoryMB: 2_048) == profile(6, 12, 2_048, true))
    #expect(PlaybackBufferPolicy.profile(for: .emergency, physicalMemoryMB: 4_096) == profile(8, 18, 4_096, false))
}

@Test func recoveryPolicyDetectsFreezeCircuitProbeScheduleAndStableReset() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(!PlaybackRecoveryPolicy.isFrozen(claimsToBePlaying: false, lastPositionAdvancedAt: now.addingTimeInterval(-9), now: now))
    #expect(!PlaybackRecoveryPolicy.isFrozen(claimsToBePlaying: true, lastPositionAdvancedAt: now.addingTimeInterval(-7.99), now: now))
    #expect(PlaybackRecoveryPolicy.isFrozen(claimsToBePlaying: true, lastPositionAdvancedAt: now.addingTimeInterval(-8), now: now))

    let recent = [-89.0, -30.0, 0.0].map { now.addingTimeInterval($0) }
    #expect(PlaybackRecoveryPolicy.shouldEnterOfflineProbe(after: recent, now: now))
    #expect(!PlaybackRecoveryPolicy.shouldEnterOfflineProbe(after: [now.addingTimeInterval(-91)] + Array(recent.dropFirst()), now: now))
    #expect((1...6).map(PlaybackRecoveryPolicy.probeDelay) == [30, 60, 120, 240, 300, 300])
    #expect(!PlaybackRecoveryPolicy.shouldResetCircuit(claimsToBePlaying: true, stablePlaybackStartedAt: now.addingTimeInterval(-59), now: now))
    #expect(PlaybackRecoveryPolicy.shouldResetCircuit(claimsToBePlaying: true, stablePlaybackStartedAt: now.addingTimeInterval(-60), now: now))
    #expect(!PlaybackRecoveryPolicy.shouldEmitRoutineHealth(lastEmittedAt: now.addingTimeInterval(-29), now: now))
    #expect(PlaybackRecoveryPolicy.shouldEmitRoutineHealth(lastEmittedAt: now.addingTimeInterval(-30), now: now))
}

@Test func idleTimerStaysDisabledOnlyDuringActivePlayback() {
    #expect(PlaybackIdleTimerPolicy.isDisabled(for: .playing))
    #expect(!PlaybackIdleTimerPolicy.isDisabled(for: .inactive))
    #expect(!PlaybackIdleTimerPolicy.isDisabled(for: .offlineProbe))
    #expect(PlaybackIdleTimerPolicy.isDisabledForLiveChannel(playbackState: .playing, applicationIsActive: true))
    for state in [ChannelViewingPlaybackState.starting, .buffering, .paused, .failed, .stopped] {
        #expect(!PlaybackIdleTimerPolicy.isDisabledForLiveChannel(playbackState: state, applicationIsActive: true))
    }
    #expect(!PlaybackIdleTimerPolicy.isDisabledForLiveChannel(playbackState: .playing, applicationIsActive: false))
}

@Test func outOfOrderPlaybackResolutionAcceptsOnlyTheLatestRequest() {
    var arbiter = PlaybackRequestArbiter()
    let requestA = arbiter.begin()
    let requestB = arbiter.begin()

    #expect(!arbiter.accepts(requestA))
    #expect(arbiter.accepts(requestB))
    #expect(arbiter.accepts(arbiter.currentRequest()))

    arbiter.invalidate()
    #expect(!arbiter.accepts(requestB))

    let scheduledBeforeStop = arbiter.currentRequest()
    arbiter.invalidate()
    #expect(!arbiter.accepts(scheduledBeforeStop))
}

@Test func emergencyCarouselPreservesAssignmentsWhileSkippingAndRestoringFailures() {
    let assigned = [0, 1, 2, 3]
    #expect(EmergencyCarouselPolicy.visibleSlots(assignedSlots: assigned, offlineSlots: [], windowStartSlot: 0) == [0, 1])
    #expect(EmergencyCarouselPolicy.visibleSlots(assignedSlots: assigned, offlineSlots: [0], windowStartSlot: 0) == [1, 2])
    #expect(EmergencyCarouselPolicy.healthySlots(assignedSlots: assigned, offlineSlots: [0]) == [1, 2, 3])
    #expect(EmergencyCarouselPolicy.visibleSlots(assignedSlots: assigned, offlineSlots: [], windowStartSlot: 0) == [0, 1])
    #expect(EmergencyCarouselPolicy.visibleSlots(assignedSlots: assigned, offlineSlots: Set(assigned), windowStartSlot: 0) == [nil, nil])
}

@Test func aPlayCommandForTheStreamAlreadyPlayingHealthilyIsADuplicate() {
    let url = "https://media.example.test/live/feed.ts"
    #expect(PlaybackCommandPolicy.isDuplicate(requestedURL: url, requestedChannelID: "c1", playingURL: url, playingChannelID: "c1", isHealthy: true))
    #expect(PlaybackCommandPolicy.isDuplicate(requestedURL: url, requestedChannelID: nil, playingURL: url, playingChannelID: nil, isHealthy: true))
    // A failed or offline stream is retried, another stream or channel is a real change.
    #expect(!PlaybackCommandPolicy.isDuplicate(requestedURL: url, requestedChannelID: "c1", playingURL: url, playingChannelID: "c1", isHealthy: false))
    #expect(!PlaybackCommandPolicy.isDuplicate(requestedURL: url, requestedChannelID: "c1", playingURL: "https://other.example.test/a.ts", playingChannelID: "c1", isHealthy: true))
    #expect(!PlaybackCommandPolicy.isDuplicate(requestedURL: url, requestedChannelID: "c1", playingURL: url, playingChannelID: "c2", isHealthy: true))
    #expect(!PlaybackCommandPolicy.isDuplicate(requestedURL: url, requestedChannelID: "c1", playingURL: nil, playingChannelID: nil, isHealthy: true))
}

@Test func theCommandConnectionBacksOffWhenTheServerKeepsClosingIt() {
    // A connection that lasted is reopened after a second and the backoff resets.
    #expect(CommandStreamReconnectPolicy.next(connectionLifetime: 120, previousBackoff: 16) == (1, 1))
    #expect(CommandStreamReconnectPolicy.next(connectionLifetime: 10, previousBackoff: 8) == (1, 1))
    // Connections that end within seconds back off up to the cap, never a tight loop.
    var backoff = CommandStreamReconnectPolicy.initialBackoff
    var delays: [TimeInterval] = []
    for _ in 0..<7 {
        let step = CommandStreamReconnectPolicy.next(connectionLifetime: 2, previousBackoff: backoff)
        delays.append(step.delay)
        backoff = step.nextBackoff
    }
    #expect(delays == [1, 2, 4, 8, 16, 30, 30])
    #expect(CommandStreamReconnectPolicy.next(connectionLifetime: 0, previousBackoff: 0).delay == 1)
}

@Test func telemetryMetadataEncodesAsTheEndpointTypesIt() throws {
    let metadata = try #require(TelemetryPrivacy.backendMetadata([
        "healthy": "true", "recoveryExhausted": "false", "bufferedDurationMs": "1500", "result": "failure",
    ]))
    let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
    #expect(object["healthy"] as? Bool == true)
    #expect(object["recoveryExhausted"] as? Bool == false)
    #expect(object["bufferedDurationMs"] as? Double == 1500)
    #expect(object["result"] as? String == "failure")
}

@Test func everyKeyTheEndpointAcceptsIsConvertedAndBounded() {
    let accepted: [String: String] = [
        "success": "true", "liveOffsetMs": "-1", "playbackSpeed": "1", "status": "503", "dataType": "media",
        "recoveryResult": "started", "eventName": "ping", "hardwareDecoders": "2", "softwareDecoders": "0",
        "hardwareVideoDecoders": "1", "softwareVideoDecoders": "1", "throughputBps": "12",
    ]
    let converted = TelemetryPrivacy.backendMetadata(accepted)
    #expect(converted?.count == accepted.count)
    #expect(converted?["liveOffsetMs"] == .number(-1))
    #expect(converted?["success"] == .flag(true))
    #expect(converted?["dataType"] == .text("media"))
    // Values outside each key's bounds are dropped.
    for (key, value) in [("playbackSpeed", "5"), ("liveOffsetMs", "-2"), ("hardwareDecoders", "33"), ("throughputBps", "-1"), ("bytesLoaded", "-3"),
                         ("success", "yes"), ("dataType", "audio"), ("recoveryResult", "later"), ("eventName", String(repeating: "e", count: 129)),
                         ("method", String(repeating: "m", count: 17)), ("state", "paused")] {
        #expect(TelemetryPrivacy.backendMetadata([key: value]) == nil, "\(key)=\(value)")
    }
}

@Test func telemetryMetadataIsCappedAtSixteenEntries() {
    let many = Dictionary(uniqueKeysWithValues: ["healthy", "isPlaying", "recoveryExhausted", "success"].map { ($0, "true") })
    #expect(TelemetryPrivacy.backendMetadata(many)?.count == 4)
}

@Test func telemetryMetadataKeepsOnlyWhatTheEndpointAcceptsWithItsTypes() {
    #expect(TelemetryPrivacy.boundedIdentity(String(repeating: "x", count: 200))?.count == 128)
    let health = TelemetryPrivacy.backendMetadata([
        "state": "ready",
        "positionMs": "4916",
        "bufferedDurationMs": "11645",
        "physicalMemoryMB": "3010",
        "preferredBufferMs": "20000",
        "observedBitrate": "6128079",
        "indicatedBitrate": "6128079",
        "stalls": "0",
    ])
    #expect(health == [
        "isPlaying": .flag(true),
        "bufferedDurationMs": .number(11645),
        "throughputBps": .number(6128079),
    ])
    #expect(TelemetryPrivacy.backendMetadata(["state": "buffering"]) == ["isPlaying": .flag(false)])
    #expect(TelemetryPrivacy.backendMetadata(["result": "success", "mediaRequests": "3", "bytesTransferred": "12765808"]) == [
        "result": .text("success"),
        "bytesLoaded": .number(12765808),
    ])
    // Out-of-range, unparseable and unknown values are dropped rather than failing the whole event.
    #expect(TelemetryPrivacy.backendMetadata(["bufferedDurationMs": "-5", "status": "700", "result": "maybe", "probe": "1", "nextProbeMs": "30000"]) == nil)
    #expect(TelemetryPrivacy.backendMetadata(["bufferedDurationMs": "NaN"]) == nil)
    #expect(TelemetryPrivacy.backendMetadata(nil) == nil)
    #expect(TelemetryPrivacy.backendMetadata(["page": String(repeating: "p", count: 257), "method": "POST"]) == ["method": .text("POST")])
}


private func profile(_ preferred: TimeInterval, _ maximum: TimeInterval, _ memory: UInt64, _ lowMemory: Bool) -> PlaybackBufferProfile {
    PlaybackBufferProfile(
        preferredForwardDuration: preferred,
        maximumDuration: maximum,
        physicalMemoryMB: memory,
        lowMemory: lowMemory
    )
}

@Test func stopCommandRoutesByNamedPositionAndLayout() {
    // No position: everything, in every layout.
    for layout in [TelemetryLayoutMode.single, .quad, .emergency] {
        #expect(StopCommandPolicy.route(position: nil, layout: layout) == .everything)
    }
    // Quad: a quadrant stops that quadrant; positions 4 to 7 are not quadrants.
    #expect((0...3).map { StopCommandPolicy.route(position: $0, layout: .quad) } == (0...3).map { .quadrant($0) })
    #expect((4...7).map { StopCommandPolicy.route(position: $0, layout: .quad) } == Array(repeating: .everything, count: 4))
    // Emergency: any of the 8 positions stops that slot, including 0 to 3.
    #expect((0...7).map { StopCommandPolicy.route(position: $0, layout: .emergency) } == (0...7).map { .emergencySlot($0) })
    // Single: a quadrant stop never tears down the stream (Mattone sends one before every quad play).
    #expect((0...3).map { StopCommandPolicy.route(position: $0, layout: .single) } == Array(repeating: .ignored, count: 4))
    #expect(StopCommandPolicy.route(position: 5, layout: .single) == .everything)
    // Out of range or negative positions are not slots.
    for layout in [TelemetryLayoutMode.single, .quad, .emergency] {
        #expect(StopCommandPolicy.route(position: 8, layout: layout) == .everything)
        #expect(StopCommandPolicy.route(position: -1, layout: layout) == .everything)
    }
}
