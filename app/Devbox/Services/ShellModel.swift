import Foundation
import Combine

struct ShellEntry: Identifiable {
    enum Status: Equatable {
        case waiting
        case running
        case done
        case silent

        var label: String {
            switch self {
            case .waiting: return "đã gửi · chờ trả lời"
            case .running: return "đang chạy"
            case .done: return "xong"
            case .silent: return "không thấy trả lời"
            }
        }
    }

    let id = UUID()
    var command: String
    var note: String?
    var output: [String] = []
    var status: Status = .waiting
    var startedAt = Date()
    var finishedAt: Date?
}

final class ShellModel: ObservableObject {
    enum SendState: Equatable {
        case idle
        case sent
        case running
        case done

        var label: String {
            switch self {
            case .idle: return "sẵn sàng"
            case .sent: return "đã gửi"
            case .running: return "đang chạy"
            case .done: return "xong"
            }
        }
    }

    @Published var input = ""
    @Published private(set) var suggestions: [CommandSuggestion] = []
    @Published private(set) var state: SendState = .idle
    @Published private(set) var entries: [ShellEntry] = []
    @Published private(set) var silent = false
    @Published private(set) var lastCommand: String?
    @Published private(set) var history: [String] = []
    @Published private(set) var snippets: [String] = []
    @Published private(set) var cwd = "~"
    @Published private(set) var fix: CommandSuggestion?
    @Published var alertCommand: String?

    private let store = SuggestionStore.shared
    private var storeSink: Set<AnyCancellable> = []
    private var consoleSink: AnyCancellable?
    private var promptSink: AnyCancellable?
    private var monitor: Timer?
    private var historyIndex: Int?
    private var draft = ""
    /// Mốc tuyệt đối (không phải chỉ số mảng) của dòng cuối đã đọc.
    /// `GuestConsole.lines` bị cắt còn 2000 dòng, nên dùng `count` làm mốc
    /// sẽ kẹt ở 2000 và bỏ mọi output mới.
    private var consumedTotal = 0
    /// Khoá của lần chẩn đoán gần nhất (command + dòng lỗi). Tránh quét lại
    /// thư mục trên iPhone cho cùng một lỗi ở mỗi chunk output.
    private var lastDiagnosis = ""

    var transcriptText: String {
        entries.map { entry in
            let head = "$ " + entry.command
            guard !entry.output.isEmpty else { return head }
            return head + "\n" + entry.output.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    init() {
        history = store.recent
        snippets = store.snippets
        store.$recent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.history = value }
            .store(in: &storeSink)
        store.$snippets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.snippets = value }
            .store(in: &storeSink)
    }

    deinit {
        monitor?.invalidate()
    }

