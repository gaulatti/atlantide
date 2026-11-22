import Foundation

/// Decides, for one player, when a live stream has gone stale and must be restarted
/// (gaulatti/atlantide#27). It is a pure state machine: the caller samples the player on its
/// own cadence, passes an `Observation`, and acts on the `Decision`. Time comes from an injected
/// clock, so every rule is testable without waiting.
///
/// A stream is stale in one of two ways while the player is meant to be playing:
/// - the clock stopped: the position has not moved for `stallTimeout` seconds;
/// - the picture froze: the clock may still move, but no new video frame arrived for
///   `stallTimeout` seconds. Only a player that reports a frame signal (`hasNewFrame` non-nil)
///   is judged on frames; audio-only streams and decoders without a frame signal are judged on
///   the clock alone.
///
/// A paused player is never restarted. Restarts back off so a dead source never loops tightly:
/// the first restart happens as soon as the stream is stale, and each further restart waits
/// `backoff[n]` seconds after the previous one (5, 15, then 60 s, and every 60 s after that).
/// Because staleness needs `stallTimeout` of silence after each restart, the effective gap
/// between restarts is the larger of that and the backoff step. The streak resets after
/// `healthyResetInterval` seconds of continuous healthy playback.
struct StreamStallWatchdog {
    struct Configuration: Equatable {
        var stallTimeout: TimeInterval = 8
        var backoff: [TimeInterval] = [5, 15, 60]
        var healthyResetInterval: TimeInterval = 120
        /// A position change smaller than this is rounding noise, not progress.
        var positionTolerance: TimeInterval = 0.25
    }

    struct Observation: Equatable {
        /// The player is paused or stopped by the user, or has nothing to play.
        var isPaused: Bool
        /// Current playback position in seconds.
        var position: TimeInterval
        /// Whether a new video frame arrived since the last observation; nil when the player
        /// has no frame signal (audio-only, or a decoder that does not expose one).
        var hasNewFrame: Bool?
    }

    enum Reason: String, Equatable {
        case frozenFrames = "frozen_frames"
        case stoppedClock = "stopped_clock"
    }

    enum Decision: Equatable {
        case none
        /// Release the player and prepare the same URL again. `attempt` counts restarts in the
        /// current streak, starting at 1.
        case restart(attempt: Int, reason: Reason)
    }

    private let configuration: Configuration
    private let clock: () -> TimeInterval

    private var needsBaseline = true
    /// After a restart the stale windows start at the restart itself, not at the next sample.
    private var keepWindowStart = false
    private var lastPosition: TimeInterval = 0
    private var lastAdvanceAt: TimeInterval = 0
    private var lastFrameAt: TimeInterval = 0
    private var lastRestartAt: TimeInterval?
    private var healthySince: TimeInterval?
    private var streak = 0
    private var advancedSinceRestart = false
    private var frameSeenSinceRestart = false

    /// True from a restart until the stream shows life again: the "Reconnecting…" badge.
    private(set) var isReconnecting = false
    /// Restarts this watchdog has issued since it was created, for the log.
    private(set) var totalRestarts = 0

    init(configuration: Configuration = Configuration(), clock: @escaping () -> TimeInterval) {
        self.configuration = configuration
        self.clock = clock
    }

    /// The player was stopped or pointed at a new stream: forget everything about the old one.
    mutating func reset() {
        needsBaseline = true
        keepWindowStart = false
        lastRestartAt = nil
        healthySince = nil
        streak = 0
        isReconnecting = false
        advancedSinceRestart = false
        frameSeenSinceRestart = false
    }

    mutating func evaluate(_ observation: Observation) -> Decision {
        let now = clock()
        if observation.isPaused {
            needsBaseline = true
            keepWindowStart = false
            healthySince = nil
            isReconnecting = false
            return .none
        }
        if needsBaseline {
            lastPosition = observation.position
            if !keepWindowStart {
                lastAdvanceAt = now
                lastFrameAt = now
            }
            keepWindowStart = false
            needsBaseline = false
        }
        let advanced = abs(observation.position - lastPosition) > configuration.positionTolerance
        if advanced {
            lastPosition = observation.position
            lastAdvanceAt = now
            advancedSinceRestart = true
        }
        if observation.hasNewFrame == true {
            lastFrameAt = now
            frameSeenSinceRestart = true
        }

        let clockStalled = now - lastAdvanceAt >= configuration.stallTimeout
        let framesStalled = observation.hasNewFrame != nil && now - lastFrameAt >= configuration.stallTimeout
        guard clockStalled || framesStalled else {
            noteHealthy(now: now, observation: observation)
            return .none
        }

        healthySince = nil
        let gap = streak == 0 ? 0 : configuration.backoff[min(streak - 1, configuration.backoff.count - 1)]
        if let lastRestartAt, now - lastRestartAt < gap {
            return .none
        }
        streak += 1
        totalRestarts += 1
        lastRestartAt = now
        isReconnecting = true
        advancedSinceRestart = false
        frameSeenSinceRestart = false
        lastAdvanceAt = now
        lastFrameAt = now
        keepWindowStart = true
        needsBaseline = true
        return .restart(attempt: streak, reason: clockStalled ? .stoppedClock : .frozenFrames)
    }

    private mutating func noteHealthy(now: TimeInterval, observation: Observation) {
        // After a restart the baseline is fresh, so "not stalled" proves nothing yet: wait for
        // a position change and, where there is a frame signal, a new frame.
        if isReconnecting {
            guard advancedSinceRestart && (observation.hasNewFrame == nil || frameSeenSinceRestart) else { return }
            isReconnecting = false
        }
        let since = healthySince ?? now
        healthySince = since
        if now - since >= configuration.healthyResetInterval {
            streak = 0
            lastRestartAt = nil
        }
    }
}
