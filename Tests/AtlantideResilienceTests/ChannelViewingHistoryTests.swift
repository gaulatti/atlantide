import Foundation
import Testing
@testable import AtlantideResilience

@Test func accumulatorCheckpointsAtSixtySecondsAndFlushesWholeSecondRemainder() async throws {
    let harness = try ViewingHistoryHarness()

    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: 59)
    try await harness.accumulator.checkpoint()
    #expect(await harness.outbox.count == 0)
    #expect(try await harness.accumulator.unpersistedActiveSeconds() == 59)

    harness.monotonic.advance(by: 1)
    try await harness.accumulator.checkpoint()
    #expect(await harness.outbox.snapshot.map(\.segment.activeSeconds) == [60])
    #expect(try await harness.accumulator.unpersistedActiveSeconds() == 0)

    harness.monotonic.advance(by: 1.75)
    try await harness.accumulator.transition(to: .stopped)

    let segments = await harness.outbox.snapshot.map(\.segment)
    #expect(segments.map(\.activeSeconds) == [60, 1])
    #expect(segments.allSatisfy { $0.activeSeconds <= 60 })
    #expect(segments[0].startedAt == Date(timeIntervalSince1970: 1_000))
    #expect(segments[0].endedAt == Date(timeIntervalSince1970: 1_060))
    #expect(segments[1].startedAt == Date(timeIntervalSince1970: 1_060))
    #expect(segments[1].endedAt == Date(timeIntervalSince1970: 1_061))
    #expect(try await harness.accumulator.unpersistedActiveSeconds() == 0)
}

@Test func nonPlayingStatesNeverAccrueAndEqualPlayingTransitionsDoNotReset() async throws {
    let harness = try ViewingHistoryHarness()

    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: 10)
    try await harness.accumulator.transition(to: .buffering)
    harness.monotonic.advance(by: 30)
    try await harness.accumulator.transition(to: .paused)
    try await harness.accumulator.transition(to: .inactive)
    try await harness.accumulator.transition(to: .failed)
    try await harness.accumulator.transition(to: .stopped)
    #expect(await harness.outbox.snapshot.map(\.segment.activeSeconds) == [10])

    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: 30)
    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: 30)
    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: 10)
    try await harness.accumulator.transition(to: .stopped)

    #expect(await harness.outbox.snapshot.map(\.segment.activeSeconds) == [10, 60, 10])
}

@Test func channelSwitchFlushesOldChannelBeforeNewChannelCanAccrue() async throws {
    let harness = try ViewingHistoryHarness()

    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: 10.8)
    try await harness.accumulator.transition(to: .playing(channelId: "channel-b"))
    harness.monotonic.advance(by: 2.2)
    try await harness.accumulator.transition(to: .channelChanged(to: "channel-c"))
    harness.monotonic.advance(by: 20)
    try await harness.accumulator.transition(to: .stopped)

    let segments = await harness.outbox.snapshot.map(\.segment)
    #expect(segments.map(\.channelId) == ["channel-a", "channel-b"])
    #expect(segments.map(\.activeSeconds) == [10, 2])
}

@Test func rapidChannelChangesDiscardOnlySubsecondResidue() async throws {
    let harness = try ViewingHistoryHarness()

    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: 0.9)
    try await harness.accumulator.transition(to: .playing(channelId: "channel-b"))
    harness.monotonic.advance(by: 0.9)
    try await harness.accumulator.transition(to: .stopped)

    #expect(await harness.outbox.count == 0)
}

@Test func wallClockAdjustmentsCannotChangeActiveDurationOrContinuousTimestamps() async throws {
    let harness = try ViewingHistoryHarness()

    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: 61)
    harness.wall.set(Date(timeIntervalSince1970: -10_000))
    try await harness.accumulator.transition(to: .stopped)

    let segments = await harness.outbox.snapshot.map(\.segment)
    #expect(segments.map(\.activeSeconds) == [60, 1])
    #expect(segments[0].startedAt == Date(timeIntervalSince1970: 1_000))
    #expect(segments[1].endedAt == Date(timeIntervalSince1970: 1_061))
}

