import Foundation

struct CommandSuggestion: Identifiable, Hashable {
    enum Kind: String {
        case history
        case command
        case subcommand
        case path
        case fix
    }

    let id = UUID()
    var text: String
    var detail: String
    var kind: Kind
    var fill: String

    static func == (lhs: CommandSuggestion, rhs: CommandSuggestion) -> Bool {
        lhs.text == rhs.text && lhs.kind == rhs.kind
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(kind.rawValue)
    }
}

enum CommandCatalog {
    static let commands: [(name: String, detail: String)] = [
        ("ls", "liệt kê file"),
        ("ls -la", "liệt kê cả file ẩn"),
        ("cd", "đổi thư mục"),
        ("pwd", "thư mục hiện tại"),
        ("clear", "xoá màn hình"),
        ("cat", "xem nội dung file"),
        ("less", "xem file dài"),
        ("nano", "sửa file"),
        ("cp", "sao chép"),
        ("mv", "di chuyển / đổi tên"),
        ("rm", "xoá"),
        ("mkdir", "tạo thư mục"),
        ("touch", "tạo file rỗng"),
        ("find", "tìm file"),
        ("grep", "tìm chuỗi"),
        ("rg", "tìm chuỗi nhanh (ripgrep)"),
        ("tar", "nén / giải nén"),
        ("zip", "nén zip"),
        ("unzip", "giải nén zip"),
        ("chmod", "đổi quyền"),
        ("chown", "đổi chủ sở hữu"),
        ("df", "dung lượng đĩa"),
        ("free", "bộ nhớ RAM"),
        ("top", "tiến trình"),
        ("htop", "tiến trình (đẹp hơn)"),
        ("ps", "danh sách tiến trình"),
        ("kill", "tắt tiến trình"),
        ("pkill", "tắt theo tên"),
        ("ss", "cổng đang mở"),
        ("curl", "gọi HTTP"),
        ("wget", "tải file"),
        ("git", "quản lý phiên bản"),
        ("python3", "chạy Python 3.13"),
        ("python", "chạy Python"),
        ("pip", "cài gói Python"),
        ("pip3", "cài gói Python"),
        ("node", "chạy Node.js 22"),
        ("npm", "quản lý gói Node"),
        ("npx", "chạy gói Node tạm thời"),
        ("apt", "cài gói Debian"),
        ("apt-get", "cài gói Debian"),
        ("dpkg", "quản lý gói .deb"),
        ("sudo", "chạy với quyền root"),
        ("su", "đổi người dùng"),
        ("ssh", "kết nối máy khác"),
        ("scp", "copy qua SSH"),
        ("tmux", "nhiều cửa sổ terminal"),
        ("screen", "terminal tách rời"),
        ("systemctl", "quản lý dịch vụ"),
        ("journalctl", "xem log hệ thống"),
        ("service", "quản lý dịch vụ"),
        ("uname", "thông tin kernel"),
        ("whoami", "tên người dùng"),
        ("id", "thông tin user"),
        ("date", "ngày giờ"),
        ("echo", "in ra màn hình"),
        ("printf", "in có định dạng"),
        ("export", "đặt biến môi trường"),
        ("env", "xem biến môi trường"),
        ("which", "tìm đường dẫn lệnh"),
        ("history", "lịch sử lệnh"),
        ("man", "hướng dẫn lệnh"),
        ("head", "xem đầu file"),
        ("tail", "xem cuối file"),
        ("wc", "đếm dòng / từ"),
        ("sort", "sắp xếp"),
        ("uniq", "lọc trùng"),
        ("sed", "sửa text"),
        ("awk", "xử lý text"),
        ("xargs", "ghép lệnh"),
        ("ln", "tạo liên kết"),
        ("du", "dung lượng thư mục"),
        ("mount", "gắn ổ đĩa"),
        ("umount", "tháo ổ đĩa"),
        ("reboot", "khởi động lại"),
        ("poweroff", "tắt máy"),
        ("exit", "thoát shell"),
        ("ping", "kiểm tra mạng"),
        ("ip", "cấu hình mạng"),
        ("netstat", "kết nối mạng"),
        ("openssl", "chứng chỉ / mã hoá"),
        ("ffmpeg", "xử lý video"),
        ("make", "build bằng Makefile"),
        ("gcc", "biên dịch C"),
        ("g++", "biên dịch C++"),
        ("cargo", "quản lý gói Rust"),
        ("go", "chạy Go"),
        ("docker", "container"),
        ("vim", "trình soạn thảo"),
        ("vi", "trình soạn thảo"),
        ("bash", "chạy shell"),
        ("sh", "chạy shell"),
        ("source", "nạp file vào shell"),
        ("alias", "đặt tên tắt"),
        ("crontab", "lịch chạy tự động"),
        ("nohup", "chạy nền, không ngắt"),
        ("bg", "đưa tiến trình ra nền"),
        ("fg", "đưa tiến trình về trước"),
        ("jobs", "tiến trình nền"),
        ("watch", "lặp lại lệnh"),
        ("time", "đo thời gian chạy"),
        ("tee", "ghi ra file và màn hình")
    ]

