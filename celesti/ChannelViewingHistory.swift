import Foundation

struct ChannelViewingSegment: Codable, Equatable, Sendable {
    let segmentId: UUID
    let channelId: String
    let activeSeconds: Int
    let startedAt: Date
    let endedAt: Date
}

enum ChannelPlaybackActivity: Equatable, Sendable {
    case playing(channelId: String)
    case buffering
    case paused
    case inactive
    case failed
    case stopped
    case channelChanged(to: String?)
}

enum ChannelViewingDeliveryOutcome: Equatable, Sendable {
    case recorded
    case duplicate
    case retryableFailure
    case terminalRejection
}

protocol ChannelViewingTransport: Sendable {
    func deliver(_ segment: ChannelViewingSegment) async -> ChannelViewingDeliveryOutcome
}

protocol ChannelViewingOutboxPersistence: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

protocol ChannelViewingMonotonicClock: Sendable {
    func now() -> TimeInterval
}

protocol ChannelViewingWallClock: Sendable {
    func now() -> Date
}

protocol ChannelViewingSegmentIDSource: Sendable {
    func next() -> UUID
}

struct SystemChannelViewingMonotonicClock: ChannelViewingMonotonicClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

struct SystemChannelViewingWallClock: ChannelViewingWallClock {
    func now() -> Date {
        Date()
    }
}

struct RandomChannelViewingSegmentIDSource: ChannelViewingSegmentIDSource {
    func next() -> UUID {
        UUID()
    }
}

