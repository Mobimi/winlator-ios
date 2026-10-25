import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var app: AppState

    @State private var playing: Container?
    @State private var editing: Container?
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newGame = ""

    var body: some View {
        NavigationStack {
            List {
                if !app.device.jit.isGranted {
                    Section {
                        JITBanner()
                    }
                }

                Section {
                    ForEach(app.containers) { container in
                        Button {
                            playing = container
                        } label: {
                            row(container)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                app.delete(container)
                            } label: {
                                Label("Xoá", systemImage: "trash")
                            }

                            Button {
                                editing = container
                            } label: {
                                Label("Sửa", systemImage: "slider.horizontal.3")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("Game của bạn")
                } footer: {
                    Text("Đây là dữ liệu mẫu. Khi engine xong, bấm Play sẽ boot máy ảo Linux và chạy .exe thật.")
                }
            }
            .navigationTitle("Cellar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newName = ""
                        newGame = ""
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $playing) { container in
                GameView(container: container)
            }
            .sheet(item: $editing) { container in
                ContainerEditorView(container: container) { updated in
                    app.update(updated)
                }
            }
            .alert("Container mới", isPresented: $showingAdd) {
                TextField("Tên container", text: $newName)
                TextField("Tên game", text: $newGame)
                Button("Huỷ", role: .cancel) {}
                Button("Tạo") {
                    app.add(name: newName, gameTitle: newGame)
                }
            }
        }
    }

    private func row(_ container: Container) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "gamecontroller")
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(container.gameTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(container.note.isEmpty ? container.name : container.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(10)
                .background(.quaternary, in: Circle())
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct JITBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Chưa bật JIT")
                    .font(.subheadline.bold())
                Text("Không có JIT thì máy ảo không chạy được. Mở tab Thiết lập để xem hướng dẫn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