    static let subcommands: [String: [(String, String)]] = [
        "git": [
            ("status", "trạng thái thay đổi"),
            ("add .", "thêm tất cả thay đổi"),
            ("add -A", "thêm cả file bị xoá"),
            ("commit -m \"\"", "lưu thay đổi"),
            ("push", "đẩy lên remote"),
            ("pull", "kéo về"),
            ("log --oneline -10", "10 commit gần nhất"),
            ("diff", "xem thay đổi chưa lưu"),
            ("checkout -b ", "tạo nhánh mới"),
            ("switch ", "đổi nhánh"),
            ("branch", "danh sách nhánh"),
            ("stash", "cất tạm thay đổi"),
            ("stash pop", "lấy lại thay đổi"),
            ("restore .", "bỏ thay đổi chưa lưu"),
            ("remote -v", "xem remote"),
            ("clone ", "clone repo")
        ],
        "npm": [
            ("install", "cài dependencies"),
            ("install --save-dev ", "cài dev dependency"),
            ("run dev", "chạy dev server"),
            ("run build", "build production"),
            ("run start", "chạy bản build"),
            ("test", "chạy test"),
            ("init -y", "tạo package.json"),
            ("update", "cập nhật gói"),
            ("outdated", "gói lỗi thời"),
            ("ls", "gói đã cài")
        ],
        "npx": [
            ("create vite@latest ", "tạo dự án Vite"),
            ("--version", "phiên bản")
        ],
        "node": [
            ("--version", "phiên bản Node"),
            ("-e \"\"", "chạy code ngắn"),
            ("index.js", "chạy file"),
            ("--watch index.js", "tự chạy lại khi sửa")
        ],
        "pip": [
            ("install ", "cài gói"),
            ("install -r requirements.txt", "cài theo file"),
            ("freeze > requirements.txt", "xuất danh sách gói"),
            ("list", "gói đã cài"),
            ("install --upgrade pip", "nâng cấp pip")
        ],
        "pip3": [
            ("install ", "cài gói"),
            ("install -r requirements.txt", "cài theo file"),
            ("freeze > requirements.txt", "xuất danh sách gói"),
            ("list", "gói đã cài")
        ],
        "python3": [
            ("-V", "phiên bản Python"),
            ("-m http.server 8080", "web server nhanh"),
            ("-m venv .venv", "tạo môi trường ảo"),
            ("-m pip install ", "cài gói"),
            ("-m json.tool ", "format JSON"),
            ("script.py", "chạy file")
        ],
        "python": [
            ("-V", "phiên bản Python"),
            ("-m http.server 8080", "web server nhanh"),
            ("script.py", "chạy file")
        ],
        "apt": [
            ("update", "cập nhật danh sách gói"),
            ("upgrade -y", "nâng cấp hệ thống"),
            ("install ", "cài gói"),
            ("search ", "tìm gói"),
            ("remove ", "gỡ gói"),
            ("autoremove", "dọn gói thừa")
        ],
        "apt-get": [
            ("update", "cập nhật danh sách gói"),
            ("install -y ", "cài gói"),
            ("remove -y ", "gỡ gói")
        ],
        "systemctl": [
            ("status ", "trạng thái dịch vụ"),
            ("restart ", "khởi động lại"),
            ("start ", "bật dịch vụ"),
            ("stop ", "tắt dịch vụ"),
            ("--no-pager status", "trạng thái không phân trang")
        ],
        "tmux": [
            ("new -s dev", "tạo phiên mới"),
            ("attach -t dev", "vào lại phiên"),
            ("ls", "danh sách phiên"),
            ("kill-server", "tắt tất cả phiên")
        ],
        "ssh": [
            ("dev@127.0.0.1 -p 2222", "vào chính máy ảo"),
            ("-V", "phiên bản")
        ],
        "tar": [
            ("-xzf ", "giải nén .tar.gz"),
            ("-czf out.tar.gz ", "nén thư mục"),
            ("-tzf ", "xem bên trong")
        ],
        "grep": [
            ("-rn \"\" .", "tìm trong thư mục"),
            ("-i ", "không phân biệt hoa thường")
        ],
        "find": [
            (". -name \"\"", "tìm theo tên"),
            (". -type f -size +10M", "file lớn hơn 10 MB")
        ],
        "ss": [
            ("-ltnp", "cổng đang mở"),
            ("-tulpn", "cả UDP")
        ],
        "chmod": [
            ("+x ", "cấp quyền chạy"),
            ("-R 755 ", "cấp quyền thư mục")
        ]
    ]

