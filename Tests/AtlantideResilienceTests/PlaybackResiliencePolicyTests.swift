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

@Test func telemetryRedactsCredentialsAndBoundsCardinality() {
    let signed = "https://user:secret@Media.Example.test/live/feed.m3u8?token=credential&expires=1#fragment"
    #expect(TelemetryPrivacy.sanitizedStreamURL(signed) == "https://Media.Example.test/live/feed.m3u8")
    #expect(TelemetryPrivacy.sanitizedStreamURL("file:///private/secret.m3u8") == nil)
    #expect(TelemetryPrivacy.boundedIdentity(String(repeating: "x", count: 200))?.count == 128)
    #expect(TelemetryPrivacy.boundedMetadata(Dictionary(uniqueKeysWithValues: (0..<20).map { ("key\($0)", String(repeating: "v", count: 300)) }))?.count == 16)
    #expect(TelemetryPrivacy.boundedMetadata(["key": String(repeating: "v", count: 300)])?["key"]?.count == 256)
}

private func profile(_ preferred: TimeInterval, _ maximum: TimeInterval, _ memory: UInt64, _ lowMemory: Bool) -> PlaybackBufferProfile {
    PlaybackBufferProfile(
        preferredForwardDuration: preferred,
        maximumDuration: maximum,
        physicalMemoryMB: memory,
        lowMemory: lowMemory
    )
}