@Test func persistedSegmentsRetryAcrossRelaunchWithTheSameIdentity() async throws {
    let persistence = MemoryChannelViewingPersistence()
    let segment = makeSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let firstOutbox = try DurableChannelViewingOutbox(persistence: persistence)
    try await firstOutbox.enqueue(segment)
    let retryingTransport = ScriptedChannelViewingTransport(
        outcomes: [.retryableFailure],
        persistence: persistence
    )

    #expect(
        try await firstOutbox.deliverNext(using: retryingTransport)
            == .retained(segmentId: segment.segmentId, outcome: .retryableFailure)
    )
    #expect(await firstOutbox.snapshot[0].deliveryAttempts == 1)
    #expect(await firstOutbox.snapshot[0].status == .retrying)

    let relaunchedOutbox = try DurableChannelViewingOutbox(persistence: persistence)
    #expect(await relaunchedOutbox.snapshot.map(\.segment.segmentId) == [segment.segmentId])

    let recordedTransport = ScriptedChannelViewingTransport(
        outcomes: [.recorded],
        persistence: persistence
    )
    #expect(
        try await relaunchedOutbox.deliverNext(using: recordedTransport)
            == .acknowledged(segmentId: segment.segmentId, outcome: .recorded)
    )
    #expect(await relaunchedOutbox.count == 0)
    #expect(await retryingTransport.deliveredSegmentIds == [segment.segmentId])
    #expect(await recordedTransport.deliveredSegmentIds == [segment.segmentId])
    #expect(await retryingTransport.sawPersistedStateBeforeDelivery)
    #expect(await recordedTransport.sawPersistedStateBeforeDelivery)
}

@Test func filePersistenceRecoversTheVersionedOutboxFromDisk() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("atlantide-viewing-history-tests")
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("outbox.json")
    let persistence = FileChannelViewingOutboxPersistence(fileURL: fileURL)
    let segment = makeSegment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    )
    let firstOutbox = try DurableChannelViewingOutbox(persistence: persistence)
    try await firstOutbox.enqueue(segment)

    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    let encoded = try Data(contentsOf: fileURL)
    #expect(String(decoding: encoded, as: UTF8.self).contains(#""schemaVersion":1"#))

    let relaunchedOutbox = try DurableChannelViewingOutbox(persistence: persistence)
    #expect(await relaunchedOutbox.snapshot.map(\.segment) == [segment])
}

@Test func duplicateAcknowledgementRemovesExactlyOnceAndDuplicateEnqueueIsIdempotent() async throws {
    let persistence = MemoryChannelViewingPersistence()
    let outbox = try DurableChannelViewingOutbox(persistence: persistence)
    let segment = makeSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    #expect(try await outbox.enqueue(segment))
    #expect(try await !outbox.enqueue(segment))
    #expect(await outbox.count == 1)

    let transport = ScriptedChannelViewingTransport(outcomes: [.duplicate], persistence: persistence)
    #expect(
        try await outbox.deliverNext(using: transport)
            == .acknowledged(segmentId: segment.segmentId, outcome: .duplicate)
    )
    #expect(await outbox.count == 0)
    #expect(try await outbox.deliverNext(using: transport) == .empty)
}

@Test func terminalRejectionRemainsDurableAndDoesNotBlockLaterSegments() async throws {
    let persistence = MemoryChannelViewingPersistence()
    let outbox = try DurableChannelViewingOutbox(persistence: persistence)
    let first = makeSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let second = makeSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    try await outbox.enqueue([first, second])
    let transport = ScriptedChannelViewingTransport(
        outcomes: [.terminalRejection, .recorded],
        persistence: persistence
    )

    #expect(
        try await outbox.deliverNext(using: transport)
            == .retained(segmentId: first.segmentId, outcome: .terminalRejection)
    )
    #expect(
        try await outbox.deliverNext(using: transport)
            == .acknowledged(segmentId: second.segmentId, outcome: .recorded)
    )
    #expect(try await outbox.deliverNext(using: transport) == .empty)

    let snapshot = await outbox.snapshot
    #expect(snapshot.count == 1)
    #expect(snapshot[0].segment.segmentId == first.segmentId)
    #expect(snapshot[0].status == .terminallyRejected)

    let relaunchedOutbox = try DurableChannelViewingOutbox(persistence: persistence)
    #expect(await relaunchedOutbox.snapshot == snapshot)
}

