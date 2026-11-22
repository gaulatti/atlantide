import Foundation
import Testing
@testable import AtlantideResilience

private final class FakeClock {
    var now: TimeInterval = 1_000
}

private typealias Watchdog = StreamStallWatchdog
private typealias Observation = StreamStallWatchdog.Observation

private func makeWatchdog(_ clock: FakeClock) -> Watchdog {
    Watchdog(clock: { clock.now })
}

/// Feeds one observation per second for `seconds` and returns every restart as (seconds from start, decision).
private func run(
    _ watchdog: inout Watchdog,
    clock: FakeClock,
    seconds: Int,
    observation: (Int) -> Observation
) -> [(at: Int, decision: Watchdog.Decision)] {
    var restarts: [(at: Int, decision: Watchdog.Decision)] = []
    for second in 0...seconds {
        let decision = watchdog.evaluate(observation(second))
        if decision != .none { restarts.append((second, decision)) }
        clock.now += 1
    }
    return restarts
}

@Test func frozenFramesWithAnAdvancingClockRestartAfterTheTimeout() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    let restarts = run(&watchdog, clock: clock, seconds: 12) {
        Observation(isPaused: false, position: Double($0), hasNewFrame: false)
    }
    #expect(restarts.map(\.at) == [8])
    #expect(restarts.first?.decision == .restart(attempt: 1, reason: .frozenFrames))
    #expect(watchdog.isReconnecting)
    #expect(watchdog.totalRestarts == 1)
}

@Test func aStoppedClockRestartsEvenWithoutAFrameSignal() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    let restarts = run(&watchdog, clock: clock, seconds: 10) {
        Observation(isPaused: false, position: $0 < 3 ? Double($0) : 2, hasNewFrame: nil)
    }
    #expect(restarts.map(\.at) == [10])
    #expect(restarts.first?.decision == .restart(attempt: 1, reason: .stoppedClock))
}

@Test func aStoppedClockWithStaleFramesReportsTheClock() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    let restarts = run(&watchdog, clock: clock, seconds: 8) { _ in
        Observation(isPaused: false, position: 5, hasNewFrame: false)
    }
    #expect(restarts.first?.decision == .restart(attempt: 1, reason: .stoppedClock))
}

@Test func aHealthyStreamIsNeverRestarted() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    let restarts = run(&watchdog, clock: clock, seconds: 600) {
        Observation(isPaused: false, position: Double($0), hasNewFrame: true)
    }
    #expect(restarts.isEmpty)
    #expect(!watchdog.isReconnecting)
}

@Test func anAudioOnlyStreamIsJudgedOnTheClockAlone() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    let restarts = run(&watchdog, clock: clock, seconds: 60) {
        Observation(isPaused: false, position: Double($0), hasNewFrame: nil)
    }
    #expect(restarts.isEmpty)
}

@Test func aPausedPlayerIsNeverRestartedAndResumesWithAFreshWindow() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    let paused = run(&watchdog, clock: clock, seconds: 300) { _ in
        Observation(isPaused: true, position: 4, hasNewFrame: false)
    }
    #expect(paused.isEmpty)
    #expect(!watchdog.isReconnecting)

    // Resuming does not count the time spent paused against the stream.
    let resumed = run(&watchdog, clock: clock, seconds: 7) { _ in
        Observation(isPaused: false, position: 4, hasNewFrame: false)
    }
    #expect(resumed.isEmpty)
}

@Test func pausingWhileReconnectingClearsTheBadge() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    _ = run(&watchdog, clock: clock, seconds: 8) { _ in
        Observation(isPaused: false, position: 1, hasNewFrame: false)
    }
    #expect(watchdog.isReconnecting)
    #expect(watchdog.evaluate(Observation(isPaused: true, position: 1, hasNewFrame: false)) == .none)
    #expect(!watchdog.isReconnecting)
}

@Test func aDeadSourceBacksOffFiveFifteenThenEverySixtySeconds() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    let restarts = run(&watchdog, clock: clock, seconds: 400) { _ in
        Observation(isPaused: false, position: 0, hasNewFrame: false)
    }
    // First at the 8 s timeout, then each waits for the later of the timeout and the backoff step:
    // +8 (5 s step), +15, +60, +60 ...
    #expect(restarts.map(\.at) == [8, 16, 31, 91, 151, 211, 271, 331, 391])
    #expect(restarts.map(\.decision) == (1...9).map { .restart(attempt: $0, reason: .stoppedClock) })
}

