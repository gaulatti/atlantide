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

@Test func fiveWallClockMinutesWithTwoMinutesBufferingDeliversThreeActiveMinutes() async throws {
    let harness = try ViewingHistoryHarness()
    let transport = RecordingChannelViewingTransport()
    let controller = ChannelViewingHistoryController(
        accumulator: harness.accumulator,
        outbox: harness.outbox,
        transport: transport,
        automaticTasks: false
    )

    await controller.receive(playbackEvent(.onDevice, "channel-a", .playing))
    harness.monotonic.advance(by: 120)
    await controller.receive(playbackEvent(.onDevice, "channel-a", .buffering))
    harness.monotonic.advance(by: 120)
    await controller.receive(playbackEvent(.onDevice, "channel-a", .playing))
    harness.monotonic.advance(by: 60)
    await controller.receive(playbackEvent(.onDevice, "channel-a", .stopped))
    await controller.drainAvailableSegmentsNow()

    let delivered = await transport.delivered
    #expect(delivered.map(\.activeSeconds).reduce(0, +) == 180)
    #expect(delivered.allSatisfy { (1...60).contains($0.activeSeconds) })
    #expect(await harness.outbox.count == 0)
}

@Test func explicitDrainSerializesWithAutomaticDeliveryBeforeReturning() async throws {
    let harness = try ViewingHistoryHarness()
    let transport = CancellableFirstChannelViewingTransport()
    let controller = ChannelViewingHistoryController(
        accumulator: harness.accumulator,
        outbox: harness.outbox,
        transport: transport
    )

    await controller.setRegistrationAvailable(true)
    await controller.setNetworkAvailable(true)
    await controller.receive(playbackEvent(.onDevice, "channel-a", .playing))
    harness.monotonic.advance(by: 301)
    await controller.receive(playbackEvent(.onDevice, "channel-a", .stopped))
    await transport.waitUntilFirstDeliveryStarts()
    await controller.drainAvailableSegmentsNow()

    let delivered = await transport.delivered
    let uniqueSeconds = Dictionary(grouping: delivered, by: \.segmentId)
        .values
        .compactMap { $0.first?.activeSeconds }
        .reduce(0, +)
    #expect(uniqueSeconds == 301)
    #expect(delivered.prefix(2).map(\.segmentId).allSatisfy { $0 == delivered[0].segmentId })
    #expect(await harness.outbox.count == 0)
}

@Test func explicitDrainCancelsRetryScheduleAndLeavesRetryableSegmentDurable() async throws {
    let harness = try ViewingHistoryHarness()
    let transport = RetryingChannelViewingTransport()
    let controller = ChannelViewingHistoryController(
        accumulator: harness.accumulator,
        outbox: harness.outbox,
        transport: transport
    )

    await controller.setRegistrationAvailable(true)
    await controller.setNetworkAvailable(true)
    await controller.receive(playbackEvent(.onDevice, "channel-a", .playing))
    harness.monotonic.advance(by: 1)
    await controller.receive(playbackEvent(.onDevice, "channel-a", .stopped))
    await transport.waitForAttempt()

    let clock = ContinuousClock()
    let started = clock.now
    await controller.drainAvailableSegmentsNow()

    #expect(started.duration(to: clock.now) < .milliseconds(500))
    #expect(await transport.attempts == 2)
    #expect(await harness.outbox.count == 1)
    #expect(await harness.outbox.snapshot[0].status == .retrying)
}

@Test func explicitDrainQueuesAutomaticStartUntilItsOneShotFinishes() async throws {
    let harness = try ViewingHistoryHarness()
    let transport = SuspendedChannelViewingTransport()
    let controller = ChannelViewingHistoryController(
        accumulator: harness.accumulator,
        outbox: harness.outbox,
        transport: transport
    )

    await controller.setRegistrationAvailable(true)
    await controller.receive(playbackEvent(.onDevice, "channel-a", .playing))
    harness.monotonic.advance(by: 1)
    await controller.receive(playbackEvent(.onDevice, "channel-a", .stopped))

    let barrier = Task { await controller.drainAvailableSegmentsNow() }
    await transport.waitForAttempt()
    await controller.setNetworkAvailable(true)
    for _ in 0..<10 { await Task.yield() }
    #expect(await transport.attempts == 1)

    await transport.release()
    await barrier.value
    for _ in 0..<10 { await Task.yield() }

    #expect(await transport.attempts == 1)
    #expect(await harness.outbox.count == 0)
}

