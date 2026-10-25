import SwiftUI
import UIKit

struct SetupView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var keeper = BackgroundKeeper.shared
    @AppStorage("devbox.keepRunning") private var keepRunning = true
    @State private var copied = false

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
                    Text("Nguồn thật là bit CS_DEBUGGED (0x10000000) trong proc_csflags. App tự đọc lại mỗi 4 giây khi JIT còn đỏ, nên không cần mở lại app. Nếu StikDebug báo đã bật mà vẫn đỏ: xem P_TRACED — “không” nghĩa là debugger chưa attach vào tiến trình này. JIT không cần entitlement riêng.")
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
        }
    }
}
