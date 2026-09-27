@preconcurrency import Network
import Foundation
import OSLog

nonisolated private let channelViewingLog = Logger(
    subsystem: "com.gaulatti.celesti",
    category: "ChannelViewing"
)

@MainActor
final class ChannelViewingRuntime {
    private let controllers: [String: ChannelViewingHistoryController]
    private let networkObserver: ChannelViewingNetworkObserver
    private var eventTask: Task<Void, Never>?
    private var aggregator = ChannelViewingSlotAggregator()
    private var channelOwners: [String: String] = [:]
    private var singleSource: ChannelViewingPlaybackSource?

    init(deviceID: String) throws {
        let persistence = UserDefaultsChannelViewingOutboxPersistence()
        let outbox = try DurableChannelViewingOutbox(persistence: persistence)
        let transport = MattoneChannelViewingTransport(deviceID: deviceID)
        var controllers: [String: ChannelViewingHistoryController] = [:]
        for key in ["single"] + (0..<4).map({ "quad:\($0)" })
            + (0..<8).map({ "emergency:\($0)" }) {
            controllers[key] = ChannelViewingHistoryController(
                accumulator: ActiveChannelViewingAccumulator(outbox: outbox),
                outbox: outbox,
                transport: transport,
                diagnosticHandler: Self.recordDiagnostic
            )
        }
        self.controllers = controllers
        self.networkObserver = ChannelViewingNetworkObserver(controllers: Array(controllers.values))
    }

    func receive(_ event: ChannelViewingPlaybackEvent) {
        receive(event, key: "single")
    }

    func receiveQuad(_ event: ChannelViewingPlaybackEvent, quadrant: Int) {
        receive(event, key: "quad:\(quadrant)")
    }

    func receiveEmergency(_ event: ChannelViewingPlaybackEvent, slot: Int) {
        receive(event, key: "emergency:\(slot)")
    }

    private func receive(_ event: ChannelViewingPlaybackEvent, key: String) {
        guard controllers[key] != nil else { return }
        if key == "single" {
            if let singleSource, singleSource != event.source { return }
            if singleSource == nil {
                guard event.state != .stopped, event.state != .failed else { return }
                singleSource = event.source
            }
        }

        if key == "single" && (event.state == .stopped || event.state == .failed) {
            singleSource = nil
        }
        for change in aggregator.receive(event, slot: key) {
            let channelID = change.channelID
            let state = change.state
            let owner: String
            if let existing = channelOwners[channelID] {
                owner = existing
            } else {
                guard let available = controllers.keys.sorted().first(where: {
                    !channelOwners.values.contains($0)
                }) else { continue }
                channelOwners[channelID] = available
                owner = available
            }
            guard let controller = controllers[owner] else { continue }
            enqueue {
                await controller.receive(ChannelViewingPlaybackEvent(
                    source: .remoteCommand,
                    channelID: channelID,
                    state: state
                ))
            }
            if state == .stopped { channelOwners.removeValue(forKey: channelID) }
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        enqueue { [controllers] in
            for controller in controllers.values {
                await controller.setApplicationActive(isActive)
            }
        }
    }

    func registrationBecameAvailable() {
        enqueue { [controllers] in
            for controller in controllers.values {
                await controller.setRegistrationAvailable(true)
            }
        }
    }

    func drainBeforeLibraryRefresh() async {
        await eventTask?.value
        for controller in controllers.values {
            await controller.drainAvailableSegmentsNow()
        }
    }

    private func enqueue(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        let previous = eventTask
        eventTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    nonisolated private static func recordDiagnostic(_ diagnostic: ChannelViewingDiagnostic) {
        switch diagnostic {
        case .delivered(.recorded):
            channelViewingLog.info("event=delivery result=recorded")
        case .delivered(.duplicate):
            channelViewingLog.info("event=delivery result=duplicate")
        case .delivered:
            channelViewingLog.error("event=delivery result=invalid_terminal_state")
        case let .retryScheduled(attempt, delaySeconds):
            channelViewingLog.notice(
                "event=delivery result=retry attempt=\(attempt) delaySeconds=\(delaySeconds)"
            )
        case .terminalRejection:
            channelViewingLog.error("event=delivery result=terminal_rejection")
        case .persistenceFailure:
            channelViewingLog.fault("event=persistence result=failed")
        }
    }
}

private final class ChannelViewingNetworkObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.gaulatti.celesti.channel-viewing-network")

    init(controllers: [ChannelViewingHistoryController]) {
        monitor.pathUpdateHandler = { path in
            Task {
                for controller in controllers {
                    await controller.setNetworkAvailable(path.status == .satisfied)
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