    static let packageFor: [String: String] = [
        "rg": "ripgrep",
        "fd": "fd-find",
        "bat": "bat",
        "jq": "jq",
        "tree": "tree",
        "tmux": "tmux",
        "vim": "vim",
        "nvim": "neovim",
        "ssh": "openssh-client",
        "sshd": "openssh-server",
        "htop": "htop",
        "lsof": "lsof",
        "fuser": "psmisc",
        "zip": "zip",
        "unzip": "unzip",
        "make": "build-essential",
        "gcc": "build-essential",
        "g++": "build-essential",
        "ffmpeg": "ffmpeg",
        "python": "python3",
        "pip": "python3-pip",
        "node": "nodejs",
        "npm": "npm",
        "cargo": "cargo",
        "go": "golang",
        "docker": "docker.io"
    ]

    static func isDangerous(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let hardBlocks = ["mkfs", "dd if=", "> /dev/sd", ":(){", "chmod -r 777 /", "chown -r"]
        for block in hardBlocks where lowered.contains(block) {
            return true
        }
        guard lowered.contains("rm -rf") || lowered.contains("rm -fr") else { return false }
        let targets = [" /", " /*", " ~", " $home", " ..", " .", " /home", " /etc", " /usr"]
        return targets.contains { lowered.contains("rm -rf" + $0) || lowered.contains("rm -fr" + $0) }
    }

    static func missingCommand(in lines: [String]) -> String? {
        for line in lines.suffix(6).reversed() {
            if let range = line.range(of: ": command not found") {
                let head = line[..<range.lowerBound]
                if let name = head.split(separator: " ").last.map(String.init), packageFor[name] != nil {
                    return name
                }
            }
            if let range = line.range(of: ": not found") {
                let head = line[..<range.lowerBound]
                if let name = head.split(separator: " ").last.map(String.init), packageFor[name] != nil {
                    return name
                }
            }
        }
        return nil
    }
}

final class SuggestionStore: ObservableObject {
    static let shared = SuggestionStore()

    @Published private(set) var recent: [String] = []
    @Published private(set) var snippets: [String] = []

    private struct Record: Codable {
        var text: String
        var count: Int
        var last: Double
        var dirs: [String: Int]
    }

    private struct Snapshot: Codable {
        var records: [Record]
        var snippets: [String]
        var dirs: [String]
    }

    private var records: [String: Record] = [:]
    private var dirs: [String] = []
    private let fileURL: URL

    private init() {
        let directory = DevboxConfig.logsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("shell.json")
        load()
        rebuildRecent()
    }

    func record(_ command: String, dir: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var record = records[trimmed] ?? Record(text: trimmed, count: 0, last: 0, dirs: [:])
        record.count += 1
        record.last = Date().timeIntervalSince1970
        record.dirs[dir, default: 0] += 1
        records[trimmed] = record
        rememberDirectory(from: trimmed)
        persist()
        rebuildRecent()
    }

