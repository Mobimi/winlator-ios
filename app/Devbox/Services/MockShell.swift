import Foundation
import Combine

enum LineRole {
    case command
    case output
    case error
    case success
    case info
}

struct ShellLine: Identifiable {
    let id = UUID()
    var text: String
    var role: LineRole
}

/// Shell giả lập để hoàn thiện UI trước khi nối QEMU (M1).
/// Mọi lệnh dưới đây chỉ in ra kết quả mẫu, không chạy gì thật.
final class MockShell: ObservableObject {
    @Published private(set) var lines: [ShellLine] = []
    @Published private(set) var cwd: String = "~"

    private var project: Project?

    var prompt: String {
        "dev@iphone:\(cwd)$"
    }

    func boot(project: Project) {
        self.project = project
        cwd = "~"
        lines = []

        append("Devbox 0.1 — Linux aarch64 (mô phỏng)", .info)
        append("Đăng nhập: dev@iphone · shell: zsh", .info)
        append("Gõ “help” để xem các lệnh mẫu.", .info)
        append("", .output)
    }

    func run(_ raw: String) {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        append("\(prompt) \(command)", .command)

        let parts = command.split(separator: " ").map(String.init)
        guard let head = parts.first?.lowercased() else { return }

        switch head {
        case "help":
            append(
                """
                Lệnh mẫu:
                  python --version      node -v
                  pip install <pkg>     npm install <pkg>
                  npm run dev           git status
                  ls                    pwd
                  clear

                Đây là shell mô phỏng. Engine Linux thật sẽ nối ở mốc M1.
                """,
                .output
            )

        case "ls":
            switch project?.runtime ?? .blank {
            case .node:
                append("app.js  package.json  package-lock.json  node_modules/  README.md", .output)
            case .python:
                append("app.py  requirements.txt  .venv/  README.md", .output)
            default:
                append("README.md", .output)
            }

        case "pwd":
            append("/home/dev/projects/\(project?.slug ?? "project")", .output)

        case "whoami":
            append("dev", .output)

        case "uname":
            append("Linux iphone 6.12.0-aarch64 #1 SMP aarch64 GNU/Linux", .output)

        case "python", "python3":
            if parts.count > 1, parts[1] == "--version" || parts[1] == "-V" {
                append("Python 3.13.1", .output)
            } else {
                append("Python 3.13.1 (main, Oct 2026) [Clang 18.1.8] on linux", .output)
            }

        case "pip", "pip3":
            if parts.count >= 3, parts[1] == "install" {
                let package = parts[2]
                append("Collecting \(package)", .output)
                append("Downloading \(package)-2.2.0-cp313-cp313-manylinux_2_17_aarch64.whl (1.2 MB)", .output)
                append("Successfully installed \(package)-2.2.0", .success)
            } else {
                append("Usage: pip install <package>", .error)
            }

        case "node":
            if parts.count > 1, parts[1] == "-v" || parts[1] == "--version" {
                append("v22.11.0", .output)
            } else if parts.count > 1 {
                append("(mô phỏng) chạy \(parts.dropFirst().joined(separator: " "))", .info)
            } else {
                append("Welcome to Node.js v22.11.0.", .output)
            }

        case "npm":
            handleNpm(parts: parts)

        case "npx":
            if parts.count > 1 {
                append("Need to install the following packages: \(parts[1])", .output)
                append("Ok to proceed? (y)", .output)
            } else {
                append("npm exec — usage: npx <package>", .error)
            }

        case "git":
            if parts.count > 1, parts[1] == "status" {
                append("On branch main", .output)
                append("nothing to commit, working tree clean", .output)
            } else {
                append("(mô phỏng) git \(parts.dropFirst().joined(separator: " "))", .info)
            }

        case "clear":
            lines = []

        default:
            append("zsh: command not found: \(head)", .error)
        }

        append("", .output)
        trimHistory()
    }

    private func handleNpm(parts: [String]) {
        guard parts.count > 1 else {
            append("npm <command> — ví dụ: npm install express", .info)
            return
        }

        switch parts[1] {
        case "install", "i", "add":
            let package = parts.count > 2 ? parts[2] : "dependencies"
            append("added 57 packages, and audited 58 packages in 4s", .output)
            append("found 0 vulnerabilities", .success)
            append("→ \(package) đã vào node_modules/ (mô phỏng)", .info)

        case "run":
            let script = parts.count > 2 ? parts[2] : "dev"
            if script == "dev" {
                append("> web-app@0.1.0 dev", .output)
                append("> vite", .output)
                append("", .output)
                append("  VITE v6.0.0  ready in 312 ms", .success)
                append("  ➜  Local:   http://localhost:5173/", .output)
                append("→ M2: mở địa chỉ này trong Safari của iPhone.", .info)
            } else {
                append("> \(script) (mô phỏng) — xong.", .output)
            }

        case "-v", "--version":
            append("10.9.0", .output)

        default:
            append("(mô phỏng) npm \(parts.dropFirst().joined(separator: " "))", .info)
        }
    }

    private func append(_ text: String, _ role: LineRole) {
        lines.append(ShellLine(text: text, role: role))
    }

    private func trimHistory() {
        let limit = 500
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }
}
