import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var app: AppState

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
                        Image(systemName: app.device.jit.isGranted ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(app.device.jit.isGranted ? Color.green : Color.red)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.device.jit.isGranted ? "JIT đã bật" : "JIT chưa bật")
                                .font(.headline)
                            Text(app.device.jit.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let flags = app.device.csFlags {
                        LabeledContent("proc_csflags", value: String(format: "0x%08X", flags))
                            .font(.system(.caption, design: .monospaced))
                    }

                    if app.device.debugged {
                        Label("App đang có debugger attach", systemImage: "ladybug")
                            .font(.caption)
                    }
                } header: {
                    Text("JIT")
                } footer: {
                    Text("Kiểm tra bằng cờ CS_DEBUGGED (debugger attach). Bật bằng StikDebug → Enable JIT cho Devbox. Không có JIT, QEMU ở M1 sẽ không chạy.")
                }

                Section {
                    LabeledContent("Image", value: "Debian 13 ARM64")
                    LabeledContent("Dung lượng", value: "~480 MB (dự kiến)")
                    LabeledContent("Trạng thái", value: "Chưa cài")
                    LabeledContent("Engine", value: "QEMU (chưa nối)")
                } header: {
                    Text("Môi trường Linux")
                } footer: {
                    Text("Image sẽ do workflow Build Debian image tạo ra (M1). Bản app hiện tại không có engine và không giả lập lệnh Linux.")
                }

                Section {
                    LabeledContent("Trạng thái", value: "Chờ engine (M2)")
                    LabeledContent("Cách làm", value: "QMP hostfwd + WKWebView")
                } header: {
                    Text("Web preview")
                } footer: {
                    Text("Khi QEMU chạy và dev server mở cổng, app sẽ tự mở http://localhost:<cổng> trong khung web. Chưa hoạt động vì chưa có engine.")
                }

                Section("Đã có trong image (dự kiến)") {
                    Label("python3, pip, venv", systemImage: "chevron.left.forwardslash.chevron.right")
                    Label("node, npm, npx", systemImage: "hexagon")
                    Label("git, curl, wget, nano", systemImage: "terminal")
                    Label("gcc, make (biên dịch chậm nhưng chạy được)", systemImage: "hammer")
                }

                Section {
                    Label("App bị iOS tạm dừng sau ~30 giây ở nền", systemImage: "moon.zzz")
                    Label("Không chạy được app có giao diện đồ hoạ", systemImage: "display")
                    Label("Không thay thế được laptop cho build nặng", systemImage: "laptopcomputer")
                    Label("Cần bật lại JIT mỗi lần mở app (StikDebug)", systemImage: "arrow.clockwise")
                } header: {
                    Text("Giới hạn đã biết")
                } footer: {
                    Text("Đây là giới hạn của iOS, không phải lỗi app. Giữ màn hình sáng khi chạy npm install lâu.")
                }

                Section {
                    Button("Kiểm tra lại thiết bị") {
                        app.refreshDevice()
                    }
                }
            }
            .navigationTitle("Thiết lập")
            .refreshable {
                app.refreshDevice()
            }
        }
    }
}
