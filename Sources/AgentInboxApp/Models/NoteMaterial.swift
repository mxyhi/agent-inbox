import Foundation

/// How a note's background is rendered.
enum NoteMaterial: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid
    case glass
    case transparent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solid:       return String(localized: "Solid")
        case .glass:       return String(localized: "Glass")
        case .transparent: return String(localized: "Transparent")
        }
    }
}
