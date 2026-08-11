import Foundation

enum Quadrant: Int, CaseIterable, Identifiable {
    case topLeft = 0
    case topRight = 1
    case bottomLeft = 2
    case bottomRight = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var row: Int { rawValue / 2 }
    var column: Int { rawValue % 2 }

    static func from(_ value: Int?) -> Quadrant? {
        guard let value else { return nil }
        return Quadrant(rawValue: value)
    }
}

enum LayoutMode: String {
    case single
    case quad
    case emergency

    static func from(_ value: String?) -> LayoutMode {
        guard let value = value?.lowercased() else { return .single }
        if value == "quad" || value == "quadrant" { return .quad }
        if value == "emergency" { return .emergency }
        return .single
    }
}