    func addSnippet(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !snippets.contains(trimmed) else { return }
        snippets.append(trimmed)
        persist()
    }

    func removeSnippet(_ text: String) {
        snippets.removeAll { $0 == text }
        persist()
    }

    func saveSnippet(_ old: String, new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = snippets.firstIndex(of: old) {
            snippets[index] = trimmed
        } else {
            snippets.append(trimmed)
        }
        persist()
    }

    func suggestions(for raw: String, dir: String) -> [CommandSuggestion] {
        let input = raw
        let leading = input.drop(while: { $0 == " " })
        if leading.isEmpty {
            return recentSuggestions(dir: dir)
        }
        let text = String(leading)
        if text == "~" || text.hasPrefix("~/") || text.hasPrefix("/") {
            let paths = pathSuggestions(for: text)
            if !paths.isEmpty { return paths }
        }
        if let space = text.firstIndex(of: " ") {
            let head = String(text[..<space]).lowercased()
            let rest = String(text[text.index(after: space)...])
            var result: [CommandSuggestion] = []
            if head == "cd" || head == "ls" || head == "cat" || head == "less" || head == "rm" || head == "cp" || head == "mv" {
                let paths = pathSuggestions(for: rest)
                if !paths.isEmpty {
                    result.append(contentsOf: paths.map { item in
                        CommandSuggestion(text: item.text, detail: item.detail, kind: .path, fill: head + " " + item.fill)
                    })
                }
            }
            if let table = CommandCatalog.subcommands[head] {
                for (candidate, detail) in table where candidate.lowercased().hasPrefix(rest.lowercased()) {
                    result.append(CommandSuggestion(text: "\(head) \(candidate)", detail: detail, kind: .subcommand, fill: "\(head) \(candidate)"))
                }
            }
            result.append(contentsOf: historySuggestions(prefix: text, dir: dir))
            return dedupe(result, limit: 6)
        }

        var result: [CommandSuggestion] = []
        let lowered = text.lowercased()
        for entry in CommandCatalog.commands where entry.name.lowercased().hasPrefix(lowered) {
            let fill = entry.name + " "
            result.append(CommandSuggestion(text: entry.name, detail: entry.detail, kind: .command, fill: fill))
        }
        result.append(contentsOf: historySuggestions(prefix: text, dir: dir))
        return dedupe(result, limit: 6)
    }

    func fixSuggestion(for name: String) -> CommandSuggestion? {
        guard let package = CommandCatalog.packageFor[name] else { return nil }
        return CommandSuggestion(
            text: "apt install \(package)",
            detail: "cài gói chứa \(name)",
            kind: .fix,
            fill: "apt install -y \(package)"
        )
    }

    private func recentSuggestions(dir: String) -> [CommandSuggestion] {
        let sorted = records.values.sorted { lhs, rhs in
            let lhsScore = score(lhs, dir: dir)
            let rhsScore = score(rhs, dir: dir)
            if lhsScore == rhsScore { return lhs.last > rhs.last }
            return lhsScore > rhsScore
        }
        return sorted.prefix(6).map {
            CommandSuggestion(text: $0.text, detail: contextDetail($0, dir: dir), kind: .history, fill: $0.text)
        }
    }

    private func historySuggestions(prefix: String, dir: String) -> [CommandSuggestion] {
        let lowered = prefix.lowercased()
        return records.values
            .filter { $0.text.lowercased().hasPrefix(lowered) && $0.text != prefix }
            .sorted { score($0, dir: dir) > score($1, dir: dir) }
            .prefix(5)
            .map {
                CommandSuggestion(text: $0.text, detail: contextDetail($0, dir: dir), kind: .history, fill: $0.text)
            }
    }

    private func contextDetail(_ record: Record, dir: String) -> String {
        let local = record.dirs[dir] ?? 0
        if local > 0 {
            return "đã dùng \(record.count) lần · \(local) lần ở đây"
        }
        return "đã dùng \(record.count) lần"
    }

