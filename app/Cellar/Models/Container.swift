import Foundation

struct Container: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var gameTitle: String
    var profile: Profile = Profile()
    var lastPlayed: Date?
    var playSeconds: Int = 0
    var note: String = ""
}

extension Container {
    static let samples: [Container] = [
        Container(name: "Cave Story", gameTitle: "Cave Story", note: "2D · mục tiêu 60 fps"),
        Container(name: "TrackMania", gameTitle: "TrackMania Nations Forever", note: "DX9 · 720p"),
        Container(name: "Skyrim", gameTitle: "The Elder Scrolls V: Skyrim", note: "DX9 · thử nghiệm")
    ]
}

struct Profile: Codable, Hashable {
    var width: Int = 1280
    var height: Int = 720
    var fpsCap: Int = 60
    var graphics: GraphicsBackend = .dxvk
    var dxvkVersion: String = "2.4"
    var box64Preset: Box64Preset = .compat
    var env: [String: String] = [:]
}

enum GraphicsBackend: String, Codable, CaseIterable, Identifiable {
    case dxvk
    case wined3d
    case vkd3d

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dxvk: return "DXVK (khuyến nghị)"
        case .wined3d: return "WineD3D (fallback)"
        case .vkd3d: return "VKD3D (DirectX 12)"
        }
    }
}

enum Box64Preset: String, Codable, CaseIterable, Identifiable {
    case fast
    case compat
    case safe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "Nhanh (dễ lỗi)"
        case .compat: return "Tương thích (khuyến nghị)"
        case .safe: return "An toàn (chậm)"
        }
    }
}