    func attach(_ guest: GuestConsole) {
        guard consoleSink == nil else { return }
        consumedTotal = guest.totalLines
        // Một tín hiệu cho mỗi lần đọc socket, thay vì publish từng ký tự.
        consoleSink = guest.$displayRevision
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak guest] _ in
                guard let self, let guest else { return }
                self.activity(guest.lineBatch)
            }
        promptSink = guest.$promptLine
            .receive(on: DispatchQueue.main)
            .sink { [weak self] line in self?.promptChanged(line) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak guest] _ in
            guard let self, let guest else { return }
            self.tick(guest)
        }
        RunLoop.main.add(timer, forMode: .common)
        monitor = timer
    }

    func refresh() {
        suggestions = CommandCatalog.isDangerous(input) ? [] : store.suggestions(for: input, dir: cwd)
    }

    func submit(_ guest: GuestConsole) {
        guard guest.connected else {
            guest.reconnect()
            return
        }
        guard guest.acceptsInput else { return }
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        historyIndex = nil
        if command.isEmpty {
            guest.send("\r")
            return
        }
        if CommandCatalog.isDangerous(command) {
            alertCommand = command
            return
        }
        deliver(command, guest: guest)
    }

    func confirmDanger(_ guest: GuestConsole) {
        guard let command = alertCommand else { return }
        alertCommand = nil
        deliver(command, guest: guest)
    }

    func runSnippet(_ text: String, guest: GuestConsole) {
        guard guest.acceptsInput else { return }
        input = ""
        deliver(text, guest: guest)
    }

    func accept(_ suggestion: CommandSuggestion) {
        input = suggestion.fill
        refresh()
    }

    func dismissFix() {
        fix = nil
    }

    func applyFix() {
        guard let fix else { return }
        self.fix = nil
        if let from = fix.copyFrom, let to = fix.copyTo {
            // Chép file/thư mục vào share trên iPhone rồi mới điền lệnh; chép
            // ngoài main thread để không khựng UI với dự án vài trăm file.
            let fill = fix.fill
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var ok = false
                do {
                    try? FileManager.default.removeItem(at: to)
                    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: from, to: to)
                    ok = true
                } catch {
                    ok = false
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ok {
                        self.input = fill
                    } else {
                        self.fix = CommandSuggestion(
                            text: "chép tay vào Devbox/share",
                            detail: "không chép được (hết chỗ?) — kéo file vào Files → Devbox → share",
                            kind: .fix,
                            fill: "cd /mnt/share"
                        )
                    }
                    self.refresh()
                }
            }
            return
        }
        input = fix.fill
        refresh()
    }

    func previous() {
        guard !history.isEmpty else { return }
        if historyIndex == nil {
            draft = input
            historyIndex = 0
        } else if let index = historyIndex {
            historyIndex = min(index + 1, history.count - 1)
        }
        input = history[historyIndex ?? 0]
        refresh()
    }

    func next() {
        guard let index = historyIndex else { return }
        if index == 0 {
            historyIndex = nil
            input = draft
        } else {
            historyIndex = index - 1
            input = history[historyIndex ?? 0]
        }
        refresh()
    }

    func addSnippet(_ text: String) {
        store.addSnippet(text)
    }

    func removeSnippet(_ text: String) {
        store.removeSnippet(text)
    }

    func saveSnippet(_ old: String, new: String) {
        store.saveSnippet(old, new: new)
    }

    func kill(port: Int, guest: GuestConsole) {
        guard guest.acceptsInput else { return }
        begin(display: "Tắt cổng \(port)", note: "cổng \(port)", guest: guest,
              line: "fuser -k \(port)/tcp 2>/dev/null; devbox-killport \(port) 2>/dev/null; true")
    }

    func installExtras(guest: GuestConsole) {
        guard guest.acceptsInput else { return }
        let directory = DevboxConfig.shareDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("devbox-extra.sh")
        try? Self.extraScript.write(to: script, atomically: true, encoding: .utf8)
        begin(display: "Cài gói bổ sung", note: "tmux/ssh/rg", guest: guest,
              line: "sudo bash /mnt/share/devbox-extra.sh")
    }

    func runDiagnostics(guest: GuestConsole) {
        guard guest.acceptsInput else { return }
        begin(display: "Kiểm tra console", note: "chẩn đoán", guest: guest,
              line: "echo DEVBOX-PING; whoami; pwd; python3 -V; node -v")
    }

    private static let extraScript = """
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends tmux openssh-server ripgrep psmisc lsof tree jq zip python-is-python3
    cat > /usr/local/bin/devbox-killport <<'KILLPORT'
    #!/bin/bash
    port="${1:-}"
    [ -z "$port" ] && exit 1
    hex="$(printf '%04X' "$port")"
    pids="$(awk -v h="$hex" 'NR > 1 { split($2, a, ":"); if (a[2] == h && $4 == "0A") print $10 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null | sort -u)"
    [ -z "$pids" ] && exit 0
    for pid in $pids; do
      kill "$pid" 2>/dev/null || true
    done
    exit 0
    KILLPORT
    chmod 755 /usr/local/bin/devbox-killport
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/devbox.conf <<'SSHD'
    Port 22
    AddressFamily inet
    ListenAddress 0.0.0.0
    PasswordAuthentication yes
    PermitRootLogin no
    AllowUsers dev
    UseDNS no
    PrintMotd no
    SSHD
    ssh-keygen -A
    systemctl enable --now ssh || service ssh start || true
    # npm cài global vào /usr/local (root) thì user dev bị EACCES; đổi prefix
    # sang ~/.local để `npm i -g` và `pip install --user` dùng chung một PATH.
    # Ghi thẳng ~/.npmrc (chắc chắn hơn `runuser`, vì runuser giữ HOME=/root).
    install -d -o dev -g dev /home/dev/.local/bin
    printf 'prefix=/home/dev/.local\n' > /home/dev/.npmrc
    chown dev:dev /home/dev/.npmrc
    grep -q 'HOME/.local/bin' /home/dev/.bashrc 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/dev/.bashrc
    chown dev:dev /home/dev/.bashrc
    # Image chỉ còn ~440 MB; đừng để cache .deb chiếm mất chỗ cài CLI.
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    echo "devbox extra packages OK"
    """

    func clear(guest: GuestConsole) {
        guest.clear()
        entries = []
        state = .idle
        fix = nil
        silent = false
        consumedTotal = 0
        lastDiagnosis = ""
    }

    func applySize(cols: Int, rows: Int, guest: GuestConsole) {
        guard guest.connected, guest.shellReady, input.isEmpty else { return }
        guest.applySize(cols: cols, rows: rows)
    }

    private func deliver(_ command: String, guest: GuestConsole, note: String? = nil) {
        store.record(command, dir: cwd)
        lastCommand = command
        fix = nil
        lastDiagnosis = ""
        input = ""
        state = .sent
        entries.append(ShellEntry(command: command, note: note))
        if entries.count > 60 {
            entries.removeFirst(entries.count - 60)
        }
        silent = false
        consumedTotal = guest.totalLines
        guest.sendLine(command)
        updateCwd(with: command)
        refresh()
    }

    private func begin(display: String, note: String?, guest: GuestConsole, line: String) {
        lastCommand = display
        state = .sent
        entries.append(ShellEntry(command: display, note: note))
        silent = false
        lastDiagnosis = ""
        consumedTotal = guest.totalLines
        guest.sendLine(line)
        refresh()
    }

    private func activity(_ batch: ConsoleLineBatch) {
        let total = batch.total
        if total < consumedTotal {
            consumedTotal = 0
        }
        // `batch.items` chỉ giữ 2000 dòng cuối, nên quy đổi mốc tuyệt đối
        // sang chỉ số trong mảng. Dòng mới nhất luôn ở cuối mảng.
        let base = total - batch.items.count
        let start = max(consumedTotal, base)
        let fresh = start < total ? Array(batch.items[(start - base)...]) : []
        consumedTotal = total
        if let name = CommandCatalog.missingCommand(in: fresh) {
            fix = store.fixSuggestion(for: name)
        } else if let command = entries.last?.command,
                  entries.last?.note == nil,
                  !fresh.isEmpty {
            diagnose(fresh, command: command)
        }
        guard !fresh.isEmpty, let index = entries.indices.last else { return }
        // Dòng đến sau khi prompt đã đóng lệnh (ví dụ `stty` do app tự gửi)
        // không được gán vào kết quả của lệnh trước.
        guard entries[index].status != .done else { return }
        // Gom rồi gán một lần: append trực tiếp vào `entries[index].output`
        // trong vòng lặp sẽ publish `entries` mỗi dòng — với output dày đây
        // cũng là một nguồn lag.
        var output = entries[index].output
        var appended = 0
        for raw in fresh {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if output.isEmpty, echoesCommand(trimmed, command: entries[index].command) { continue }
            if isPromptOnly(trimmed) { continue }
            output.append(raw)
            appended += 1
        }
        if output.count > 400 {
            output.removeFirst(output.count - 400)
        }
        if appended > 0 {
            entries[index].output = output
        }
        if entries[index].status == .silent || entries[index].status == .waiting {
            entries[index].status = .running
            state = .running
        }
        if silent && !entries[index].output.isEmpty {
            silent = false
        }
    }

    private func promptChanged(_ line: String) {
        guard !line.isEmpty, let index = entries.indices.last else { return }
        guard line.hasSuffix("$ ") || line.hasSuffix("# ") else { return }
        // Chỉ coi là prompt thật, không phải output tình cờ kết thúc bằng "$ ".
        guard line.contains("dev@devbox") || line.contains("root@devbox") else { return }
        guard entries[index].status != .done else { return }
        entries[index].status = .done
        entries[index].finishedAt = Date()
        state = .done
        silent = false
    }

    private func tick(_ guest: GuestConsole) {
        guard let index = entries.indices.last else { return }
        let status = entries[index].status
        guard status == .waiting || status == .running else { return }
        let idle = Date().timeIntervalSince(guest.lastActivity)
        let elapsed = Date().timeIntervalSince(entries[index].startedAt)
        guard elapsed > 10, idle > 10 else { return }
        // Lệnh đang hỏi `(y/n)` / "Ok to proceed?" thì im lặng là bình thường,
        // không được gắn nhãn "Debian không trả lời" rồi khuyên Ctrl-C.
        guard !awaitingInput(entries[index].output, tail: guest.currentLine) else { return }
        if entries[index].output.isEmpty {
            entries[index].status = .silent
            entries[index].finishedAt = Date()
            silent = true
            state = .idle
        } else if idle > 30 {
            entries[index].status = .silent
            entries[index].finishedAt = Date()
            silent = true
            state = .idle
        }
    }

    /// Output trông như đang chờ người dùng trả lời (y/n, "Ok to proceed?",
    /// nhập mật khẩu…). Chỉ dùng để không báo nhầm "không trả lời".
    /// `tail` là dòng đang gõ dở: npm in "Ok to proceed? (y)" không kèm `\n`
    /// nên câu hỏi chỉ nằm ở đó, chưa vào `output`.
    private func awaitingInput(_ output: [String], tail: String) -> Bool {
        var text = tail.trimmingCharacters(in: .whitespaces)
        if text.isEmpty,
           let last = output.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            text = last.trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return false }
        if text.hasSuffix("?") || text.hasSuffix(":") { return true }
        let lower = text.lowercased()
        let markers = [
            "(y/n)", "[y/n]", "(y)", "[y]", "ok to proceed", "do you want",
            "are you sure", "proceed?", "continue?", "press any key", "password:"
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Nhận ra các lỗi hay gặp khi chạy file vừa đưa từ máy vào hoặc cài CLI:
    /// không tìm thấy file, CRLF của Windows, thiếu quyền chạy, npm EACCES,
    /// hết đĩa, DNS của apt. Chỉ chẩn đoán khi lệnh do người dùng gõ (các
    /// lệnh nội bộ có `note`).
    private func diagnose(_ fresh: [String], command: String) {
        // Script nội bộ dài hàng nghìn ký tự: điền lại vào ô nhập là vô nghĩa.
        guard command.count <= 300 else { return }
        guard let line = fresh.last(where: { raw in
            let text = raw.lowercased()
            return text.contains("no such file") || text.contains("permission denied")
                || text.contains("bad interpreter") || text.contains("cannot execute")
                || text.contains("no space left") || text.contains("temporary failure resolving")
                || text.contains("could not resolve") || text.contains("network is unreachable")
                || text.contains("unable to locate package")
                || text.contains("has no installation candidate")
        }) else { return }
        let key = "\(command)|\(line)"
        guard lastDiagnosis != key else { return }
        lastDiagnosis = key
        let lower = line.lowercased()
        let token = Self.missingToken(in: line)
        let script = command.split(separator: " ").last.map(String.init) ?? command
        // Shebang dính `\r` (file lưu từ Windows): `/usr/bin/env: 'python3\r'`.
        if lower.contains("bad interpreter") || (token?.contains("\r") ?? false) {
            fix = CommandSuggestion(
                text: "bỏ CRLF rồi chạy lại",
                detail: "file có \\r của Windows — shebang không đọc được",
                kind: .fix,
                fill: "sed -i 's/\\r$//' \(Self.shellQuote(script)) && \(command)"
            )
            return
        }
        // npm ghi vào /usr/local (của root) → EACCES hàng loạt. Chữa đúng là
        // đổi prefix, không phải `chmod +x`, nên phải bắt trước nhánh dưới.
        if lower.contains("eacces") || (lower.contains("permission denied") && command.contains("npm")) {
            fix = CommandSuggestion(
                text: "đổi npm prefix về ~/.local",
                detail: "npm ghi vào /usr/local của root nên bị EACCES",
                kind: .fix,
                fill: "npm config set prefix ~/.local && export PATH=\"$HOME/.local/bin:$PATH\" && \(command)"
            )
            return
        }
        if lower.contains("permission denied") {
            let target = token ?? script
            // Trên 9p (`security_model=none`) `chmod +x` có thể bị nuốt; gọi
            // thẳng trình thông dịch chắc ăn hơn và không mất quyền gì.
            if let runner = Self.interpreter(for: target) {
                fix = CommandSuggestion(
                    text: "chạy bằng \(runner)",
                    detail: "file thiếu quyền chạy — gọi \(runner) trực tiếp",
                    kind: .fix,
                    fill: "\(runner) \(Self.shellQuote(target))"
                )
            } else {
                fix = CommandSuggestion(
                    text: "cấp quyền chạy",
                    detail: "file chưa có +x — chmod rồi chạy lại",
                    kind: .fix,
                    fill: "chmod +x \(Self.shellQuote(target)) && \(command)"
                )
            }
            return
        }
        // Ba nhóm lỗi môi trường hay gặp khi cài CLI/agent.
        if lower.contains("no space left") {
            fix = CommandSuggestion(
                text: "dọn dung lượng máy ảo",
                detail: "đĩa ảo đầy — xem df -h rồi xoá cache",
                kind: .fix,
                fill: "df -h; sudo apt-get clean; rm -rf ~/.cache/pip ~/.npm/_cacache; df -h"
            )
            return
        }
        if lower.contains("temporary failure resolving") || lower.contains("could not resolve")
            || lower.contains("network is unreachable") {
            fix = CommandSuggestion(
                text: "kiểm tra mạng máy ảo",
                detail: "không phân giải được tên miền — apt/pip/npm sẽ lỗi hàng loạt",
                kind: .fix,
                fill: "ping -c1 10.0.2.2; echo 'nameserver 10.0.2.3' | sudo tee /etc/resolv.conf; \(command)"
            )
            return
        }
        if lower.contains("unable to locate package") || lower.contains("has no installation candidate") {
            fix = CommandSuggestion(
                text: "cập nhật danh sách gói",
                detail: "apt chưa biết gói này — cần apt-get update",
                kind: .fix,
                fill: "sudo apt-get update && \(command)"
            )
            return
        }
        guard let path = token else { return }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return }
        locate(name, command: command)
    }

    private static func interpreter(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "py": return "python3"
        case "sh", "bash": return "bash"
        case "js", "mjs", "cjs": return "node"
        default: return nil
        }
    }

    /// Lấy tên file/hướng dẫn từ dòng lỗi của bash/python.
    private static func missingToken(in line: String) -> String? {
        if let open = line.range(of: "can't open file '"), let close = line[open.upperBound...].firstIndex(of: "'") {
            return String(line[open.upperBound..<close])
        }
        if let marker = line.range(of: "bad interpreter: ") {
            let tail = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            return tail.isEmpty ? nil : tail
        }
        for suffix in [": No such file or directory", ": Permission denied", ": not found"] {
            if let range = line.range(of: suffix) {
                let head = line[..<range.lowerBound]
                // "bash: ./x.py" / "sh: 1: ./x.py" → lấy đoạn sau dấu ':' cuối.
                if let colon = head.lastIndex(of: ":") {
                    let tail = head[head.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty { return tail }
                }
            }
        }
        return nil
    }

    /// Tìm file cùng tên (không phân biệt hoa/thường) trong các thư mục mà
    /// người dùng nhìn thấy bằng app Files.
    private enum HostFile {
        case share(URL, String)
        case hostOnly(URL)
        case none
    }

    private func locate(_ name: String, command: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hit = Self.findHostFile(named: name)
            var suggestion: CommandSuggestion?
            switch hit {
            case .share(let url, let actual):
                let dir = "/mnt/share" + Self.relativeToShare(url.deletingLastPathComponent())
                suggestion = CommandSuggestion(
                    text: "chạy từ /mnt/share",
                    detail: "thấy \(actual) trong thư mục chia sẻ",
                    kind: .fix,
                    fill: "cd \(Self.shellQuote(dir)) && \(Self.replacing(name, with: actual, in: command))"
                )
            case .hostOnly(let url):
                if let plan = Self.importPlan(file: url) {
                    suggestion = CommandSuggestion(
                        text: "chép vào /mnt/share rồi chạy",
                        detail: "\(Self.displayPath(url)) chưa nối với máy ảo",
                        kind: .fix,
                        fill: "cd \(Self.shellQuote(plan.guestDir)) && \(Self.replacing(name, with: url.lastPathComponent, in: command))",
                        copyFrom: plan.source,
                        copyTo: plan.dest
                    )
                } else {
                    suggestion = CommandSuggestion(
                        text: "chuyển tay vào Devbox/share",
                        detail: "\(Self.displayPath(url)) quá lớn hoặc không đọc được",
                        kind: .fix,
                        fill: "cd /mnt/share"
                    )
                }
            case .none:
                suggestion = CommandSuggestion(
                    text: "tìm \(name) trong máy ảo",
                    detail: "không thấy \(name) trong share hay Projects",
                    kind: .fix,
                    fill: "find /home/dev /mnt/share -name \(Self.shellQuote(name)) 2>/dev/null | head"
                )
            }
            DispatchQueue.main.async {
                guard let self, self.entries.last?.command == command else { return }
                self.fix = suggestion
            }
        }
    }

    private static func findHostFile(named name: String) -> HostFile {
        if let url = search(name, under: DevboxConfig.shareDirectory, maxDepth: 6) {
            return .share(url, url.lastPathComponent)
        }
        if let url = search(name, under: DevboxConfig.documents, maxDepth: 4) {
            return .hostOnly(url)
        }
        return .none
    }

    private static func search(_ name: String, under root: URL, maxDepth: Int) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return nil
        }
        var budget = 8000
        while let url = walker.nextObject() as? URL {
            budget -= 1
            if budget <= 0 { break }
            if walker.level > maxDepth {
                walker.skipDescendants()
                continue
            }
            guard url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return url
            }
        }
        return nil
    }

    private static func relativeToShare(_ url: URL) -> String {
        let base = DevboxConfig.shareDirectory.path
        guard url.path.hasPrefix(base) else { return "" }
        return String(url.path.dropFirst(base.count))
    }

    /// Kế hoạch chép file vào share: chép cả thư mục cha để relative import /
    /// `index.html` đi kèm vẫn chạy; nếu file nằm ngay gốc Documents thì chỉ
    /// chép đúng file đó (không chép cả Documents).
    private static func importPlan(file: URL) -> (guestDir: String, source: URL, dest: URL)? {
        let folder = file.deletingLastPathComponent()
        let rel = relativeToDocuments(folder)
        let isRoot = rel == "root"
        let source = isRoot ? file : folder
        let subpath = isRoot ? "root/\(file.lastPathComponent)" : rel
        let importRoot = DevboxConfig.shareDirectory.appendingPathComponent("_import", isDirectory: true)
        let dest = importRoot.appendingPathComponent(subpath, isDirectory: !isRoot)
        let guestDir = "/mnt/share/_import/" + (isRoot ? "root" : rel)
        guard fitsShare(source, deep: !isRoot) else { return nil }
        return (guestDir, source, dest)
    }

    /// Giới hạn để một cú bấm không cố chép 5 GB (ảnh đĩa nằm trong Documents).
    private static func fitsShare(_ url: URL, deep: Bool) -> Bool {
        if !deep {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size <= 50_000_000
        }
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url,
                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return false }
        var files = 0
        var bytes = 0
        while let item = walker.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += values?.fileSize ?? 0
            if files > 500 || bytes > 50_000_000 { return false }
        }
        return files > 0
    }

    private static func relativeToDocuments(_ url: URL) -> String {
        let base = DevboxConfig.documents.path
        var rel = url.path
        if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
        rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? "root" : rel
    }

    private static func displayPath(_ url: URL) -> String {
        let base = DevboxConfig.documents.path
        guard url.path.hasPrefix(base) else { return url.path }
        return "Files" + String(url.path.dropFirst(base.count))
    }

    private static func replacing(_ name: String, with actual: String, in command: String) -> String {
        guard name != actual,
              let range = command.range(of: name, options: [.caseInsensitive, .backwards]) else {
            return command
        }
        return command.replacingCharacters(in: range, with: actual)
    }

    private static func shellQuote(_ text: String) -> String {
        guard !text.isEmpty else { return "''" }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func echoesCommand(_ line: String, command: String) -> Bool {
        guard line.contains(command) else { return false }
        return line.contains("$") || line.contains("#")
    }

    private func isPromptOnly(_ line: String) -> Bool {
        guard line.hasPrefix("dev@devbox") || line.hasPrefix("root@devbox") else { return false }
        return line.hasSuffix("$") || line.hasSuffix("#") || line.hasSuffix("$ ") || line.hasSuffix("# ")
    }

    private func updateCwd(with command: String) {
        guard command == "cd" || command.hasPrefix("cd ") else { return }
        let target = command == "cd" ? "~" : String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        if target.isEmpty || target == "~" {
            cwd = "~"
        } else {
            cwd = target
        }
    }
}