    private func score(_ record: Record, dir: String) -> Double {
        let age = Date().timeIntervalSince1970 - record.last
        let recency = max(0, 1 - age / (60 * 60 * 24 * 14))
        let local = Double(record.dirs[dir] ?? 0)
        return Double(min(record.count, 40)) + recency * 12 + local * 6
    }

    private func dedupe(_ items: [CommandSuggestion], limit: Int) -> [CommandSuggestion] {
        var seen: Set<String> = []
        var result: [CommandSuggestion] = []
        for item in items {
            let key = item.text.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }

    private func pathSuggestions(for raw: String) -> [CommandSuggestion] {
        let prefix = raw.trimmingCharacters(in: .whitespaces)
        if prefix.hasPrefix("/mnt/share") {
            let relative = String(prefix.dropFirst("/mnt/share".count))
            let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            let base = DevboxConfig.shareDirectory
            let directory = trimmed.isEmpty ? base : base.appendingPathComponent(trimmed)
            return entries(in: directory, guestPrefix: "/mnt/share" + (trimmed.isEmpty ? "" : "/" + trimmed), input: prefix)
        }
        if prefix == "~" || prefix.hasPrefix("~/") {
            if prefix == "~" {
                var result: [CommandSuggestion] = [
                    CommandSuggestion(text: "~/projects", detail: "thư mục dự án", kind: .path, fill: "~/projects/")
                ]
                for slug in projectSlugs().prefix(6) {
                    let path = "~/projects/\(slug)/"
                    result.append(CommandSuggestion(text: path, detail: "dự án", kind: .path, fill: path))
                }
                return result
            }
            let relative = String(prefix.dropFirst(2))
            if relative == "projects" || relative.hasPrefix("projects/") {
                let rest = relative == "projects" ? "" : String(relative.dropFirst("projects/".count))
                let directory = DevboxConfig.documents.appendingPathComponent("Projects", isDirectory: true)
                let base = rest.isEmpty ? directory : directory.appendingPathComponent(rest)
                return entries(in: base, guestPrefix: "~/projects" + (rest.isEmpty ? "" : "/" + rest), input: prefix)
            }
            return dirs.filter { $0.hasPrefix(prefix) && $0 != prefix }.prefix(6).map {
                CommandSuggestion(text: $0, detail: "đã dùng", kind: .path, fill: $0)
            }
        }
        return dirs.filter { $0.hasPrefix(prefix) && $0 != prefix }.prefix(6).map {
            CommandSuggestion(text: $0, detail: "đã dùng", kind: .path, fill: $0)
        }
    }

    private func entries(in directory: URL, guestPrefix: String, input: String) -> [CommandSuggestion] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let needle = input.split(separator: "/").last.map(String.init) ?? ""
        var result: [CommandSuggestion] = []
        for name in names.sorted() where name.hasPrefix(needle) && name != needle {
            let full = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory)
            let escaped = name.contains(" ") ? name.replacingOccurrences(of: " ", with: "\\ ") : name
            let guest = guestPrefix + "/" + escaped + (isDirectory.boolValue ? "/" : "")
            result.append(CommandSuggestion(
                text: guest,
                detail: isDirectory.boolValue ? "thư mục" : "file",
                kind: .path,
                fill: guest
            ))
            if result.count >= 8 { break }
        }
        return result
    }

    private func projectSlugs() -> [String] {
        let directory = DevboxConfig.documents.appendingPathComponent("Projects", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted()
    }

    private func rememberDirectory(from command: String) {
        guard command.hasPrefix("cd ") else { return }
        let target = String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        guard target.hasPrefix("/") || target.hasPrefix("~") else { return }
        dirs.removeAll { $0 == target }
        dirs.insert(target, at: 0)
        if dirs.count > 20 {
            dirs = Array(dirs.prefix(20))
        }
    }

    private func rebuildRecent() {
        recent = records.values
            .sorted { $0.last > $1.last }
            .prefix(40)
            .map(\.text)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        records = Dictionary(snapshot.records.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })
        snippets = snapshot.snippets
        dirs = snapshot.dirs
    }

    private func persist() {
        let snapshot = Snapshot(records: Array(records.values), snippets: snippets, dirs: dirs)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
