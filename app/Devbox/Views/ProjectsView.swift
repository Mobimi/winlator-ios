import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var app: AppState

    @State private var opening: Project?
    @State private var editing: Project?
    @State private var creating = false
    @State private var draft = Project(name: "", runtime: .python)

    var body: some View {
        NavigationStack {
            List {
                if !app.device.jit.isGranted {
                    Section {
                        JITBanner(state: app.device.jit)
                    }
                }

                Section {
                    ForEach(app.projects) { project in
                        Button {
                            app.touch(project)
                            opening = project
                        } label: {
                            row(project)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                app.delete(project)
                            } label: {
                                Label("Xoá", systemImage: "trash")
                            }

                            Button {
                                editing = project
                            } label: {
                                Label("Sửa", systemImage: "slider.horizontal.3")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("Môi trường")
                } footer: {
                    Text("Mỗi dự án tạo một thư mục thật trong Documents/Projects và được lưu lại trên máy. Lệnh Linux chỉ chạy sau khi có engine (M1).")
                }
            }
            .navigationTitle("Devbox")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        draft = Project(name: "", runtime: .python)
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $opening) { project in
                TerminalView(project: project)
            }
            .sheet(item: $editing) { project in
                ProjectEditorView(project: project) { updated in
                    app.upsert(updated)
                }
            }
            .sheet(isPresented: $creating) {
                ProjectEditorView(project: draft, isNew: true) { created in
                    app.upsert(created)
                }
            }
        }
    }

    private func row(_ project: Project) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: project.runtime.icon)
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name.isEmpty ? "Chưa đặt tên" : project.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitle(for: project))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func subtitle(for project: Project) -> String {
        if let opened = project.lastOpened {
            return "\(project.runtime.label) · mở \(opened.formatted(date: .abbreviated, time: .shortened))"
        }
        if !project.note.isEmpty {
            return project.note
        }
        return project.runtime.label
    }
}

struct JITBanner: View {
    let state: JITState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        if case .unknown = state { return "questionmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var title: String {
        if case .unknown = state { return "Chưa xác định được JIT" }
        return "Chưa bật JIT"
    }

    private var message: String {
        if case .unknown = state {
            return "iOS này chặn đọc cờ JIT. Mở tab Thiết lập để xem chi tiết và errno."
        }
        return "Máy ảo Linux cần JIT. Mở tab Thiết lập để xem cách bật bằng StikDebug."
    }
}
