import SwiftUI
import UIKit

struct ShellView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var guest = GuestConsole.shared
    @ObservedObject private var engine = QEMUEngine.shared
    @ObservedObject private var images = ImageStore.shared
    @StateObject private var model = ShellModel()
    @StateObject private var ports = PortWatcher()

    @State private var sheet: ShellSheet?
    @State private var preview: PreviewTarget?
    @State private var lastSize = CGSize.zero
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                output
                if let fix = model.fix {
                    fixBar(fix)
                }
                suggestionBar
                keyBar
                inputBar
            }
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .navigationTitle("Shell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        sheet = .ports
                    } label: {
                        Image(systemName: "network")
                    }
                    Button {
                        sheet = .snippets
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    Menu {
                        Button("Lịch sử lệnh") { sheet = .history }
                        Button("Xoá màn hình") { model.clear(guest: guest) }
                        Button("Sao chép 20 dòng cuối") { copyTail() }
                        Divider()
                        Button("Cài gói bổ sung (tmux/ssh/rg)") {
                            model.installExtras(guest: guest)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ShellSizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(ShellSizeKey.self) { size in
                guard size.width > 0, size != lastSize else { return }
                lastSize = size
                applySize(size)
            }
            .sheet(item: $sheet) { item in
                switch item {
                case .history:
                    historySheet
                case .snippets:
                    snippetsSheet
                case .ports:
                    portsSheet
                }
            }
            .sheet(item: $preview) { target in
                WebPreviewView(target: target)
            }
            .alert(
                "Lệnh có thể phá máy ảo",
                isPresented: Binding(
                    get: { model.alertCommand != nil },
                    set: { if !$0 { model.alertCommand = nil } }
                )
            ) {
                Button("Huỷ", role: .cancel) { model.alertCommand = nil }
                Button("Vẫn chạy", role: .destructive) { model.confirmDanger(guest) }
            } message: {
                Text("\(model.alertCommand ?? "")\n\nLệnh này xoá hoặc ghi đè dữ liệu. Chỉ chạy nếu bạn chắc chắn.")
            }
            .onAppear(perform: boot)
            .onDisappear { ports.stop() }
            .onChange(of: guest.connected) { _, connected in
                if connected {
                    applySize(lastSize)
                }
            }
            .onChange(of: engine.state) { _, state in
                if case .running = state {
                    ports.start()
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

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
            Spacer()
            if engine.isRunning {
                Text(engine.uptimeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.4))
                Text(model.state.label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(stateColor)
            } else if images.isInstalled && engine.canStart {
                Button("Khởi động") { startEngine() }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(statusColor.opacity(0.12))
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if guest.rows.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .textSelection(.enabled)
                            .padding(.top, 12)
                    }
                    ForEach(guest.tail(300)) { row in
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
                scrollToEnd(proxy)
            }
            .onChange(of: guest.rows.last?.text) { _, _ in
                scrollToEnd(proxy)
            }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    private func fixBar(_ fix: CommandSuggestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
            Text("Thiếu lệnh · gợi ý cài")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.6))
            Spacer()
            Button {
                model.applyFix()
                focused = true
            } label: {
                Text(fix.text)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.18), in: Capsule())
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.yellow.opacity(0.08))
    }

    private var suggestionBar: some View {
        Group {
            if model.suggestions.isEmpty {
                Color.clear.frame(height: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.suggestions.prefix(6)) { suggestion in
                            Button {
                                model.accept(suggestion)
                                focused = true
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color.white.opacity(0.9))
                                        .lineLimit(1)
                                    Text(suggestion.detail)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.white.opacity(0.45))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(suggestionColor(suggestion.kind).opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .frame(height: 48)
                .background(Color(red: 0.07, green: 0.07, blue: 0.08))
            }
        }
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("↑") { model.previous() }
                key("↓") { model.next() }
                key("Tab") {
                    if let first = model.suggestions.first {
                        model.accept(first)
                    } else {
                        guest.sendKey(.tab)
                    }
                    focused = true
                }
                key("Esc") { guest.sendKey(.escape) }
                key("Ctrl-C") { guest.sendKey(.controlC) }
                key("cd ~") {
                    model.input = "cd ~"
                    model.submit(guest)
                }
                key("pwd") {
                    model.input = "pwd"
                    model.submit(guest)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.cwd)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.75))
                    .lineLimit(1)
                Text("$")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green)
            }
            .frame(width: 24, alignment: .leading)

            TextField("gõ lệnh…", text: $model.input)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.send)
                .onSubmit {
                    model.submit(guest)
                    focused = true
                }
                .onChange(of: model.input) { _, _ in
                    model.refresh()
                }

            Button {
                model.submit(guest)
                focused = true
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(guest.connected ? Color.green : Color.white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!guest.connected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }

    private var historySheet: some View {
        NavigationStack {
            List {
                if model.history.isEmpty {
                    Text("Chưa có lệnh nào.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.history, id: \.self) { item in
                    Button {
                        model.input = item
                        model.refresh()
                        sheet = nil
                        focused = true
                    } label: {
                        Text(item)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Lịch sử")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { sheet = nil }
                }
            }
        }
    }

    private var snippetsSheet: some View {
        NavigationStack {
            List {
                Section("Đã lưu") {
                    if model.snippets.isEmpty {
                        Text("Chưa có snippet. Thêm ở dưới.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.snippets, id: \.self) { item in
                        HStack {
                            Button {
                                sheet = nil
                                model.runSnippet(item, guest: guest)
                            } label: {
                                Text(item)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                model.removeSnippet(item)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            model.removeSnippet(model.snippets[index])
                        }
                    }
                }
                Section("Thêm") {
                    SnippetAdder { text in
                        model.addSnippet(text)
                    }
                }
            }
            .navigationTitle("Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { sheet = nil }
                }
            }
        }
    }

    private var portsSheet: some View {
        NavigationStack {
            List {
                Section {
                    if ports.ports.isEmpty {
                        Text(engine.isRunning ? "Chưa có server nào mở cổng." : "Linux chưa chạy.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ports.ports, id: \.self) { port in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("localhost:\(port)")
                                .font(.system(size: 13, design: .monospaced))
                            HStack(spacing: 8) {
                                Button("Mở web") {
                                    sheet = nil
                                    preview = PreviewTarget(port: port)
                                }
                                .buttonStyle(.bordered)

                                Button("Copy URL") {
                                    UIPasteboard.general.string = "http://127.0.0.1:\(port)/"
                                    copied = true
                                }
                                .buttonStyle(.bordered)

                                Button("Tắt cổng", role: .destructive) {
                                    model.kill(port: port, guest: guest)
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Cổng web (tự phát hiện)")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ssh dev@127.0.0.1 -p 2222")
                            .font(.system(size: 12, design: .monospaced))
                        Text("Mật khẩu: dev · dùng Blink Shell hoặc Termius để có terminal đầy đủ (vim, htop).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Copy lệnh SSH") {
                        UIPasteboard.general.string = "ssh dev@127.0.0.1 -p 2222"
                        copied = true
                    }
                    .buttonStyle(.bordered)
                } header: {
                    Text("Vào máy ảo từ app khác")
                } footer: {
                    Text("Cần bật OpenSSH trong máy ảo: menu ⋯ → Cài gói bổ sung (tmux/ssh/rg).")
                }
            }
            .navigationTitle("Cổng đang mở")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                if copied {
                    Text("Đã copy URL")
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { sheet = nil }
                }
            }
        }
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color.white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        if !guest.connected {
            switch engine.state {
            case .running: return .orange
            case .starting: return .yellow
            case .failed: return .red
            default: return .gray
            }
        }
        return .green
    }

    private var stateColor: Color {
        switch model.state {
        case .idle: return Color.white.opacity(0.35)
        case .sent: return .yellow
        case .running: return .orange
        case .done: return .green
        }
    }

    private var statusText: String {
        if !images.isInstalled {
            return "CHƯA CÀI DEBIAN · vào tab Thiết lập"
        }
        if !guest.connected {
            switch engine.state {
            case .starting:
                return "ĐANG KHỞI ĐỘNG · \(engine.lastStage)"
            case .running:
                return "LINUX ĐANG CHẠY · đang nối console…"
            case .failed(let message):
                return message.uppercased()
            case .stopped:
                return "LINUX ĐÃ DỪNG · mở lại app để boot lại"
            case .idle:
                return app.device.jit == .denied ? "CẦN BẬT JIT BẰNG STIKDEBUG" : "LINUX CHƯA CHẠY"
            }
        }
        return "dev@devbox · \(model.cwd)"
    }

    private var emptyText: String {
        if !images.isInstalled {
            return "Chưa có Debian.\nVào tab Thiết lập để tải image (khoảng 400 MB)."
        }
        if !guest.connected {
            return "Chưa nối console.\nBấm Khởi động ở trên, hoặc mở một dự án để QEMU boot."
        }
        return "Đã nối console."
    }

    private func suggestionColor(_ kind: CommandSuggestion.Kind) -> Color {
        switch kind {
        case .history: return .cyan
        case .command: return .green
        case .subcommand: return .blue
        case .path: return .purple
        case .fix: return .yellow
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = guest.rows.last?.id else { return }
        withAnimation(.linear(duration: 0.1)) {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private func copyTail() {
        let text = guest.tail(20).map(\.text).joined(separator: "\n")
        UIPasteboard.general.string = text
    }

    private func applySize(_ size: CGSize) {
        guard size.width > 0, guest.connected else { return }
        let cols = max(20, min(200, Int(size.width / 7.2)))
        let rows = max(12, min(80, Int(size.height / 15)))
        model.applySize(cols: cols, rows: rows, guest: guest)
    }

    private func boot() {
        model.attach(guest)
        if !guest.connected {
            guest.connect(port: engine.consolePort)
        }
        if engine.isRunning {
            ports.start()
            applySize(lastSize)
        }
        startEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            focused = true
        }
    }

    private func startEngine() {
        guard images.isInstalled, !engine.isRunning, engine.canStart,
              app.device.jit != .denied, let image = images.image else { return }
        engine.start(image: image)
    }
}

private struct ShellSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private enum ShellSheet: String, Identifiable {
    case history
    case snippets
    case ports

    var id: String { rawValue }
}

private struct SnippetAdder: View {
    @State private var text = ""
    let onAdd: (String) -> Void

    init(onAdd: @escaping (String) -> Void) {
        self.onAdd = onAdd
    }

    var body: some View {
        HStack {
            TextField("npm run dev", text: $text)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Thêm") {
                onAdd(text)
                text = ""
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
