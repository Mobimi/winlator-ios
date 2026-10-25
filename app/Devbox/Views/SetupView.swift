import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var app: AppState

    @AppStorage("devbox.autoOpenWeb") private var autoOpenWeb: Bool = true

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

                    if app.device.debugged {
                        Label("App đang có debugger attach", systemImage: "ladybug")
                            .font(.caption)
                    }
                } header: {
                    Text("JIT")
                } footer: {
                    Text("Máy ảo Linux dùng JIT của QEMU. Không có JIT thì chỉ chạy được bản mô phỏng UI này. Bật bằng StikDebug.")
                }

                Section {
                    LabeledContent("Image", value: "Debian 13 ARM64")
                    LabeledContent("Dung lượng", value: "~480 MB (dự kiến)")
                    LabeledContent("Trạng thái", value: "Chưa cài")
                    LabeledContent("Engine", value: "QEMU (chưa nối)")
                } header: {
                    Text("Môi trường Linux")
                } footer: {
                    Text("Image sẽ được tải ở lần chạy đầu tiên (M1). Hiện app chỉ chạy shell mô phỏng.")
                }

                Section {
                    Toggle(isOn: $autoOpenWeb) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tự mở web preview")
                            Text("Khi phát hiện server mới")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Cổng theo dõi", value: "3000 · 5173 · 8000 · 8501 · 7860")
                } header: {
                    Text("Web preview")
                } footer: {
                    Text("Chạy `npm run dev`, `uvicorn`, `streamlit`… app tự mở http://localhost:<cổng> trong khung web. Tắt mục này nếu muốn mở bằng Safari.")
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