@Test func boundedOutboxRejectsOverflowAndConflictingIdentitiesWithoutMutation() async throws {
    let persistence = MemoryChannelViewingPersistence()
    let outbox = try DurableChannelViewingOutbox(persistence: persistence, maximumSegments: 1)
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    let first = makeSegment(id: id)
    try await outbox.enqueue(first)

    do {
        try await outbox.enqueue(makeSegment(id: id, channelId: "different"))
        Issue.record("Expected a conflicting segment error")
    } catch {
        #expect(error as? ChannelViewingOutboxError == .conflictingSegment(id))
    }

    do {
        try await outbox.enqueue(makeSegment(id: UUID()))
        Issue.record("Expected an outbox capacity error")
    } catch {
        #expect(error as? ChannelViewingOutboxError == .capacityExceeded(limit: 1))
    }

    #expect(await outbox.snapshot.map(\.segment) == [first])
}

@Test func outboxRejectsInvalidCapacityAndMalformedSegments() async throws {
    let persistence = MemoryChannelViewingPersistence()
    do {
        _ = try DurableChannelViewingOutbox(persistence: persistence, maximumSegments: 0)
        Issue.record("Expected an invalid outbox capacity error")
    } catch {
        #expect(error as? ChannelViewingOutboxError == .invalidCapacity(0))
    }

    let outbox = try DurableChannelViewingOutbox(persistence: persistence)
    let malformed = ChannelViewingSegment(
        segmentId: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        channelId: "channel-a",
        activeSeconds: 61,
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_061)
    )
    do {
        try await outbox.enqueue(malformed)
        Issue.record("Expected an invalid segment error")
    } catch {
        #expect(error as? ChannelViewingOutboxError == .invalidSegment(malformed.segmentId))
    }
    #expect(await outbox.count == 0)
}

@Test func corruptAndUnknownPersistenceSchemasFailClosed() throws {
    let corrupt = MemoryChannelViewingPersistence(data: Data("not-json".utf8))
    do {
        _ = try DurableChannelViewingOutbox(persistence: corrupt)
        Issue.record("Expected corrupt state to fail")
    } catch {
        #expect(error as? ChannelViewingOutboxError == .corruptState)
    }

    let future = MemoryChannelViewingPersistence(
        data: Data(#"{"schemaVersion":2,"entries":[]}"#.utf8)
    )
    do {
        _ = try DurableChannelViewingOutbox(persistence: future)
        Issue.record("Expected an unknown schema to fail")
    } catch {
        #expect(error as? ChannelViewingOutboxError == .unsupportedSchemaVersion(2))
    }
}

@Test func persistedCheckpointSurvivesAccumulatorCrashWithLessThanSixtySecondsAtRisk() async throws {
    let persistence = MemoryChannelViewingPersistence()
    let monotonic = TestMonotonicClock()
    let wall = TestWallClock(Date(timeIntervalSince1970: 1_000))
    let ids = SequenceChannelViewingIDSource()
    let firstOutbox = try DurableChannelViewingOutbox(persistence: persistence)
    var accumulator: ActiveChannelViewingAccumulator? = ActiveChannelViewingAccumulator(
        outbox: firstOutbox,
        monotonicClock: monotonic,
        wallClock: wall,
        segmentIDSource: ids
    )

    try await accumulator?.transition(to: .playing(channelId: "channel-a"))
    monotonic.advance(by: 119.9)
    try await accumulator?.checkpoint()
    #expect(await firstOutbox.snapshot.map(\.segment.activeSeconds) == [60])
    let atRiskSeconds = try await accumulator?.unpersistedActiveSeconds() ?? 0
    #expect(abs(atRiskSeconds - 59.9) < 0.000_001)
    #expect(atRiskSeconds < 60)

    accumulator = nil
    let relaunchedOutbox = try DurableChannelViewingOutbox(persistence: persistence)
    #expect(await relaunchedOutbox.snapshot.map(\.segment.activeSeconds) == [60])
}

@Test func failedStopPersistenceFreezesElapsedTimeAndRetriesTheSameBatch() async throws {
    let harness = try ViewingHistoryHarness()
    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: 10.9)
    harness.persistence.failNextSave()

    do {
        try await harness.accumulator.transition(to: .stopped)
        Issue.record("Expected the first persistence attempt to fail")
    } catch {
        #expect(error is TestPersistenceError)
    }

    harness.monotonic.advance(by: 50)
    try await harness.accumulator.transition(to: .stopped)

    let segments = await harness.outbox.snapshot.map(\.segment)
    #expect(segments.map(\.activeSeconds) == [10])
    #expect(
        segments.map(\.segmentId)
            == [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!]
    )
}