@Test func aRestartThatRecoversClearsTheBadgeOnlyOnPositiveEvidence() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    _ = run(&watchdog, clock: clock, seconds: 8) { _ in
        Observation(isPaused: false, position: 3, hasNewFrame: false)
    }
    #expect(watchdog.isReconnecting)

    // Not yet stale again, but nothing has moved: still reconnecting.
    clock.now += 1
    #expect(watchdog.evaluate(Observation(isPaused: false, position: 0, hasNewFrame: false)) == .none)
    #expect(watchdog.isReconnecting)

    // The clock moves but no frame yet: still reconnecting.
    clock.now += 1
    #expect(watchdog.evaluate(Observation(isPaused: false, position: 1, hasNewFrame: false)) == .none)
    #expect(watchdog.isReconnecting)

    // A frame arrives: recovered.
    clock.now += 1
    #expect(watchdog.evaluate(Observation(isPaused: false, position: 2, hasNewFrame: true)) == .none)
    #expect(!watchdog.isReconnecting)
}

@Test func withoutAFrameSignalTheClockMovingEndsReconnecting() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    _ = run(&watchdog, clock: clock, seconds: 8) { _ in
        Observation(isPaused: false, position: 3, hasNewFrame: nil)
    }
    #expect(watchdog.isReconnecting)
    clock.now += 1
    _ = watchdog.evaluate(Observation(isPaused: false, position: 0, hasNewFrame: nil))
    clock.now += 1
    _ = watchdog.evaluate(Observation(isPaused: false, position: 1, hasNewFrame: nil))
    #expect(!watchdog.isReconnecting)
}

@Test func twoMinutesOfHealthyPlaybackResetsTheBackoff() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    let first = run(&watchdog, clock: clock, seconds: 17) { _ in
        Observation(isPaused: false, position: 0, hasNewFrame: false)
    }
    #expect(first.count == 2)

    var position = 100.0
    func playHealthy(seconds: Int) {
        for _ in 0..<seconds {
            position += 1
            _ = watchdog.evaluate(Observation(isPaused: false, position: position, hasNewFrame: true))
            clock.now += 1
        }
    }
    func freezePictureOnly(seconds: Int) -> [(at: Int, decision: StreamStallWatchdog.Decision)] {
        var restarts: [(at: Int, decision: StreamStallWatchdog.Decision)] = []
        for second in 0...seconds {
            position += 1
            let decision = watchdog.evaluate(Observation(isPaused: false, position: position, hasNewFrame: false))
            if decision != .none { restarts.append((second, decision)) }
            clock.now += 1
        }
        return restarts
    }

    // 100 s healthy is not enough: the next stall continues the streak.
    playHealthy(seconds: 100)
    #expect(freezePictureOnly(seconds: 8).first?.decision == .restart(attempt: 3, reason: .frozenFrames))

    // A full two minutes healthy forgets it.
    playHealthy(seconds: 125)
    #expect(freezePictureOnly(seconds: 8).first?.decision == .restart(attempt: 1, reason: .frozenFrames))
}

@Test func positionJitterBelowTheToleranceIsNotProgress() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    let restarts = run(&watchdog, clock: clock, seconds: 9) {
        Observation(isPaused: false, position: 10 + Double($0 % 2) * 0.1, hasNewFrame: nil)
    }
    #expect(restarts.map(\.at) == [8])
}

@Test func resetForgetsTheOldStream() {
    let clock = FakeClock()
    var watchdog = makeWatchdog(clock)
    _ = run(&watchdog, clock: clock, seconds: 8) { _ in
        Observation(isPaused: false, position: 1, hasNewFrame: false)
    }
    #expect(watchdog.isReconnecting)
    watchdog.reset()
    #expect(!watchdog.isReconnecting)
    let restarts = run(&watchdog, clock: clock, seconds: 8) { _ in
        Observation(isPaused: false, position: 1, hasNewFrame: false)
    }
    #expect(restarts.first?.decision == .restart(attempt: 1, reason: .stoppedClock))
}

@Test func eachQuadPlayerIsJudgedAlone() {
    let clock = FakeClock()
    var players = (0..<4).map { _ in makeWatchdog(clock) }
    var restarted: [Int] = []
    for second in 0...12 {
        for index in players.indices {
            let frozen = index == 2
            let decision = players[index].evaluate(
                Observation(isPaused: false, position: Double(second), hasNewFrame: !frozen)
            )
            if decision != .none { restarted.append(index) }
        }
        clock.now += 1
    }
    #expect(restarted == [2])
    #expect(players.map(\.isReconnecting) == [false, false, true, false])
}
