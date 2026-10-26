import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var showRaw = false
    @State private var showFull = false
    @State private var didSize = false
    @State private var importing = false
    @State private var errorsOnly = false
    @State private var importNote: String?
    @AppStorage("devbox.consoleFont") private var consoleFont = 12.0
    @FocusState private var focused: Bool

    private static let rawBottomID = "raw-bottom"

    /// `@AppStorage` chỉ lưu `Double`; SwiftUI cần `CGFloat`.
    private var codeSize: CGFloat { CGFloat(consoleFont) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                output
                if model.doctor != nil {
                    doctorBar
                } else if let fix = model.fix {
                    fixBar(fix)
                }
                suggestionBar
                keyBar
                inputBar
            }
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    if copied {
                        Text("Đã chép vào bộ nhớ tạm")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .transition(.opacity)
                    }
                    if let importNote {
                        Text(importNote)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .transition(.opacity)
                    }
                }
                .padding(.top, 6)
            }
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
                        Button("Sửa lỗi gần nhất…") { sheet = .doctor }
                            .disabled(model.doctor == nil)
                        Button("Lịch sử lệnh") { sheet = .history }
                        Button("Xoá màn hình") { model.clear(guest: guest) }
                        Button("Kiểm tra nhanh (đĩa/mạng/node)") {
                            model.healthCheck(guest: guest)
                        }
                        .disabled(!guest.acceptsInput)
                        Button("Kiểm tra console (whoami/python3)") {
                            model.runDiagnostics(guest: guest)
                        }
                        .disabled(!guest.acceptsInput)
                        Divider()
                        Button("Đưa file vào máy ảo…") { importing = true }
                        Button("Sao chép 20 dòng cuối") { copyTail() }
                        Button("Sao chép console thô (300 dòng)") {
                            copy(guest.tail(300).map(\.text).joined(separator: "\n"))
                        }
                        Button("Sao chép toàn bộ kết quả") {
                            UIPasteboard.general.string = model.transcriptText
                        }
                        .disabled(model.entries.isEmpty)
                        Button("Lưu kết quả vào Files (share)") { exportTranscript() }
                            .disabled(model.entries.isEmpty)
                        Divider()
                        Button("Cài gói bổ sung (tmux/ssh/rg)") {
                            model.installExtras(guest: guest)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Ẩn bàn phím") { focused = false }
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
                // Đang chạy lệnh thì chưa gửi được `stty`; đánh dấu để lần
                // prompt kế tiếp gửi lại kích thước mới.
                didSize = applySize(size)
            }
            .sheet(item: $sheet) { item in
                switch item {
                case .history:
                    historySheet
                case .snippets:
                    snippetsSheet
                case .ports:
                    portsSheet
                case .doctor:
                    doctorSheet
                }
            }
            .sheet(item: $preview) { target in
                WebPreviewView(target: target)
            }
            .sheet(isPresented: $showFull) {
                fullResultsSheet
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
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
                if !connected {
                    didSize = false
                    return
                }
                if guest.shellReady, !didSize {
                    didSize = applySize(lastSize)
                }
            }
            .onChange(of: guest.shellReady) { _, ready in
                guard ready, !didSize else { return }
                didSize = applySize(lastSize)
            }
            .onChange(of: engine.state) { _, state in
                if case .running = state {
                    didSize = false
                    ports.start()
                    guest.connect(port: engine.consolePort)
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
        VStack(spacing: 0) {
            outputHeader
            statusStrip
            if showRaw {
                rawConsole
            } else {
                resultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
        .layoutPriority(1)
    }

    private var outputHeader: some View {
        HStack(spacing: 8) {
            modeButton("Kết quả", active: !showRaw) { showRaw = false }
            modeButton("Console thô", active: showRaw) { showRaw = true }
            Spacer()
            if totalErrors > 0 {
                Button {
                    errorsOnly.toggle()
                } label: {
                    Text(errorsOnly ? "Bỏ lọc lỗi" : "Chỉ lỗi (\(totalErrors))")
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(errorsOnly ? Color.red.opacity(0.3) : Color.red.opacity(0.12), in: Capsule())
                        .foregroundStyle(errorsOnly ? Color.white : Color.red.opacity(0.9))
                }
                .buttonStyle(.plain)
            }
            Text("\(guest.receivedBytes) B")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.35))
            Menu {
                ForEach([11.0, 12.0, 14.0, 16.0], id: \.self) { size in
                    Button("\(Int(size)) pt") { consoleFont = size }
                }
            } label: {
                Text("Aa")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            Button {
                showFull = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(model.entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }

    private func modeButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: active ? .semibold : .regular, design: .monospaced))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(active ? Color.green.opacity(0.22) : Color.clear, in: Capsule())
                .foregroundStyle(active ? Color.green : Color.white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusStrip: some View {
        if !images.isInstalled {
            strip(.orange, "exclamationmark.triangle.fill", "Chưa cài Debian", "Vào tab Thiết lập để tải image") {
                EmptyView()
            }
        } else if !engine.isRunning {
            switch engine.state {
            case .starting:
                strip(.yellow, "hourglass", "Đang khởi động QEMU · \(engine.lastStage)", "Thường 10–40 giây, lần đầu lâu hơn") {
                    EmptyView()
                }
            case .failed(let message):
                strip(.red, "xmark.octagon.fill", "QEMU lỗi", message) {
                    EmptyView()
                }
            case .stopped:
                strip(.orange, "stop.circle.fill", "Linux đã dừng", "Vuốt app khỏi đa nhiệm rồi mở lại để boot lại") {
                    EmptyView()
                }
            default:
                strip(.gray, "moon.zzz.fill", "Linux chưa chạy", !app.device.jitReady ? "Cần bật JIT bằng StikDebug" : "Bấm Khởi động để boot máy ảo") {
                    stripButton("Khởi động") { startEngine() }
                }
            }
        } else if !guest.connected {
            strip(.orange, "bolt.slash.fill", "Guest đã boot nhưng chưa nối console", guest.lastError ?? (guest.connecting ? "Đang thử kết nối…" : "Bấm Nối lại")) {
                stripButton("Nối lại") { reconnectConsole() }
            }
        } else if model.state == .sent || model.state == .running {
            // Lệnh đang chạy: prompt biến mất khỏi `currentLine` nên
            // `guest.shellReady` = false, nhưng stdin vẫn nhận được — gõ `y`
            // khi npm hỏi "Ok to proceed? (y)" là cách duy nhất để đi tiếp.
            strip(.cyan, "ellipsis.circle.fill", "Lệnh đang chạy", "Nếu nó hỏi y/n thì gõ câu trả lời vào ô dưới rồi gửi · Ctrl-C để ngắt") {
                stripButton("Ctrl-C") { guest.sendKey(.controlC) }
            }
        } else if model.silent {
            // Lệnh treo/không trả lời: prompt chưa về nên gửi lệnh mới sẽ bị
            // chèn vào stdin của lệnh đang chạy. Ctrl-C là cách ngắt an toàn.
            strip(.red, "exclamationmark.octagon.fill", "Debian không trả lời", "Đã nhận \(guest.receivedBytes) byte. \(heartbeatText) · đang hỏi y/n thì cứ gõ câu trả lời rồi gửi · Ctrl-C để ngắt") {
                stripButton("Ctrl-C") { guest.sendKey(.controlC) }
                stripButton("Nối lại") { reconnectConsole() }
            }
        } else if !guest.shellSeen {
            strip(.yellow, "hourglass", "Console đã nối · chờ prompt", "getty/bash còn đang khởi động. Lệnh chỉ gửi sau khi thấy prompt dev@devbox.") {
                stripButton("Nối lại") { reconnectConsole() }
            }
        }
    }

    private var heartbeatText: String {
        guard let alive = engine.guestAliveAt else { return "Guest chưa ghi nhịp" }
        let seconds = Int(Date().timeIntervalSince(alive))
        if seconds < 6 {
            return "Guest còn sống (nhịp \(max(0, seconds))s trước)"
        }
        return "Guest im lặng \(seconds)s"
    }

    private func strip<Actions: View>(
        _ color: Color,
        _ icon: String,
        _ title: String,
        _ detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                actions()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.13))
    }

    private func stripButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.16), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func reconnectConsole() {
        guest.reconnect(port: engine.consolePort)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.entries.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .textSelection(.enabled)
                            .padding(.top, 10)
                    } else if errorsOnly && visibleEntries.isEmpty {
                        Text("Không còn lệnh nào có lỗi — bấm \"Bỏ lọc lỗi\" để xem lại.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .padding(.top, 10)
                    }
                    ForEach(visibleEntries) { entry in
                        entryView(entry)
                            .id(entry.id)
                    }
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.entries.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: model.entries.last?.output.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: model.entries.last?.status) { _, _ in
                scrollToBottom(proxy)
            }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    private func entryView(_ entry: ShellEntry) -> some View {
        let filtering = errorsOnly && entry.errorCount > 0
        let lines = filtering
            ? entry.output.filter { ShellEntry.severity(of: $0) == .error }
            : entry.output
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Text("$")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                Text(entry.command)
                    .font(.system(size: max(10, codeSize - 1), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(headline(entry))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(entryColor(entry))
                    .lineLimit(1)
                // Menu đặt ở nút riêng thay vì `.contextMenu` trên cả thẻ:
                // giữ lâu trên chữ phải dùng để bôi đen, nếu gắn contextMenu
                // thì iOS mở menu và không chọn chữ được.
                Menu {
                    entryActions(entry)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
            if entry.errorCount > 0 || entry.warningCount > 0 {
                Text(countsText(entry))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(entry.errorCount > 0 ? Color.red.opacity(0.85) : Color.yellow.opacity(0.8))
            }
            if entry.output.isEmpty {
                Text(emptyEntryText(entry))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
            } else if filtering {
                // Chỉ hiện dòng lỗi, gộp một Text để vẫn bôi đen nhiều dòng.
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: codeSize, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if lines.count < entry.output.count {
                    Text("… \(entry.output.count - lines.count) dòng khác bị ẩn")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            } else {
                // Một Text cho cả khối: giữ nguyên xuống dòng nên bôi đen được
                // nhiều dòng liền (trước đây mỗi dòng một Text, chỉ chọn 1 dòng).
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: codeSize, design: .monospaced))
                    .foregroundStyle(Color(white: 0.86))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func entryActions(_ entry: ShellEntry) -> some View {
        Button {
            copy(entry.command)
        } label: {
            Label("Chép lệnh", systemImage: "terminal")
        }
        Button {
            copy(entry.output.joined(separator: "\n"))
        } label: {
            Label("Chép kết quả", systemImage: "doc.on.doc")
        }
        Button {
            copy(([entry.command] + entry.output).joined(separator: "\n"))
        } label: {
            Label("Chép lệnh + kết quả", systemImage: "doc.on.clipboard")
        }
        Divider()
        Button {
            model.input = entry.command
            model.refresh()
            focused = true
        } label: {
            Label("Điền lại lệnh", systemImage: "arrow.uturn.left")
        }
        Button {
            guard guest.acceptsInput else { return }
            model.input = entry.command
            model.submit(guest)
            focused = true
        } label: {
            Label("Chạy lại", systemImage: "arrow.clockwise")
        }
        .disabled(!guest.acceptsInput)
        Divider()
        Button {
            sheet = .ports
        } label: {
            Label("Cổng đang mở", systemImage: "network")
        }
    }

    /// Khi bật "Chỉ lỗi" thì ẩn luôn cả thẻ không có lỗi nào.
    private var visibleEntries: [ShellEntry] {
        errorsOnly ? model.entries.filter { $0.errorCount > 0 } : model.entries
    }

    private var totalErrors: Int {
        model.entries.reduce(0) { $0 + $1.errorCount }
    }

    private func headline(_ entry: ShellEntry) -> String {
        if let note = entry.note { return note }
        if let code = entry.exitCode {
            let mark = code == 0 ? "✓" : "✗ \(code)"
            return entry.durationText.map { "\(mark) · \($0)" } ?? mark
        }
        return entry.status.label
    }

    private func countsText(_ entry: ShellEntry) -> String {
        var parts: [String] = []
        if entry.errorCount > 0 { parts.append("\(entry.errorCount) lỗi") }
        if entry.warningCount > 0 { parts.append("\(entry.warningCount) cảnh báo") }
        return parts.joined(separator: " · ")
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copied = false
        }
    }

    private func emptyEntryText(_ entry: ShellEntry) -> String {
        switch entry.status {
        case .waiting, .running: return "đang chờ Debian trả lời…"
        case .done: return "(lệnh không in ra gì)"
        case .silent: return "Debian không trả lời. Bấm Nối lại ở trên."
        }
    }

    private func entryColor(_ entry: ShellEntry) -> Color {
        if let code = entry.exitCode { return code == 0 ? .green : .red }
        switch entry.status {
        case .waiting: return .yellow
        case .running: return .orange
        case .done: return .green
        case .silent: return .red
        }
    }

    private var rawConsole: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if guest.rows.isEmpty {
                        Text("Console chưa nhận được dữ liệu nào.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .padding(.top, 12)
                    } else {
                        // Một Text cho cả khối: bôi đen được nhiều dòng rồi
                        // Copy, thay vì mỗi dòng một Text (chỉ chọn 1 dòng).
                        // Không gắn contextMenu ở đây vì nó chiếm thao tác giữ
                        // lâu — muốn copy cả khối thì dùng menu ở thanh trên.
                        Text(guest.tail(300).map(\.text).joined(separator: "\n"))
                            .font(.system(size: codeSize, design: .monospaced))
                            .foregroundStyle(Color(white: 0.86))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id(Self.rawBottomID)
                    }
                }
                .padding(10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: guest.displayRevision) { _, _ in
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
            Text(fix.detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(2)
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
            Button {
                model.dismissFix()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.yellow.opacity(0.08))
    }

    /// Thanh gọn cho lỗi vừa xảy ra: nguyên nhân + cách sửa đầu tiên + nút mở
    /// chi tiết. Không tự chạy gì — mọi lệnh sửa đều phải do người dùng bấm.
    @ViewBuilder
    private var doctorBar: some View {
        if let doctor = model.doctor {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 1) {
                    Text(doctor.headline)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(2)
                    if let first = doctor.repairs.first {
                        Text(first.title)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.yellow.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let first = doctor.repairs.first, first.command != nil {
                    Button {
                        model.runRepair(first, guest: guest)
                    } label: {
                        Text("Chạy")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.yellow.opacity(0.18), in: Capsule())
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                }
                Button("Chi tiết") { sheet = .doctor }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .buttonStyle(.plain)
                Button {
                    model.dismissFix()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.yellow.opacity(0.08))
        }
    }

    private var doctorSheet: some View {
        NavigationStack {
            Group {
                if let doctor = model.doctor {
                    List {
                        Section("Vì sao") {
                            Text(doctor.headline)
                                .font(.system(size: 13, weight: .semibold))
                            Text(doctor.cause)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Section {
                            Text(doctor.errorLine.isEmpty ? "(không có output)" : doctor.errorLine)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Sao chép 20 dòng cuối") {
                                UIPasteboard.general.string = model.tailText()
                                copied = true
                            }
                        } header: {
                            Text("Dòng lỗi")
                        } footer: {
                            Text("Gửi dòng này (hoặc 20 dòng cuối) nếu cách sửa bên dưới không đúng.")
                        }
                        Section {
                            ForEach(doctor.repairs) { repair in
                                repairRow(repair, primary: true)
                            }
                        } header: {
                            Text("Cách sửa — bấm để chạy")
                        } footer: {
                            Text("App không tự chạy gì. Lệnh dài hiện thành một khối kết quả riêng để xem nó làm gì.")
                        }
                        if !doctor.probes.isEmpty {
                            Section {
                                ForEach(doctor.probes) { repair in
                                    repairRow(repair, primary: false)
                                }
                            } header: {
                                Text("Chẩn đoán thêm (chỉ đọc)")
                            } footer: {
                                Text("Các lệnh này không đổi gì trong máy ảo — chạy trước để biết chắc nguyên nhân.")
                            }
                        }
                    }
                } else {
                    List {
                        Text("Không còn chẩn đoán nào. Lỗi tiếp theo sẽ hiện ở đây.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sửa lỗi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { sheet = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func repairRow(_ repair: Repair, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(repair.title)
                .font(.system(size: 13, weight: .semibold))
            Text(repair.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let command = repair.command {
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                switch repair.action {
                case .ports:
                    Button("Mở danh sách cổng") { sheet = .ports }
                        .buttonStyle(.bordered)
                case .healthCheck:
                    Button("Chạy kiểm tra") {
                        model.runRepair(repair, guest: guest)
                        sheet = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!guest.acceptsInput)
                case .copyTail:
                    Button("Sao chép") {
                        model.runRepair(repair, guest: guest)
                        copied = true
                        sheet = nil
                    }
                    .buttonStyle(.bordered)
                case .run:
                    Button(primary ? "Chạy" : "Chạy thử") {
                        model.runRepair(repair, guest: guest)
                        sheet = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!guest.acceptsInput)
                    Button("Điền vào ô nhập") {
                        model.fillRepair(repair)
                        sheet = nil
                        focused = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
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
                key("Dán") {
                    guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                    model.input += text.trimmingCharacters(in: .newlines)
                    model.refresh()
                    focused = true
                }
                key("Chép") {
                    if showRaw {
                        copy(guest.tail(300).map(\.text).joined(separator: "\n"))
                    } else if let last = model.entries.last {
                        copy(([last.command] + last.output).joined(separator: "\n"))
                    }
                }
                Button {
                    focused = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 10))
                        Text("Ẩn phím")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(Color.white.opacity(0.9))
                }
                .buttonStyle(.plain)
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
                    .foregroundStyle(guest.acceptsInput ? Color.green : Color.white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!guest.acceptsInput)
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
                            HStack(spacing: 6) {
                                Text("localhost:\(port)")
                                    .font(.system(size: 13, design: .monospaced))
                                if let target = ports.proxies[port] {
                                    Text("→ máy ảo \(target)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.green)
                                }
                            }
                            if ports.proxies[port] == nil, ports.silentPorts.contains(port) {
                                Text("Không trả lời HTTP — có thể server chỉ nghe 127.0.0.1 trong máy ảo.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
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

                                    if ports.proxies[port] != nil {
                                        Button("Tắt proxy", role: .destructive) {
                                            stopProxy(port)
                                        }
                                        .buttonStyle(.bordered)
                                    } else if ports.silentPorts.contains(port) {
                                        Button("Thử lại") { ports.retry(port) }
                                            .buttonStyle(.bordered)
                                        Button("Chuyển qua proxy") { openProxy(port) }
                                            .buttonStyle(.bordered)
                                    }

                                    Button("Tắt cổng", role: .destructive) {
                                        model.kill(port: port, guest: guest)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Cổng web (tự phát hiện)")
                } footer: {
                    Text("Các cổng này đã được QEMU forward nên iOS mở được. “Chuyển qua proxy” dùng khi server chỉ nghe 127.0.0.1 trong máy ảo.")
                }

                if !ports.unreachable.isEmpty {
                    Section {
                        ForEach(ports.unreachable, id: \.self) { port in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("máy ảo:\(port)")
                                    .font(.system(size: 13, design: .monospaced))
                                Text("Cổng này chưa forward ra iOS nên bấm vào không mở được.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Button("Mở ra ngoài (proxy)") { openProxy(port) }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Chỉ nghe trong máy ảo")
                    } footer: {
                        Text("App chạy một proxy TCP nhỏ trong máy ảo: nghe cổng đã forward rồi chuyển vào 127.0.0.1:<cổng này>. Cần python3 (có sẵn trong image).")
                    }
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

    private var fullResultsSheet: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.07)
                    .ignoresSafeArea()
                ScrollView {
                    Text(model.transcriptText)
                        .font(.system(size: codeSize, design: .monospaced))
                        .foregroundStyle(Color(white: 0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            .navigationTitle("Toàn bộ kết quả")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { showFull = false }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = model.transcriptText
                        copied = true
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    ShareLink(item: model.transcriptText) {
                        Image(systemName: "square.and.arrow.up")
                    }
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
        switch engine.state {
        case .starting:
            return "ĐANG KHỞI ĐỘNG · \(engine.lastStage)"
        case .failed(let message):
            return message.uppercased()
        case .stopped:
            return "LINUX ĐÃ DỪNG · mở lại app để boot lại"
        case .running:
            if !guest.connected {
                return engine.guestBooted ? "GUEST ĐÃ BOOT · chưa nối console 4444" : "ĐANG BOOT · \(engine.uptimeText)"
            }
            if model.state == .sent || model.state == .running {
                return "dev@devbox · đang chạy lệnh"
            }
            if !guest.shellSeen {
                return "CONSOLE ĐÃ NỐI · chờ prompt guest"
            }
            if !guest.shellReady {
                // Bash đã lên nhưng đang chạy lệnh/hỏi y-n: vẫn gửi được.
                return "dev@devbox · \(model.cwd) · chờ trả lời"
            }
            return "dev@devbox · \(model.cwd)"
        case .idle:
            return !app.device.jitReady ? "CẦN BẬT JIT BẰNG STIKDEBUG" : "LINUX CHƯA CHẠY"
        }
    }

    private var emptyText: String {
        if !images.isInstalled {
            return "Chưa có Debian.\nVào tab Thiết lập để tải image (khoảng 500 MB)."
        }
        if !guest.connected {
            return "Chưa nối console.\nBấm Khởi động ở trên, hoặc mở một dự án để QEMU boot."
        }
        if !guest.shellSeen {
            return "Console đã nối nhưng getty chưa in prompt.\nChờ thêm vài giây — lệnh sẽ chỉ gửi khi prompt dev@devbox xuất hiện."
        }
        return "Gõ lệnh ở ô dưới rồi bấm mũi tên xanh.\nFile trong Files → Devbox → share nằm ở /mnt/share.\n\nVí dụ: cd /mnt/share && ls · python3 -V · node -v"
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
        // Terminal cần bám đáy ngay; animation mỗi lần có dòng mới sẽ xếp
        // hàng hàng trăm animation và làm giao diện giật.
        proxy.scrollTo(Self.rawBottomID, anchor: .bottom)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = model.entries.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }

    private func copyTail() {
        let text = guest.tail(20).map(\.text).joined(separator: "\n")
        UIPasteboard.general.string = text
    }

    /// Xuất toàn bộ kết quả ra `Devbox/share/devbox-output.txt` để mở bằng app
    /// Files trên iPhone (hoặc copy sang máy khác) khi cần gửi log dài.
    private func exportTranscript() {
        let dir = DevboxConfig.shareDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("devbox-output.txt")
        do {
            try model.transcriptText.write(to: url, atomically: true, encoding: .utf8)
            importNote = "Đã lưu Devbox/share/devbox-output.txt"
        } catch {
            importNote = "Không ghi được file: \(error.localizedDescription)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { self.importNote = nil }
    }

    /// Người dùng chọn file/thư mục từ app Files: chép vào `share/_import`
    /// (9p → `/mnt/share/_import`) rồi điền sẵn lệnh xem thư mục đó.
    /// Mở server chỉ nghe loopback (hoặc cổng chưa forward) ra ngoài bằng proxy
    /// TCP chạy trong guest. Chọn cổng nghe từ danh sách đã forward.
    private func openProxy(_ target: Int) {
        guard guest.acceptsInput else { return }
        guard let listen = ports.listenPort(for: target) else {
            importNote = "Hết cổng trống để làm proxy — tắt bớt server khác"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { importNote = nil }
            return
        }
        ports.startProxy(listen: listen, target: target)
        model.openWebProxy(target: target, listen: listen, guest: guest)
        sheet = nil
        importNote = "Đang mở máy ảo:\(target) qua localhost:\(listen)…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { importNote = nil }
    }

    private func stopProxy(_ listen: Int) {
        model.stopWebProxy(listen: listen, guest: guest)
        ports.stopProxy(listen: listen)
        sheet = nil
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let model = self.model
        importNote = "Đang chép \(urls.count) mục vào /mnt/share/_import…"
        DispatchQueue.global(qos: .userInitiated).async {
            let count = ShellModel.importIntoShare(urls)
            DispatchQueue.main.async {
                guard count > 0 else {
                    self.importNote = "Không chép được mục nào — kiểm tra quyền truy cập file"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { self.importNote = nil }
                    return
                }
                model.input = "cd /mnt/share/_import && ls -la"
                model.refresh()
                self.importNote = "Đã chép \(count) mục — bấm Enter để xem"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { self.importNote = nil }
            }
        }
    }

    @discardableResult
    private func applySize(_ size: CGSize) -> Bool {
        guard size.width > 0, guest.connected, guest.shellReady, model.input.isEmpty else { return false }
        let cols = max(20, min(200, Int(size.width / 7.2)))
        let rows = max(12, min(80, Int(size.height / 15)))
        model.applySize(cols: cols, rows: rows, guest: guest)
        return true
    }

    private func boot() {
        model.attach(guest)
        if engine.isRunning {
            ports.start()
            guest.connect(port: engine.consolePort)
        }
        if guest.connected, guest.shellReady, lastSize.width > 0 {
            didSize = applySize(lastSize)
        }
        startEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            focused = true
        }
    }

    private func startEngine() {
        guard images.isInstalled, !engine.isRunning, engine.canStart,
              app.device.jitReady, let image = images.image else { return }
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
    case doctor

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
