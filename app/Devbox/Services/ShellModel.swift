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

    func applyFix() {
        guard let fix else { return }
        input = fix.fill
        self.fix = nil
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
    echo "devbox extra packages OK"
    """

    func clear(guest: GuestConsole) {
        guest.clear()
        entries = []
        state = .idle
        fix = nil
        silent = false
        consumedTotal = 0
    }

    func applySize(cols: Int, rows: Int, guest: GuestConsole) {
        guard guest.connected, guest.shellReady, input.isEmpty else { return }
        guest.applySize(cols: cols, rows: rows)
    }

    private func deliver(_ command: String, guest: GuestConsole, note: String? = nil) {
        store.record(command, dir: cwd)
        lastCommand = command
        fix = nil
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
