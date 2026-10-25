import SwiftUI
import UIKit

struct SetupView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var keeper = BackgroundKeeper.shared
    @ObservedObject private var images = ImageStore.shared
    @ObservedObject private var engine = QEMUEngine.shared
    @StateObject private var ports = PortWatcher()
    @AppStorage("devbox.keepRunning") private var keepRunning = true
    @State private var copied = false
    @State private var preview: PreviewTarget?
    @State private var engineCheck: String?
    @State private var logCopied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Thiết bị") {
                    LabeledContent("Model", value: app.device.model)
                    LabeledContent("iOS", value: app.device.systemVersion)
                    LabeledContent("RAM", value: "\(app.device.physicalMemoryMB) MB")
                    LabeledContent("CPU", value: "\(app.device.cores) nhân")
                }

                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: jitIcon)
                            .foregroundStyle(jitColor)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.device.jit.title)
                                .font(.headline)
                            Text(app.device.jit.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let flags = app.device.csFlags {
                        LabeledContent("proc_csflags", value: String(format: "0x%08X", flags) + " · " + app.device.csSource)
                            .font(.system(.caption, design: .monospaced))
                    } else {
                        LabeledContent("proc_csflags", value: "không đọc được")
                        LabeledContent("errno", value: "csops \(app.device.csopsErrno) · sysctl \(app.device.sysctlErrno)")
                    }

                    LabeledContent("CS_DEBUGGED", value: app.device.debugged ? "BẬT (0x10000000)" : "TẮT")
                    LabeledContent("P_TRACED", value: app.device.traced ? "có debugger trace" : "không")
                    LabeledContent("PID · PPID", value: "\(app.device.pid) · \(app.device.parentPID)")

                    if app.device.debugged {
                        Label("App đang có debugger attach", systemImage: "ladybug")
                            .font(.caption)
                    }
                } header: {
                    Text("JIT")
                } footer: {
                    Text("App đọc cờ bằng csops trước, sysctl sau. iOS 18+ hay chặn sysctl.proc_csflags nên có thể ra “không xác định” dù JIT đang bật. App tự đọc lại mỗi 4 giây. Nếu StikDebug báo đã bật mà vẫn đỏ: xem P_TRACED — “không” nghĩa là debugger không còn attach vào tiến trình này. JIT không cần entitlement riêng.")
                }

                Section {
                    Toggle("Giữ app chạy khi ra nền", isOn: $keepRunning)

                    LabeledContent("Trạng thái", value: keeper.stateText)
                    if keeper.isAudioRunning {
                        LabeledContent("Đã giữ", value: keeper.uptimeText)
                    }
                    LabeledContent("Audio session", value: keeper.category)
                    LabeledContent("Route", value: keeper.route)
                    if keeper.backgroundTaskActive {
                        LabeledContent("Gia hạn tạm", value: "~30 giây")
                    }
                    LabeledContent("UIBackgroundModes", value: keeper.hasBackgroundAudioMode ? "audio ✓" : "THIẾU")
                    if keeper.interruptionCount > 0 {
                        LabeledContent("Gián đoạn audio", value: "\(keeper.interruptionCount) lần")
                    }
                    if let error = keeper.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Chạy nền")
                } footer: {
                    Text("App phát một đoạn audio im lặng để iOS không treo tiến trình → web server trong máy ảo vẫn trả lời khi bạn chuyển sang app khác. Vuốt app khỏi đa nhiệm thì luôn tắt, không cách nào chặn. Tốn pin và ấm máy, nên tắt khi không cần.")
                }

                Section {
                    LabeledContent("Entitlements", value: "Không dùng")
                    LabeledContent("Quyền đặc biệt", value: "Chỉ Info.plist")
                    LabeledContent("JIT", value: "Debugger attach (StikDebug)")
                    LabeledContent("Ký app", value: "Sideloadly / SideStore · 7 ngày")
                } header: {
                    Text("Chữ ký & quyền")
                } footer: {
                    Text("App không có file .entitlements riêng. Thêm entitlement ngoài profile free sẽ làm app cài xong bị crash. Chạy nền dùng UIBackgroundModes (Info.plist), JIT dùng CS_DEBUGGED, nên cả hai đều không cần entitlement.")
                }

                Section {
                    LabeledContent("Trạng thái", value: images.phase.text)
                    if let image = images.image {
                        LabeledContent("Debian", value: image.manifest.suite + " · ARM64")
                        LabeledContent("Kernel", value: image.manifest.kernelVersion)
                        LabeledContent("Python", value: image.manifest.packages.python)
                        LabeledContent("Node", value: image.manifest.packages.node + " · npm " + image.manifest.packages.npm)
                    }

                    if images.isInstalled {
                        Button(role: .destructive) {
                            engine.stop()
                            images.remove()
                        } label: {
                            Label("Xoá image", systemImage: "trash")
                        }
                        .disabled(images.phase.isBusy)
                    } else {
                        Button {
                            images.install()
                        } label: {
                            Label("Tải và cài image (~480 MB)", systemImage: "arrow.down.circle")
                        }
                        .disabled(images.phase.isBusy)
                    }
                } header: {
                    Text("Môi trường Linux")
                } footer: {
                    Text("App tải rootfs Debian 13 từ GitHub Release, kiểm tra SHA256 rồi giải nén zstd ngay trên máy. Cần khoảng 3 GB trống. Tải một lần, sau đó boot offline.")
                }

                Section {
                    LabeledContent("QEMU", value: engine.state.text)
                    if let image = images.image {
                        if engine.isRunning || engine.state == .starting {
                            Button(role: .destructive) {
                                engine.stop()
                            } label: {
                                Label("Dừng Linux", systemImage: "stop.circle")
                            }
                        } else if engine.canStart {
                            Button {
                                engine.start(image: image)
                            } label: {
                                Label("Khởi động Linux", systemImage: "play.circle")
                            }
                        } else {
                            Text("QEMU chỉ boot một lần mỗi tiến trình. Thoát hẳn app rồi mở lại để boot tiếp.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Console", value: "127.0.0.1:\(engine.consolePort)")
                    LabeledContent("QMP", value: "127.0.0.1:\(engine.qmpPort)")
                    LabeledContent("Bước cuối", value: engine.lastStage)
                    if engine.isRunning {
                        LabeledContent("Đã chạy", value: engine.uptimeText)
                    }
                    if case .failed(let message) = engine.state {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if !engine.logLines.isEmpty {
                        Text(engine.logLines.suffix(8).joined(separator: "\n"))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        copyEngineLog()
                    } label: {
                        Label(logCopied ? "Đã copy log QEMU" : "Sao chép log QEMU", systemImage: logCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    }

                    Button {
                        engineCheck = engine.preflight()
                    } label: {
                        Label("Kiểm tra engine (không boot)", systemImage: "stethoscope")
                    }
                    .disabled(engine.state.isActive)
                } header: {
                    Text("Engine")
                } footer: {
                    Text("QEMU aarch64 chạy trong tiến trình app, tăng tốc bằng JIT. Boot lần đầu chậm (30–60 giây) vì là TCG. “Kiểm tra engine” chỉ nạp thư viện và thử cấp phát bộ nhớ exec, không khởi động máy ảo — dùng để biết lỗi nằm ở thư viện hay ở JIT.")
                }

                Section {
                    LabeledContent("Trạng thái", value: portsText)
                    if !ports.ports.isEmpty {
                        ForEach(ports.ports, id: \.self) { port in
                            Button("Mở localhost:\(port)") {
                                preview = PreviewTarget(port: port)
                            }
                        }
                    }
                } header: {
                    Text("Web preview")
                } footer: {
                    Text("Guest ghi cổng đang mở vào file .ports trong thư mục share. Khi dev server bắt đầu lắng nghe, app tự mở khung web một lần; nút Web trong terminal để mở lại. Server chạy trong tiến trình QEMU nên ra ngoài app vẫn sống nếu giữ nền bật.")
                }

                Section("Đã có trong image (dự kiến)") {
                    Label("python3, pip, venv", systemImage: "chevron.left.forwardslash.chevron.right")
                    Label("node, npm, npx", systemImage: "hexagon")
                    Label("git, curl, wget, nano", systemImage: "terminal")
                    Label("gcc, make (biên dịch chậm nhưng chạy được)", systemImage: "hammer")
                }

                Section {
                    Label("Vuốt app khỏi đa nhiệm là app tắt (mọi app iOS đều vậy)", systemImage: "hand.raised")
                    Label("Giữ nền tốn pin và làm máy ấm", systemImage: "battery.25")
                    Label("Không chạy được app có giao diện đồ hoạ", systemImage: "display")
                    Label("Không thay thế được laptop cho build nặng", systemImage: "laptopcomputer")
                    Label("Cần bật lại JIT mỗi lần mở app (StikDebug)", systemImage: "arrow.clockwise")
                } header: {
                    Text("Giới hạn đã biết")
                } footer: {
                    Text("Đây là giới hạn của iOS, không phải lỗi app. Khi giữ nền đang bật, đừng vuốt app khỏi đa nhiệm nếu còn server chạy.")
                }

                Section {
                    Button {
                        UIPasteboard.general.string = Diagnostics.text()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Đã copy chẩn đoán" : "Sao chép chẩn đoán", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    }

                    Button("Kiểm tra lại thiết bị") {
                        app.refreshDevice()
                    }
                } footer: {
                    Text("Bấm “Sao chép chẩn đoán” rồi dán vào chat — đủ để kiểm tra JIT, nền, image, không cần chụp ảnh.")
                }
            }
            .navigationTitle("Thiết lập")
            .refreshable {
                app.refreshDevice()
            }
            .onAppear {
                ports.start()
            }
            .onDisappear {
                ports.stop()
            }
            .sheet(item: $preview) { target in
                WebPreviewView(target: target)
            }
            .navigationDestination(isPresented: Binding(get: { engineCheck != nil }, set: { if !$0 { engineCheck = nil } })) {
                if let text = engineCheck {
                    EngineCheckView(text: text)
                }
            }
        }
    }

    private func copyEngineLog() {
        let log = engine.persistedLog()
        var text = "== QEMU \(engine.state.text) · bước cuối: \(engine.lastStage) ==\n"
        text += log.isEmpty ? "(qemu.log trống)\n\n" + Diagnostics.text() : log
        UIPasteboard.general.string = text
        logCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            logCopied = false
        }
    }

    private var portsText: String {
        if !images.isInstalled {
            return "Cần cài image trước"
        }
        if ports.ports.isEmpty {
            return engine.isRunning ? "Chưa có cổng nào mở" : "Linux chưa chạy"
        }
        return ports.ports.map { String($0) }.joined(separator: ", ")
    }

    private var jitIcon: String {
        switch app.device.jit {
        case .granted: return "checkmark.seal.fill"
        case .denied: return "xmark.seal.fill"
        case .unknown: return "questionmark.seal.fill"
        }
    }

    private var jitColor: Color {
        switch app.device.jit {
        case .granted: return .green
        case .denied: return .red
        case .unknown: return .orange
        }
    }
}

private struct EngineCheckView: View {
    let text: String

    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .navigationTitle("Kiểm tra engine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "Đã copy" : "Copy", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                }
            }
        }
    }
}
