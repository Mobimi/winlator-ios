import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var pad = GamepadMonitor()

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
                    Text("JIT là điều kiện bắt buộc để chạy máy ảo. Bật bằng StikDebug trên iPhone, hoặc cài qua AltStore/SideStore có hỗ trợ JIT.")
                }

                Section {
                    if pad.controllers.isEmpty {
                        Text("Chưa phát hiện tay cầm.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pad.controllers, id: \.self) { name in
                            Label(name, systemImage: "gamecontroller.fill")
                        }
                    }

                    LabeledContent("Tín hiệu cuối", value: pad.lastEvent)

                    Button("Quét tay cầm") {
                        pad.startDiscovery()
                    }
                } header: {
                    Text("Tay cầm")
                } footer: {
                    Text("Kết nối tay cầm trong Settings → Bluetooth của iOS trước, sau đó bấm Quét.")
                }

                Section("Việc còn lại") {
                    Label("Cài IPA bằng Sideloadly (Windows)", systemImage: "1.circle")
                    Label("Bật Developer Mode trên iPhone", systemImage: "2.circle")
                    Label("Bật JIT bằng StikDebug", systemImage: "3.circle")
                    Label("Quay lại Thư viện và bấm Play", systemImage: "4.circle")
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