struct FileChannelViewingOutboxPersistence: ChannelViewingOutboxPersistence {
    let fileURL: URL

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func save(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

enum ChannelViewingOutboxError: Error, Equatable {
    case corruptState
    case unsupportedSchemaVersion(Int)
    case invalidCapacity(Int)
    case invalidSegment(UUID)
    case capacityExceeded(limit: Int)
    case conflictingSegment(UUID)
}

enum ChannelViewingAccumulatorError: Error, Equatable {
    case emptyChannelId
    case monotonicClockMovedBackward
}

enum ChannelViewingOutboxEntryStatus: String, Codable, Equatable, Sendable {
    case pending
    case retrying
    case terminallyRejected
}

struct ChannelViewingOutboxEntry: Codable, Equatable, Sendable {
    let segment: ChannelViewingSegment
    var status: ChannelViewingOutboxEntryStatus
    var deliveryAttempts: Int
}

enum ChannelViewingOutboxAttemptResult: Equatable, Sendable {
    case empty
    case acknowledged(segmentId: UUID, outcome: ChannelViewingDeliveryOutcome)
    case retained(segmentId: UUID, outcome: ChannelViewingDeliveryOutcome)
}

actor DurableChannelViewingOutbox {
    private struct PersistedState: Codable {
        let schemaVersion: Int
        var entries: [ChannelViewingOutboxEntry]
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    static let currentSchemaVersion = 1

    private let persistence: any ChannelViewingOutboxPersistence
    private let maximumSegments: Int
    private let encoder: JSONEncoder
    private var entries: [ChannelViewingOutboxEntry]
    private var inFlightSegmentIds: Set<UUID> = []

    init(
        persistence: any ChannelViewingOutboxPersistence,
        maximumSegments: Int = 1_000
    ) throws {
        guard maximumSegments > 0 else {
            throw ChannelViewingOutboxError.invalidCapacity(maximumSegments)
        }
        self.persistence = persistence
        self.maximumSegments = maximumSegments

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        guard let data = try persistence.load() else {
            entries = []
            return
        }

        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            throw ChannelViewingOutboxError.corruptState
        }
        guard probe.schemaVersion == Self.currentSchemaVersion else {
            throw ChannelViewingOutboxError.unsupportedSchemaVersion(probe.schemaVersion)
        }
        guard let state = try? decoder.decode(PersistedState.self, from: data) else {
            throw ChannelViewingOutboxError.corruptState
        }
        guard Self.isValid(entries: state.entries, maximumSegments: maximumSegments) else {
            throw ChannelViewingOutboxError.corruptState
        }
        entries = state.entries
    }

    var count: Int {
        entries.count
    }

    var snapshot: [ChannelViewingOutboxEntry] {
        entries
    }

    @discardableResult
    func enqueue(_ segment: ChannelViewingSegment) throws -> Bool {
        try enqueue([segment]) > 0
    }

    @discardableResult
    func enqueue(_ segments: [ChannelViewingSegment]) throws -> Int {
        var additions: [ChannelViewingOutboxEntry] = []

        for segment in segments {
            guard Self.isValid(segment: segment) else {
                throw ChannelViewingOutboxError.invalidSegment(segment.segmentId)
            }
            if let existing = entries.first(where: { $0.segment.segmentId == segment.segmentId })?.segment
                ?? additions.first(where: { $0.segment.segmentId == segment.segmentId })?.segment {
                guard existing == segment else {
                    throw ChannelViewingOutboxError.conflictingSegment(segment.segmentId)
                }
                continue
            }
            additions.append(
                ChannelViewingOutboxEntry(
                    segment: segment,
                    status: .pending,
                    deliveryAttempts: 0
                )
            )
        }

        guard entries.count + additions.count <= maximumSegments else {
            throw ChannelViewingOutboxError.capacityExceeded(limit: maximumSegments)
        }
        guard !additions.isEmpty else { return 0 }

        let previousEntries = entries
        entries.append(contentsOf: additions)
        do {
            try persist()
        } catch {
            entries = previousEntries
            throw error
        }
        return additions.count
    }

    func deliverNext(
        using transport: any ChannelViewingTransport
    ) async throws -> ChannelViewingOutboxAttemptResult {
        guard let entry = entries.first(where: {
            $0.status != .terminallyRejected && !inFlightSegmentIds.contains($0.segment.segmentId)
        }) else {
            return .empty
        }

        let segmentId = entry.segment.segmentId
        inFlightSegmentIds.insert(segmentId)
        let outcome = await transport.deliver(entry.segment)
        inFlightSegmentIds.remove(segmentId)

        guard let index = entries.firstIndex(where: { $0.segment.segmentId == segmentId }) else {
            return .empty
        }

        let previousEntries = entries
        let result: ChannelViewingOutboxAttemptResult
        switch outcome {
        case .recorded, .duplicate:
            entries.remove(at: index)
            result = .acknowledged(segmentId: segmentId, outcome: outcome)
        case .retryableFailure:
            entries[index].status = .retrying
            entries[index].deliveryAttempts += 1
            result = .retained(segmentId: segmentId, outcome: outcome)
        case .terminalRejection:
            entries[index].status = .terminallyRejected
            entries[index].deliveryAttempts += 1
            result = .retained(segmentId: segmentId, outcome: outcome)
        }

        do {
            try persist()
        } catch {
            entries = previousEntries
            throw error
        }
        return result
    }

    private func persist() throws {
        let state = PersistedState(
            schemaVersion: Self.currentSchemaVersion,
            entries: entries
        )
        try persistence.save(try encoder.encode(state))
    }

    private static func isValid(
        entries: [ChannelViewingOutboxEntry],
        maximumSegments: Int
    ) -> Bool {
        guard entries.count <= maximumSegments else { return false }
        var segmentIds: Set<UUID> = []
        for entry in entries {
            guard isValid(segment: entry.segment),
                  entry.deliveryAttempts >= 0,
                  segmentIds.insert(entry.segment.segmentId).inserted else {
                return false
            }
        }
        return true
    }

    private static func isValid(segment: ChannelViewingSegment) -> Bool {
        let duration = segment.endedAt.timeIntervalSince(segment.startedAt)
        return !segment.channelId.isEmpty
            && (1...ActiveChannelViewingAccumulator.maximumSegmentSeconds).contains(segment.activeSeconds)
            && abs(duration - TimeInterval(segment.activeSeconds)) < 0.000_001
    }
}

actor ActiveChannelViewingAccumulator {
    static let maximumSegmentSeconds = 60

    private struct ActiveInterval {
        let channelId: String
        let monotonicStartedAt: TimeInterval
        let wallStartedAt: Date
        var persistedWholeSeconds: Int
        var monotonicEndedAt: TimeInterval?
    }

    private struct PendingBatch {
        let segments: [ChannelViewingSegment]
        let persistedWholeSeconds: Int
        let closesInterval: Bool
    }

    private let outbox: DurableChannelViewingOutbox
    private let monotonicClock: any ChannelViewingMonotonicClock
    private let wallClock: any ChannelViewingWallClock
    private let segmentIDSource: any ChannelViewingSegmentIDSource
    private var activeInterval: ActiveInterval?
    private var pendingBatch: PendingBatch?

    init(
        outbox: DurableChannelViewingOutbox,
        monotonicClock: any ChannelViewingMonotonicClock = SystemChannelViewingMonotonicClock(),
        wallClock: any ChannelViewingWallClock = SystemChannelViewingWallClock(),
        segmentIDSource: any ChannelViewingSegmentIDSource = RandomChannelViewingSegmentIDSource()
    ) {
        self.outbox = outbox
        self.monotonicClock = monotonicClock
        self.wallClock = wallClock
        self.segmentIDSource = segmentIDSource
    }

    func transition(to activity: ChannelPlaybackActivity) async throws {
        try await persistPendingBatch()
        let monotonicNow = monotonicClock.now()

        switch activity {
        case let .playing(channelId):
            guard !channelId.isEmpty else {
                throw ChannelViewingAccumulatorError.emptyChannelId
            }

            guard let activeInterval else {
                start(channelId: channelId, monotonicNow: monotonicNow)
                return
            }

            if activeInterval.channelId == channelId {
                try await checkpoint(at: monotonicNow)
            } else {
                try await stop(at: monotonicNow)
                start(channelId: channelId, monotonicNow: monotonicNow)
            }

        case .buffering, .paused, .inactive, .failed, .stopped, .channelChanged:
            try await stop(at: monotonicNow)
        }
    }

    func checkpoint() async throws {
        try await persistPendingBatch()
        try await checkpoint(at: monotonicClock.now())
    }

    func unpersistedActiveSeconds() throws -> TimeInterval {
        guard let activeInterval else { return 0 }
        let elapsed = (activeInterval.monotonicEndedAt ?? monotonicClock.now())
            - activeInterval.monotonicStartedAt
        guard elapsed >= 0 else {
            throw ChannelViewingAccumulatorError.monotonicClockMovedBackward
        }
        return elapsed - TimeInterval(activeInterval.persistedWholeSeconds)
    }

    private func start(channelId: String, monotonicNow: TimeInterval) {
        activeInterval = ActiveInterval(
            channelId: channelId,
            monotonicStartedAt: monotonicNow,
            wallStartedAt: wallClock.now(),
            persistedWholeSeconds: 0,
            monotonicEndedAt: nil
        )
    }

    private func checkpoint(at monotonicNow: TimeInterval) async throws {
        guard let activeInterval else { return }
        let elapsedWholeSeconds = try wholeSecondsElapsed(
            since: activeInterval.monotonicStartedAt,
            now: monotonicNow
        )
        let checkpointedSeconds =
            (elapsedWholeSeconds / Self.maximumSegmentSeconds) * Self.maximumSegmentSeconds
        try await persistSegments(through: checkpointedSeconds)
    }

    private func stop(at monotonicNow: TimeInterval) async throws {
        guard let activeInterval else { return }
        if activeInterval.monotonicEndedAt == nil {
            self.activeInterval?.monotonicEndedAt = monotonicNow
        }
        let endedAt = self.activeInterval?.monotonicEndedAt ?? monotonicNow
        let elapsedWholeSeconds = try wholeSecondsElapsed(
            since: activeInterval.monotonicStartedAt,
            now: endedAt
        )
        try await persistSegments(through: elapsedWholeSeconds, closesInterval: true)
    }

    private func persistSegments(
        through targetWholeSeconds: Int,
        closesInterval: Bool = false
    ) async throws {
        guard let activeInterval,
              targetWholeSeconds > activeInterval.persistedWholeSeconds else {
            if closesInterval {
                self.activeInterval = nil
            }
            return
        }

        var segments: [ChannelViewingSegment] = []
        var offset = activeInterval.persistedWholeSeconds
        while offset < targetWholeSeconds {
            let seconds = min(Self.maximumSegmentSeconds, targetWholeSeconds - offset)
            segments.append(
                ChannelViewingSegment(
                    segmentId: segmentIDSource.next(),
                    channelId: activeInterval.channelId,
                    activeSeconds: seconds,
                    startedAt: activeInterval.wallStartedAt.addingTimeInterval(TimeInterval(offset)),
                    endedAt: activeInterval.wallStartedAt.addingTimeInterval(TimeInterval(offset + seconds))
                )
            )
            offset += seconds
        }

        pendingBatch = PendingBatch(
            segments: segments,
            persistedWholeSeconds: targetWholeSeconds,
            closesInterval: closesInterval
        )
        try await persistPendingBatch()
    }

    private func persistPendingBatch() async throws {
        guard let pendingBatch else { return }
        try await outbox.enqueue(pendingBatch.segments)
        if pendingBatch.closesInterval {
            activeInterval = nil
        } else {
            activeInterval?.persistedWholeSeconds = pendingBatch.persistedWholeSeconds
        }
        self.pendingBatch = nil
    }

    private func wholeSecondsElapsed(since start: TimeInterval, now: TimeInterval) throws -> Int {
        guard now >= start else {
            throw ChannelViewingAccumulatorError.monotonicClockMovedBackward
        }
        return Int((now - start).rounded(.down))
    }
}
