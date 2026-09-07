import Foundation

nonisolated struct ChannelViewingSegment: Codable, Equatable, Sendable {
    let segmentId: UUID
    let channelId: String
    let activeSeconds: Int
    let startedAt: Date
    let endedAt: Date
}

nonisolated enum ChannelPlaybackActivity: Equatable, Sendable {
    case playing(channelId: String)
    case buffering
    case paused
    case inactive
    case failed
    case stopped
    case channelChanged(to: String?)
}

nonisolated enum ChannelViewingDeliveryOutcome: Equatable, Sendable {
    case recorded
    case duplicate
    case retryableFailure
    case terminalRejection
}

nonisolated protocol ChannelViewingTransport: Sendable {
    func deliver(_ segment: ChannelViewingSegment) async -> ChannelViewingDeliveryOutcome
}

nonisolated protocol ChannelViewingOutboxPersistence: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

nonisolated protocol ChannelViewingMonotonicClock: Sendable {
    func now() -> TimeInterval
}

nonisolated protocol ChannelViewingWallClock: Sendable {
    func now() -> Date
}

nonisolated protocol ChannelViewingSegmentIDSource: Sendable {
    func next() -> UUID
}

nonisolated struct SystemChannelViewingMonotonicClock: ChannelViewingMonotonicClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

nonisolated struct SystemChannelViewingWallClock: ChannelViewingWallClock {
    func now() -> Date {
        Date()
    }
}

nonisolated struct RandomChannelViewingSegmentIDSource: ChannelViewingSegmentIDSource {
    func next() -> UUID {
        UUID()
    }
}

nonisolated struct FileChannelViewingOutboxPersistence: ChannelViewingOutboxPersistence {
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

nonisolated struct UserDefaultsChannelViewingOutboxPersistence:
    ChannelViewingOutboxPersistence,
    @unchecked Sendable
{
    let defaults: UserDefaults
    let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "celesti.channel-viewing-outbox"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> Data? {
        defaults.data(forKey: key)
    }

    func save(_ data: Data) throws {
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw ChannelViewingPersistenceError.writeVerificationFailed
        }
    }
}

nonisolated enum ChannelViewingPersistenceError: Error, Equatable {
    case writeVerificationFailed
}

nonisolated enum ChannelViewingOutboxError: Error, Equatable {
    case corruptState
    case unsupportedSchemaVersion(Int)
    case invalidCapacity(Int)
    case invalidSegment(UUID)
    case capacityExceeded(limit: Int)
    case conflictingSegment(UUID)
}

nonisolated enum ChannelViewingAccumulatorError: Error, Equatable {
    case emptyChannelId
    case monotonicClockMovedBackward
}

nonisolated enum ChannelViewingOutboxEntryStatus: String, Codable, Equatable, Sendable {
    case pending
    case retrying
    case terminallyRejected
}

nonisolated struct ChannelViewingOutboxEntry: Codable, Equatable, Sendable {
    let segment: ChannelViewingSegment
    var status: ChannelViewingOutboxEntryStatus
    var deliveryAttempts: Int
}

nonisolated enum ChannelViewingOutboxAttemptResult: Equatable, Sendable {
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

nonisolated protocol ChannelViewingHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

nonisolated struct URLSessionChannelViewingHTTPClient: ChannelViewingHTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

nonisolated struct MattoneChannelViewingTransport: ChannelViewingTransport {
    static let productionEndpoint = URL(
        string: "https://api.celesti.gaulatti.com/channel-viewing/segments"
    )!

    private struct ResponseBody: Decodable {
        let status: String
    }

    let endpoint: URL
    let deviceID: String
    let client: any ChannelViewingHTTPClient

    init(
        endpoint: URL = CelestiAPIConfiguration.endpoint("channel-viewing/segments"),
        deviceID: String,
        client: any ChannelViewingHTTPClient = URLSessionChannelViewingHTTPClient()
    ) {
        self.endpoint = endpoint
        self.deviceID = deviceID
        self.client = client
    }

    func deliver(_ segment: ChannelViewingSegment) async -> ChannelViewingDeliveryOutcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            request.httpBody = try encoder.encode(segment)
            let (data, response) = try await client.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .retryableFailure
            }

            if (200...299).contains(response.statusCode) {
                guard let payload = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
                    return .retryableFailure
                }
                switch payload.status {
                case "recorded": return .recorded
                case "duplicate": return .duplicate
                default: return .retryableFailure
                }
            }

            if response.statusCode == 408
                || response.statusCode == 425
                || response.statusCode == 429
                || (500...599).contains(response.statusCode) {
                return .retryableFailure
            }
            return .terminalRejection
        } catch {
            return .retryableFailure
        }
    }
}

