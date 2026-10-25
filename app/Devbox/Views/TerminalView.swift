import SwiftUI
import Foundation

struct TerminalView: View {
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppState
    @StateObject private var shell = ConsoleShell()
    @ObservedObject private var guest = GuestConsole.shared
    @StateObject private var ports = PortWatcher()
    @ObservedObject private var engine = QEMUEngine.shared
    @ObservedObject private var images = ImageStore.shared
    @ObservedObject private var keeper = BackgroundKeeper.shared

    @State private var input = ""
    @State private var preview: PreviewTarget?
    @State private var didEnter = false
    @FocusState private var inputFocused: Bool

    private let localCommands = ["help", "jit", "diag", "bg", "mem", "uname", "df", "ls", "engine"]
    private let guestCommands = ["ls", "python3 --version", "node -v", "npm -v", "clear", "df -h", "free -h"]

    private var guestMode: Bool { images.isInstalled }

    private var guestLive: Bool { guest.connected }

    private var quickCommands: [String] { guestMode ? guestCommands : localCommands }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                engineStrip
                if guestMode {
                    guestConsole
                    keyBar
                } else {
                    localConsole
                }
                quickBar
                inputBar
            }
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .navigationTitle(project.name.isEmpty ? "Console" : project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if ports.ports.isEmpty {
                        Text(project.runtime.shortLabel)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Menu {
                            ForEach(ports.ports, id: \.self) { port in
                                Button("localhost:\(port)") {
                                    preview = PreviewTarget(port: port)
                                }
                            }
                        } label: {
                            Label("Web", systemImage: "globe")
                                .font(.caption)
                        }
                    }
                }
            }
            .sheet(item: $preview) { target in
                WebPreviewView(target: target)
            }
            .onAppear(perform: boot)
            .onDisappear {
                ports.stop()
            }
            .onChange(of: images.isInstalled) { _, installed in
                if installed {
                    startEngineIfNeeded()
                }
            }
            .onChange(of: guest.connected) { _, connected in
                if connected {
                    enterProject()
                }
            }
            .onChange(of: guest.receivedBytes) { _, bytes in
                if bytes > 0 {
                    enterProject()
                }
            }
            .onChange(of: ports.autoOpenPort) { _, port in
                guard let port else { return }
                if preview == nil {
                    preview = PreviewTarget(port: port)
                }
                ports.autoOpenPort = nil
            }
        }
    }

    private var engineStrip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(engineColor)
                .frame(width: 6, height: 6)
            Text(engineText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
            Spacer()
            if engine.isRunning {
                Text(engine.uptimeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
                Button("Dừng") { engine.stop() }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.orange)
            } else if keeper.isAudioRunning {
                Text("GIỮ NỀN")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(engineColor.opacity(0.12))
    }

    private var engineColor: Color {
        switch engine.state {
        case .running:
            return .green
        case .starting:
            return .yellow
        case .failed:
            return .red
        case .idle, .stopped:
            return .orange
        }
    }

    private var engineText: String {
        if !guestMode {
            return "CHƯA CÀI IMAGE · mở Thiết lập để tải Debian"
        }
        switch engine.state {
        case .idle, .stopped:
            if app.device.jit == .denied {
                return "LINUX DỪNG · bật JIT bằng StikDebug"
            }
            return engine.hasBooted ? "LINUX ĐÃ DỪNG · mở lại app để boot lại" : "LINUX DỪNG"
        case .starting:
            return "ĐANG BOOT DEBIAN… (TCG, có thể 30–60 giây)"
        case .running:
            return guest.connected ? "LINUX ĐANG CHẠY · console đã nối" : "LINUX ĐANG CHẠY · đang nối console…"
        case .failed(let message):
            return message.uppercased()
        }
    }

    private var localConsole: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shell.lines) { line in
                        Text(line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.role.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: shell.lines.count) { _, _ in
                guard let last = shell.lines.last?.id else { return }
                withAnimation(.linear(duration: 0.12)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var guestConsole: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(guest.rows) { row in
                        Text(row.text.isEmpty ? " " : row.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(white: 0.86))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(row.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: guest.rows.count) { _, _ in
                guard let last = guest.rows.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onChange(of: guest.rows.last?.text) { _, _ in
                guard let last = guest.rows.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyButton("Esc", .escape)
                keyButton("Tab", .tab)
                keyButton("Ctrl-C", .controlC)
                keyButton("Ctrl-D", .controlD)
                keyButton("←", .left)
                keyButton("↑", .up)
                keyButton("↓", .down)
                keyButton("→", .right)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }

    private func keyButton(_ title: String, _ key: TerminalKey) -> some View {
        Button {
            guest.sendKey(key)
            inputFocused = true
        } label: {
            Text(title)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color.white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private var quickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickCommands, id: \.self) { command in
                    Button {
                        runQuick(command)
                    } label: {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(Color.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text(guestMode ? (guestLive ? "dev@devbox" : "…") : shell.prompt)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(guestMode ? (guestLive ? Color.green : Color.orange) : Color.green)
                .lineLimit(1)

            TextField(guestMode ? "lệnh trong Debian…" : "lệnh…", text: $input)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }

    private func boot() {
        guest.connect(port: engine.consolePort)
        ports.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            inputFocused = true
        }
        if guest.connected {
            enterProject()
        }
        startEngineIfNeeded()
    }

    private func startEngineIfNeeded() {
        guard guestMode, !engine.isRunning, engine.canStart,
              app.device.jit != .denied, let image = images.image else { return }
        engine.start(image: image)
    }

    private func enterProject() {
        guard guestMode, guest.connected, guest.receivedBytes > 0, !didEnter else { return }
        didEnter = true
        let path = project.guestPath
        guest.send("mkdir -p \(path) && cd \(path)\r")
    }

    private func submit() {
        if guestMode {
            guard !input.isEmpty else { return }
            guest.send(input + "\r")
            input = ""
            return
        }
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        input = ""
        shell.run(command)
    }

    private func runQuick(_ command: String) {
        if guestMode {
            guard guestLive else { return }
            guest.send(command + "\r")
        } else {
            shell.run(command)
        }
    }
}

extension LineRole {
    var color: Color {
        switch self {
        case .command:
            return Color(red: 0.55, green: 0.85, blue: 0.55)
        case .output:
            return Color(white: 0.85)
        case .error:
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .success:
            return Color(red: 0.45, green: 0.95, blue: 0.6)
        case .info:
            return Color(white: 0.55)
        }
    }
}
