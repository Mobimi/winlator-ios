import Foundation
import Combine

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
    @Published private(set) var lastCommand: String?
    @Published private(set) var history: [String] = []
    @Published private(set) var snippets: [String] = []
    @Published private(set) var cwd = "~"
    @Published private(set) var fix: CommandSuggestion?
    @Published var alertCommand: String?

    private let store = SuggestionStore.shared
    private var storeSink: Set<AnyCancellable> = []
    private var consoleSink: AnyCancellable?
    private var settle: Timer?
    private var historyIndex: Int?
    private var draft = ""

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
        settle?.invalidate()
    }

    func attach(_ guest: GuestConsole) {
        consoleSink = guest.$lines
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in self?.activity(lines: lines) }
    }

    func refresh() {
        suggestions = CommandCatalog.isDangerous(input) ? [] : store.suggestions(for: input, dir: cwd)
    }

    func submit(_ guest: GuestConsole) {
        guard guest.connected else { return }
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
        guard guest.connected else { return }
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
        guard guest.connected else { return }
        guest.sendLine("fuser -k \(port)/tcp 2>/dev/null; devbox-killport \(port) 2>/dev/null; true")
        state = .sent
        settleNow()
    }

    func installExtras(guest: GuestConsole) {
        guard guest.connected else { return }
        let directory = DevboxConfig.shareDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("devbox-extra.sh")
        try? Self.extraScript.write(to: script, atomically: true, encoding: .utf8)
        guest.sendLine("sudo bash /mnt/share/devbox-extra.sh")
        lastCommand = "cài gói bổ sung"
        state = .sent
        settleNow()
    }

    private static let extraScript = """
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends tmux openssh-server ripgrep psmisc lsof tree jq zip
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
        state = .idle
        fix = nil
    }

    func applySize(cols: Int, rows: Int, guest: GuestConsole) {
        guard guest.connected, state == .idle, input.isEmpty else { return }
        guest.applySize(cols: cols, rows: rows)
    }

    private func deliver(_ command: String, guest: GuestConsole) {
        store.record(command, dir: cwd)
        lastCommand = command
        fix = nil
        input = ""
        state = .sent
        guest.sendLine(command)
        updateCwd(with: command)
        refresh()
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self, self.state == .sent else { return }
            self.state = .running
        }
    }

    private func activity(lines: [String]) {
        if state == .sent || state == .running {
            state = .running
        }
        if let name = CommandCatalog.missingCommand(in: lines) {
            fix = store.fixSuggestion(for: name)
        }
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.state == .running || self.state == .sent {
                self.state = .done
            }
        }
    }

    private func settleNow() {
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.state = .done
        }
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
