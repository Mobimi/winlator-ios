import SwiftUI

struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Project
    private let isNew: Bool
    private let onSave: (Project) -> Void

    init(project: Project, isNew: Bool = false, onSave: @escaping (Project) -> Void) {
        _draft = State(initialValue: project)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Thông tin") {
                    TextField("Tên dự án", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Ghi chú", text: $draft.note)
                }

                Section {
                    Picker("Runtime", selection: $draft.runtime) {
                        ForEach(Runtime.allCases) { runtime in
                            Text(runtime.label).tag(runtime)
                        }
                    }
                } header: {
                    Text("Môi trường")
                } footer: {
                    Text(draft.runtime.summary)
                }

                Section("Đường dẫn trong Linux") {
                    Text(draft.slug.isEmpty ? "/home/dev/projects/project" : draft.guestPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("RAM đề xuất", value: "2.5 GB")
                    LabeledContent("Ổ đĩa", value: "Dùng chung image Linux")
                } header: {
                    Text("Tài nguyên")
                } footer: {
                    Text("iPhone 12 Pro Max có 6 GB RAM; iOS chỉ cho app dùng khoảng 3–3.5 GB nên không nên đặt cao hơn. Các thông số này áp dụng khi engine QEMU được nối (M1).")
                }
            }
            .navigationTitle(isNew ? "Dự án mới" : "Cấu hình")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        var value = draft
                        if value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            value.name = "du-an-moi"
                        }
                        onSave(value)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}