nonisolated enum ChannelViewingPlaybackSource: Equatable, Sendable {
    case onDevice
    case remoteCommand
}

nonisolated enum ChannelViewingPlaybackState: Equatable, Sendable {
    case starting
    case buffering
    case playing
    case paused
    case failed
    case stopped
}

nonisolated struct ChannelViewingPlaybackEvent: Equatable, Sendable {
    let source: ChannelViewingPlaybackSource
    let channelID: String
    let state: ChannelViewingPlaybackState
}

nonisolated enum ChannelViewingDiagnostic: Equatable, Sendable {
    case delivered(ChannelViewingDeliveryOutcome)
    case retryScheduled(attempt: Int, delaySeconds: Int)
    case terminalRejection
    case persistenceFailure
}

nonisolated struct ChannelViewingRetrySchedule: Equatable, Sendable {
    static let maximumDelaySeconds = 30

    private(set) var attempt = 0

    mutating func nextDelaySeconds() -> Int {
        attempt += 1
        return min(1 << min(attempt - 1, 5), Self.maximumDelaySeconds)
    }

    mutating func reset() {
        attempt = 0
    }
}

actor ChannelViewingHistoryController {
    typealias DiagnosticHandler = @Sendable (ChannelViewingDiagnostic) -> Void

    private let accumulator: ActiveChannelViewingAccumulator
    private let outbox: DurableChannelViewingOutbox
    private let transport: any ChannelViewingTransport
    private let diagnosticHandler: DiagnosticHandler
    private let automaticTasks: Bool
    private var applicationIsActive = true
    private var registrationIsAvailable = false
    private var networkIsAvailable = false
    private var currentSource: ChannelViewingPlaybackSource?
    private var latestEvent: ChannelViewingPlaybackEvent?
    private var checkpointTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var drainRequested = false
    private var explicitDrainInProgress = false

    init(
        accumulator: ActiveChannelViewingAccumulator,
        outbox: DurableChannelViewingOutbox,
        transport: any ChannelViewingTransport,
        automaticTasks: Bool = true,
        diagnosticHandler: @escaping DiagnosticHandler = { _ in }
    ) {
        self.accumulator = accumulator
        self.outbox = outbox
        self.transport = transport
        self.automaticTasks = automaticTasks
        self.diagnosticHandler = diagnosticHandler
    }

    func receive(_ event: ChannelViewingPlaybackEvent) async {
        if let currentSource, currentSource != event.source {
            return
        }
        if currentSource == nil {
            guard event.state != .stopped, event.state != .failed else { return }
            currentSource = event.source
        }
        latestEvent = event

        await applyEffectiveActivity()
        if event.state == .stopped, currentSource == event.source {
            currentSource = nil
            latestEvent = nil
        }
    }

    func setApplicationActive(_ isActive: Bool) async {
        guard applicationIsActive != isActive else {
            if isActive { requestDrain() }
            return
        }
        applicationIsActive = isActive
        await applyEffectiveActivity()
        if isActive { requestDrain() }
    }

    func setRegistrationAvailable(_ isAvailable: Bool) {
        registrationIsAvailable = isAvailable
        if isAvailable {
            requestDrain()
        } else {
            deliveryTask?.cancel()
            drainRequested = false
        }
    }

    func setNetworkAvailable(_ isAvailable: Bool) {
        networkIsAvailable = isAvailable
        if isAvailable {
            requestDrain()
        } else {
            deliveryTask?.cancel()
            drainRequested = false
        }
    }

    func checkpointNow() async {
        guard applicationIsActive, latestEvent?.state == .playing else { return }
        do {
            try await accumulator.checkpoint()
            requestDrain()
        } catch {
            checkpointTask?.cancel()
            checkpointTask = nil
            diagnosticHandler(.persistenceFailure)
        }
    }

    func drainAvailableSegmentsNow() async {
        explicitDrainInProgress = true
        defer {
            explicitDrainInProgress = false
            if drainRequested {
                drainRequested = false
                requestDrain()
            }
        }
        while let activeDelivery = deliveryTask {
            drainRequested = false
            activeDelivery.cancel()
            await activeDelivery.value
        }
        await drainAvailableSegments(retries: false, ownsDeliveryTask: false)
    }

    private func applyEffectiveActivity() async {
        let activity: ChannelPlaybackActivity
        if !applicationIsActive {
            activity = .inactive
        } else if let latestEvent {
            switch latestEvent.state {
            case .playing:
                activity = .playing(channelId: latestEvent.channelID)
            case .starting, .buffering:
                activity = .buffering
            case .paused:
                activity = .paused
            case .failed:
                activity = .failed
            case .stopped:
                activity = .stopped
            }
        } else {
            activity = .stopped
        }

        do {
            try await accumulator.transition(to: activity)
            configureCheckpoint(for: activity)
            requestDrain()
        } catch {
            checkpointTask?.cancel()
            checkpointTask = nil
            diagnosticHandler(.persistenceFailure)
        }
    }

    private func configureCheckpoint(for activity: ChannelPlaybackActivity) {
        checkpointTask?.cancel()
        checkpointTask = nil
        guard automaticTasks, case .playing = activity else { return }
        checkpointTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
            await self?.checkpointDeadlineReached()
        }
    }

    private func checkpointDeadlineReached() async {
        checkpointTask = nil
        guard applicationIsActive, latestEvent?.state == .playing else { return }
        await checkpointNow()
        if checkpointTask == nil,
           applicationIsActive,
           latestEvent?.state == .playing {
            configureCheckpoint(for: .playing(channelId: latestEvent?.channelID ?? ""))
        }
    }

    private func requestDrain() {
        guard automaticTasks,
              registrationIsAvailable,
              networkIsAvailable else { return }
        guard !explicitDrainInProgress else {
            drainRequested = true
            return
        }
        guard deliveryTask == nil else {
            drainRequested = true
            return
        }
        drainRequested = false
        deliveryTask = Task { [weak self] in
            await self?.drainAvailableSegments(retries: true, ownsDeliveryTask: true)
        }
    }

    private func drainAvailableSegments(retries: Bool, ownsDeliveryTask: Bool) async {
        var schedule = ChannelViewingRetrySchedule()
        while !Task.isCancelled {
            if retries, (!registrationIsAvailable || !networkIsAvailable) { break }
            let result: ChannelViewingOutboxAttemptResult
            do {
                result = try await outbox.deliverNext(using: transport)
            } catch {
                diagnosticHandler(.persistenceFailure)
                break
            }

            switch result {
            case .empty:
                finishDrain(ownsDeliveryTask: ownsDeliveryTask)
                return
            case let .acknowledged(_, outcome):
                diagnosticHandler(.delivered(outcome))
                schedule.reset()
            case let .retained(_, outcome):
                switch outcome {
                case .terminalRejection:
                    diagnosticHandler(.terminalRejection)
                case .retryableFailure:
                    guard retries else {
                        finishDrain(ownsDeliveryTask: ownsDeliveryTask)
                        return
                    }
                    let delay = schedule.nextDelaySeconds()
                    diagnosticHandler(.retryScheduled(attempt: schedule.attempt, delaySeconds: delay))
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    } catch {
                        finishDrain(ownsDeliveryTask: ownsDeliveryTask)
                        return
                    }
                case .recorded, .duplicate:
                    break
                }
            }
        }
        finishDrain(ownsDeliveryTask: ownsDeliveryTask)
    }

    private func finishDrain(ownsDeliveryTask: Bool) {
        guard ownsDeliveryTask else { return }
        deliveryTask = nil
        guard drainRequested else { return }
        drainRequested = false
        requestDrain()
    }
}
