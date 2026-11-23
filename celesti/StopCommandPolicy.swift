import Foundation

/// Where a remote `stop` command applies, given the layout the device is in.
///
/// Matches the Android TV client and Mattone's senders (gaulatti/atlantide#31):
/// a stop that names an emergency position applies to it only in emergency, a
/// stop that names a quadrant applies to it only in quad, and a stop that names
/// a quadrant while the device is in any other layout changes nothing. Mattone
/// sends `stop` with a quadrant before every quad `play` and from "stop this
/// quadrant", so it must never tear down a stream that is not in a quadrant.
enum StopCommandRoute: Equatable {
    case emergencySlot(Int)
    case quadrant(Int)
    case ignored
    case everything
}

enum StopCommandPolicy {
    static let quadrants = 0..<4
    static let emergencySlots = 0..<8

    static func route(position: Int?, layout: TelemetryLayoutMode) -> StopCommandRoute {
        guard let position else { return .everything }
        if layout == .emergency, emergencySlots.contains(position) { return .emergencySlot(position) }
        if quadrants.contains(position) { return layout == .quad ? .quadrant(position) : .ignored }
        return .everything
    }
}
