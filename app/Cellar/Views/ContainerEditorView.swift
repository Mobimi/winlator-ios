import SwiftUI

struct ContainerEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Container
    private let onSave: (Container) -> Void

    init(container: Container, onSave: @escaping (Container) -> Void) {
        _draft = State(initialValue: container)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Thông tin") {
                    TextField("Tên container", text: $draft.name)
                    TextField("Tên game", text: $draft.gameTitle)
                    TextField("Ghi chú", text: $draft.note)
                }

                Section("Đồ hoạ") {
                    Picker("Backend", selection: $draft.profile.graphics) {
                        ForEach(GraphicsBackend.allCases) { backend in
                            Text(backend.label).tag(backend)
                        }
                    }

                    Stepper(
                        "Ngang: \(draft.profile.width)",
                        value: $draft.profile.width,
                        in: 640...1920,
                        step: 160
                    )

                    Stepper(
                        "Dọc: \(draft.profile.height)",
                        value: $draft.profile.height,
                        in: 360...1080,
                        step: 90
                    )

                    Picker("Giới hạn FPS", selection: $draft.profile.fpsCap) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                }

                Section("box64") {
                    Picker("Preset", selection: $draft.profile.box64Preset) {
                        ForEach(Box64Preset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }

                    TextField("Phiên bản DXVK", text: $draft.profile.dxvkVersion)
                }

                Section("Chẩn đoán") {
                    Toggle(
                        "Hiện FPS (DXVK HUD)",
                        isOn: Binding(
                            get: { draft.profile.env["DXVK_HUD"] != nil },
                            set: { draft.profile.env["DXVK_HUD"] = $0 ? "fps" : nil }
                        )
                    )
                }
            }
            .navigationTitle("Cấu hình")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}
