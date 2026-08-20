import Foundation

enum TelemetryLayoutMode: String, Encodable {
    case single
    case quad
    case emergency
}

struct PlaybackBufferProfile: Equatable {
    let preferredForwardDuration: TimeInterval
    let maximumDuration: TimeInterval
    let physicalMemoryMB: UInt64
    let lowMemory: Bool
}

enum PlaybackBufferPolicy {
    static func profile(
        for layoutMode: TelemetryLayoutMode,
        physicalMemoryMB: UInt64 = ProcessInfo.processInfo.physicalMemory / UInt64(1_024 * 1_024)
    ) -> PlaybackBufferProfile {
        let lowMemory = physicalMemoryMB <= 2_048
        let durations: (TimeInterval, TimeInterval)

        switch (layoutMode, lowMemory) {
        case (.emergency, true): durations = (6, 12)
        case (.emergency, false): durations = (8, 18)
        case (.quad, true): durations = (8, 18)
        case (.quad, false): durations = (12, 25)
        case (.single, true): durations = (15, 30)
        case (.single, false): durations = (20, 45)
        }

        return PlaybackBufferProfile(
            preferredForwardDuration: durations.0,
            maximumDuration: durations.1,
            physicalMemoryMB: physicalMemoryMB,
            lowMemory: lowMemory
        )
    }
}

enum PlaybackRecoveryPolicy {
    static let freezeTimeout: TimeInterval = 8
    static let recoveryWindow: TimeInterval = 90
    static let stableResetInterval: TimeInterval = 60
    static let routineHealthInterval: TimeInterval = 30

    static func isFrozen(
        claimsToBePlaying: Bool,
        lastPositionAdvancedAt: Date,
        now: Date
    ) -> Bool {
        claimsToBePlaying && now.timeIntervalSince(lastPositionAdvancedAt) >= freezeTimeout
    }

    static func recoveriesWithinWindow(_ recoveries: [Date], now: Date) -> [Date] {
        recoveries.filter { now.timeIntervalSince($0) <= recoveryWindow }
    }

    static func shouldEnterOfflineProbe(after recoveries: [Date], now: Date) -> Bool {
        recoveriesWithinWindow(recoveries, now: now).count >= 3
    }

    static func probeDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 30 }
        let exponent = min(attempt - 1, 4)
        return min(300, 30 * pow(2, Double(exponent)))
    }

    static func shouldResetCircuit(
        claimsToBePlaying: Bool,
        stablePlaybackStartedAt: Date?,
        now: Date
    ) -> Bool {
        guard claimsToBePlaying, let stablePlaybackStartedAt else { return false }
        return now.timeIntervalSince(stablePlaybackStartedAt) >= stableResetInterval
    }

    static func shouldEmitRoutineHealth(lastEmittedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastEmittedAt) >= routineHealthInterval
    }
}

enum EmergencyCarouselPolicy {
    static func healthySlots(assignedSlots: [Int], offlineSlots: Set<Int>) -> [Int] {
        assignedSlots.filter { !offlineSlots.contains($0) }
    }

    static func visibleSlots(
        assignedSlots: [Int],
        offlineSlots: Set<Int>,
        windowStartSlot: Int?
    ) -> [Int?] {
        let healthy = healthySlots(assignedSlots: assignedSlots, offlineSlots: offlineSlots)
        guard !healthy.isEmpty else { return [nil, nil] }
        let startIndex = healthy.firstIndex(of: windowStartSlot ?? healthy[0]) ?? 0
        return [
            healthy[startIndex],
            healthy.count > 1 ? healthy[(startIndex + 1) % healthy.count] : nil,
        ]
    }
}

enum TelemetryPrivacy {
    private static let maximumIdentityLength = 128
    private static let maximumMetadataEntries = 16
    private static let maximumMetadataKeyLength = 64
    private static let maximumMetadataValueLength = 256

    static func sanitizedStreamURL(_ rawValue: String?) -> String? {
        guard let rawValue,
              var components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }

    static func boundedIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        return String(value.prefix(maximumIdentityLength))
    }

    static func boundedMetadata(_ metadata: [String: String]?) -> [String: String]? {
        guard let metadata else { return nil }
        let entries = metadata
            .sorted { $0.key < $1.key }
            .prefix(maximumMetadataEntries)
            .map {
                (
                    String($0.key.prefix(maximumMetadataKeyLength)),
                    String($0.value.prefix(maximumMetadataValueLength))
                )
            }
        return entries.reduce(into: [:]) { bounded, entry in
            bounded[entry.0] = entry.1
        }
    }
}
