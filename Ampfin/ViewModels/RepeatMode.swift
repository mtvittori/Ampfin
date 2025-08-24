// Central definition for repeat mode, used by player/view model
import Foundation

public enum RepeatMode: Int, CaseIterable, Codable {
    case off, all, one
    mutating public func toggle() {
        self = RepeatMode(rawValue: (rawValue + 1) % RepeatMode.allCases.count)!
    }
    public var iconName: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
    public var description: String {
        switch self {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }
}
