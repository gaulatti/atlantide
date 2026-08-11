import Foundation
import OSLog

private let telemetryLog = Logger(subsystem: "com.gaulatti.celesti", category: "Telemetry")

enum TelemetryPlatform: String, Encodable {
    case ios
}

enum TelemetryEventType: String, Encodable {
    case playbackStart = "playback_start"
    case playbackStop = "playback_stop"
    case playbackError = "playback_error"
    case playbackFailure = "playback_failure"
    case bufferingStart = "buffering_start"
    case bufferingEnd = "buffering_end"
    case decoderInitialized = "decoder_initialized"
    case bitrateChanged = "bitrate_changed"
}

enum TelemetryDecoderType: String, Encodable {
    case hardware
    case software
    case unknown
}

enum TelemetryLayoutMode: String, Encodable {
    case single
    case quad
    case emergency
}

struct TelemetryEvent: Encodable {
    let deviceCode: String
    let platform: TelemetryPlatform
    let eventType: TelemetryEventType
    let channelId: String?
    let streamName: String?
    let streamUrl: String?
    let quadrant: Int?
    let layoutMode: TelemetryLayoutMode?
    let decoderType: TelemetryDecoderType?
    let decoderName: String?
    let bitrate: Double?
    let errorCode: String?
    let errorReason: String?
    let durationMs: Int?
    let metadata: [String: String]?
}

final class TelemetryReporter {
    static let shared = TelemetryReporter()

    private let baseURL: URL
    private let urlSession: URLSession
    private var isEnabled = true
    private var activeChannelId: String?

    private init() {
        self.baseURL = URL(string: "https://api.celesti.gaulatti.com/telemetry")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.urlSession = URLSession(configuration: config)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func setActiveChannel(_ channelId: String?) {
        activeChannelId = channelId
    }

    func report(
        deviceCode: String,
        eventType: TelemetryEventType,
        streamName: String? = nil,
        streamUrl: String? = nil,
        quadrant: Int? = nil,
        layoutMode: TelemetryLayoutMode? = nil,
        decoderType: TelemetryDecoderType? = nil,
        decoderName: String? = nil,
        bitrate: Double? = nil,
        errorCode: String? = nil,
        errorReason: String? = nil,
        durationMs: Int? = nil,
        metadata: [String: String]? = nil
    ) {
        guard isEnabled else { return }

        let event = TelemetryEvent(
            deviceCode: deviceCode,
            platform: .ios,
            eventType: eventType,
            channelId: activeChannelId,
            streamName: streamName,
            streamUrl: streamUrl,
            quadrant: quadrant,
            layoutMode: layoutMode,
            decoderType: decoderType,
            decoderName: decoderName,
            bitrate: bitrate,
            errorCode: errorCode,
            errorReason: errorReason,
            durationMs: durationMs,
            metadata: metadata
        )

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceCode, forHTTPHeaderField: "X-Device-ID")
        request.setValue("ios", forHTTPHeaderField: "X-Platform")

        do {
            request.httpBody = try JSONEncoder().encode(event)
        } catch {
            telemetryLog.error("Failed to encode telemetry event: \(error, privacy: .public)")
            return
        }

        urlSession.dataTask(with: request) { data, response, error in
            if let error {
                telemetryLog.debug("Telemetry report failed: \(error, privacy: .public)")
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                telemetryLog.debug("Telemetry report returned status \(http.statusCode)")
            }
        }.resume()
    }
}