@Test func monotonicClockRegressionFailsWithoutMutatingTheOutbox() async throws {
    let harness = try ViewingHistoryHarness()
    try await harness.accumulator.transition(to: .playing(channelId: "channel-a"))
    harness.monotonic.advance(by: -1)

    do {
        try await harness.accumulator.checkpoint()
        Issue.record("Expected a monotonic clock regression to fail")
    } catch {
        #expect(error as? ChannelViewingAccumulatorError == .monotonicClockMovedBackward)
    }
    #expect(await harness.outbox.count == 0)
}

private struct ViewingHistoryHarness {
    let persistence: MemoryChannelViewingPersistence
    let monotonic: TestMonotonicClock
    let wall: TestWallClock
    let outbox: DurableChannelViewingOutbox
    let accumulator: ActiveChannelViewingAccumulator

    init() throws {
        persistence = MemoryChannelViewingPersistence()
        monotonic = TestMonotonicClock()
        wall = TestWallClock(Date(timeIntervalSince1970: 1_000))
        outbox = try DurableChannelViewingOutbox(persistence: persistence)
        accumulator = ActiveChannelViewingAccumulator(
            outbox: outbox,
            monotonicClock: monotonic,
            wallClock: wall,
            segmentIDSource: SequenceChannelViewingIDSource()
        )
    }
}

private final class MemoryChannelViewingPersistence: ChannelViewingOutboxPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var shouldFailNextSave = false

    init(data: Data? = nil) {
        storedData = data
    }

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw TestPersistenceError()
        }
        storedData = data
    }

    func failNextSave() {
        lock.lock()
        defer { lock.unlock() }
        shouldFailNextSave = true
    }

    var hasPersistedState: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedData?.isEmpty == false
    }
}

private struct TestPersistenceError: Error {}

private final class TestMonotonicClock: ChannelViewingMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value += seconds
    }
}

private final class TestWallClock: ChannelViewingWallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

private final class SequenceChannelViewingIDSource: ChannelViewingSegmentIDSource, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

private actor ScriptedChannelViewingTransport: ChannelViewingTransport {
    private var outcomes: [ChannelViewingDeliveryOutcome]
    private let persistence: MemoryChannelViewingPersistence
    private(set) var deliveredSegmentIds: [UUID] = []
    private(set) var sawPersistedStateBeforeDelivery = true

    init(
        outcomes: [ChannelViewingDeliveryOutcome],
        persistence: MemoryChannelViewingPersistence
    ) {
        self.outcomes = outcomes
        self.persistence = persistence
    }

    func deliver(_ segment: ChannelViewingSegment) async -> ChannelViewingDeliveryOutcome {
        sawPersistedStateBeforeDelivery =
            sawPersistedStateBeforeDelivery && persistence.hasPersistedState
        deliveredSegmentIds.append(segment.segmentId)
        return outcomes.removeFirst()
    }
}

private func makeSegment(
    id: UUID,
    channelId: String = "channel-a"
) -> ChannelViewingSegment {
    ChannelViewingSegment(
        segmentId: id,
        channelId: channelId,
        activeSeconds: 10,
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_010)
    )
}
