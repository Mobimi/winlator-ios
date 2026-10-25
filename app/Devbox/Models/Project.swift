import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var runtime: Runtime = .python
    var note: String = ""
    var lastOpened: Date?
    var env: [String: String] = [:]

    var slug: String {
        let lowered = name.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(allowed).replacingOccurrences(of: "--", with: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "project" : trimmed
    }

    var guestPath: String {
        "/home/dev/projects/\(slug)"
    }
}

extension Project {
    static let samples: [Project] = [
        Project(name: "hello-python", runtime: .python, note: "Python 3.13 · pip · venv"),
        Project(name: "web-app", runtime: .node, note: "Node 22 · npm · Vite"),
        Project(name: "scratch", runtime: .blank, note: "Thư mục trống")
    ]
}

enum Runtime: String, Codable, CaseIterable, Identifiable {
    case python
    case node
    case blank

    var id: String { rawValue }

    var label: String {
        switch self {
        case .python: return "Python 3.13"
        case .node: return "Node.js 22"
        case .blank: return "Trống"
        }
    }

    var shortLabel: String {
        switch self {
        case .python: return "PY"
        case .node: return "NODE"
        case .blank: return "SHELL"
        }
    }

    var icon: String {
        switch self {
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .node: return "hexagon"
        case .blank: return "terminal"
        }
    }

    var summary: String {
        switch self {
        case .python:
            return "python3, pip, venv. Cài được wheel linux-aarch64 (numpy, pandas…)."
        case .node:
            return "node, npm, npx. Chạy được dev server và mở trong Safari."
        case .blank:
            return "Chỉ shell Linux. Tự cài bằng apt/pip/npm."
        }
    }
}