@Test func sourceSwitchPauseAndBackgroundCloseAttributionWithoutAcceptingStaleStops() async throws {
    let harness = try ViewingHistoryHarness()
    let transport = RecordingChannelViewingTransport()
    let controller = ChannelViewingHistoryController(
        accumulator: harness.accumulator,
        outbox: harness.outbox,
        transport: transport,
        automaticTasks: false
    )

    await controller.receive(playbackEvent(.onDevice, "channel-a", .playing))
    harness.monotonic.advance(by: 301)
    await controller.receive(playbackEvent(.onDevice, "channel-b", .starting))
    await controller.receive(playbackEvent(.onDevice, "channel-b", .playing))
    harness.monotonic.advance(by: 10)
    await controller.setApplicationActive(false)
    harness.monotonic.advance(by: 100)
    await controller.setApplicationActive(true)
    harness.monotonic.advance(by: 5)
    await controller.receive(playbackEvent(.onDevice, "channel-b", .paused))
    harness.monotonic.advance(by: 40)

    await controller.receive(playbackEvent(.onDevice, "channel-b", .stopped))
    await controller.receive(playbackEvent(.remoteCommand, "channel-c", .starting))
    await controller.receive(playbackEvent(.remoteCommand, "channel-c", .playing))
    harness.monotonic.advance(by: 7)
    await controller.receive(playbackEvent(.onDevice, "channel-b", .stopped))
    await controller.receive(playbackEvent(.onDevice, "channel-b", .buffering))
    await controller.receive(playbackEvent(.onDevice, "channel-b", .playing))
    harness.monotonic.advance(by: 3)
    await controller.receive(playbackEvent(.onDevice, "channel-b", .paused))
    await controller.receive(playbackEvent(.remoteCommand, "channel-c", .stopped))
    await controller.drainAvailableSegmentsNow()

    let delivered = await transport.delivered
    let totals = Dictionary(grouping: delivered, by: \.channelId)
        .mapValues { $0.map(\.activeSeconds).reduce(0, +) }
    #expect(totals == ["channel-a": 301, "channel-b": 15, "channel-c": 10])
    #expect(delivered.filter { $0.channelId == "channel-a" }.map(\.activeSeconds) == [60, 60, 60, 60, 60, 1])
}

@Test func mattoneTransportSendsExactDTOAndClassifiesServerOutcomes() async throws {
    let endpoint = try #require(URL(string: "http://127.0.0.1:3000/channel-viewing/segments"))
    let client = ScriptedChannelViewingHTTPClient(
        responses: [
            (200, #"{"status":"recorded"}"#),
            (200, #"{"status":"duplicate"}"#),
            (404, #"{"message":"Channel not found"}"#),
            (503, #"{"message":"Unavailable"}"#),
        ]
    )
    let transport = MattoneChannelViewingTransport(
        endpoint: endpoint,
        deviceID: "LOCAL-OPERATOR-TV",
        client: client
    )
    let segment = makeSegment(
        id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
        channelId: "10000000-0000-4000-8000-000000000001"
    )

    #expect(await transport.deliver(segment) == .recorded)
    #expect(await transport.deliver(segment) == .duplicate)
    #expect(await transport.deliver(segment) == .terminalRejection)
    #expect(await transport.deliver(segment) == .retryableFailure)

    let requests = await client.requests
    #expect(requests.count == 4)
    let request = try #require(requests.first)
    #expect(request.url == endpoint)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "X-Device-ID") == "LOCAL-OPERATOR-TV")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(json.keys) == Set(["segmentId", "channelId", "activeSeconds", "startedAt", "endedAt"]))
    #expect(json["segmentIdId"] == nil)
    #expect(json["segmentId"] as? String == segment.segmentId.uuidString)
    #expect(json["channelId"] as? String == segment.channelId)
    #expect(json["activeSeconds"] as? Int == segment.activeSeconds)
    #expect(json["startedAt"] as? String == "1970-01-01T00:16:40Z")
    #expect(json["endedAt"] as? String == "1970-01-01T00:16:50Z")
}

@Test func retryScheduleIsBoundedAtThirtySeconds() {
    var schedule = ChannelViewingRetrySchedule()
    #expect((0..<8).map { _ in schedule.nextDelaySeconds() } == [1, 2, 4, 8, 16, 30, 30, 30])
    schedule.reset()
    #expect(schedule.nextDelaySeconds() == 1)
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

private actor RecordingChannelViewingTransport: ChannelViewingTransport {
    private(set) var delivered: [ChannelViewingSegment] = []

    func deliver(_ segment: ChannelViewingSegment) async -> ChannelViewingDeliveryOutcome {
        delivered.append(segment)
        return .recorded
    }
}

private actor CancellableFirstChannelViewingTransport: ChannelViewingTransport {
    private(set) var delivered: [ChannelViewingSegment] = []
    private var firstDeliveryStarted = false

    func deliver(_ segment: ChannelViewingSegment) async -> ChannelViewingDeliveryOutcome {
        delivered.append(segment)
        if delivered.count == 1 {
            firstDeliveryStarted = true
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return .retryableFailure
            }
        }
        return .recorded
    }

    func waitUntilFirstDeliveryStarts() async {
        while !firstDeliveryStarted {
            await Task.yield()
        }
    }

}

private actor RetryingChannelViewingTransport: ChannelViewingTransport {
    private(set) var attempts = 0

    func deliver(_ segment: ChannelViewingSegment) async -> ChannelViewingDeliveryOutcome {
        attempts += 1
        return .retryableFailure
    }

    func waitForAttempt() async {
        while attempts == 0 {
            await Task.yield()
        }
    }
}

private actor SuspendedChannelViewingTransport: ChannelViewingTransport {
    private(set) var attempts = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func deliver(_ segment: ChannelViewingSegment) async -> ChannelViewingDeliveryOutcome {
        attempts += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .recorded
    }

    func waitForAttempt() async {
        while attempts == 0 {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ScriptedChannelViewingHTTPClient: ChannelViewingHTTPClient {
    private var responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Int, String)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        return (
            Data(response.1.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.0,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
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

private func playbackEvent(
    _ source: ChannelViewingPlaybackSource,
    _ channelID: String,
    _ state: ChannelViewingPlaybackState
) -> ChannelViewingPlaybackEvent {
    ChannelViewingPlaybackEvent(source: source, channelID: channelID, state: state)
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
