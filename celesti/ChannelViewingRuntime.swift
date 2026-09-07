@preconcurrency import Network
import Foundation
import OSLog

nonisolated private let channelViewingLog = Logger(
    subsystem: "com.gaulatti.celesti",
    category: "ChannelViewing"
)

@MainActor
final class ChannelViewingRuntime {
    private let controller: ChannelViewingHistoryController
    private let networkObserver: ChannelViewingNetworkObserver
    private var eventTask: Task<Void, Never>?

    init(deviceID: String) throws {
        let persistence = UserDefaultsChannelViewingOutboxPersistence()
        let outbox = try DurableChannelViewingOutbox(persistence: persistence)
        let accumulator = ActiveChannelViewingAccumulator(outbox: outbox)
        let transport = MattoneChannelViewingTransport(deviceID: deviceID)
        let controller = ChannelViewingHistoryController(
            accumulator: accumulator,
            outbox: outbox,
            transport: transport,
            diagnosticHandler: Self.recordDiagnostic
        )
        self.controller = controller
        self.networkObserver = ChannelViewingNetworkObserver(controller: controller)
    }

    func receive(_ event: ChannelViewingPlaybackEvent) {
        enqueue { controller in
            await controller.receive(event)
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        enqueue { controller in
            await controller.setApplicationActive(isActive)
        }
    }

    func registrationBecameAvailable() {
        enqueue { controller in
            await controller.setRegistrationAvailable(true)
        }
    }

    func drainBeforeLibraryRefresh() async {
        await eventTask?.value
        await controller.drainAvailableSegmentsNow()
    }

    private func enqueue(
        _ operation: @escaping @Sendable (ChannelViewingHistoryController) async -> Void
    ) {
        let previous = eventTask
        eventTask = Task { [controller] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation(controller)
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

    init(controller: ChannelViewingHistoryController) {
        monitor.pathUpdateHandler = { path in
            Task {
                await controller.setNetworkAvailable(path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
