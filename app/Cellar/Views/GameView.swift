import SwiftUI

struct GameView: View {
    let container: Container

    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = MockEngine()
    @StateObject private var pad = GamepadMonitor()

    @State private var showOverlay = true
    @State private var showLog = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            surface

            if engine.progress < 1 {
                bootPanel
            } else if showOverlay {
                playOverlay
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            await engine.boot()
        }
        .sheet(isPresented: $showLog) {
            LogView()
        }
    }

    private var surface: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.white.opacity(0.22))

            Text(container.gameTitle)
                .font(.title2.bold())
                .foregroundStyle(Color.white.opacity(0.8))

            Text("Màn hình giả lập — engine chưa nối")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bootPanel: some View {
        VStack(spacing: 16) {
            ProgressView(value: engine.progress)
                .tint(.green)
                .frame(width: 260)

            Text(engine.message)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.85))

            Text("\(Int(engine.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var playOverlay: some View {
        VStack {
            HStack(spacing: 10) {
                circleButton("chevron.left") { dismiss() }

                Spacer()

                chip("\(container.profile.width)×\(container.profile.height)")
                chip("\(container.profile.fpsCap) fps")
                chip(container.profile.graphics.rawValue.uppercased())

                Spacer()

                circleButton("text.alignleft") { showLog = true }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            HStack(spacing: 12) {
                circleButton("pause.fill") {}
                circleButton("camera.fill") {}
                circleButton("gamecontroller.fill") { pad.startDiscovery() }
                circleButton("xmark") { dismiss() }
            }
            .padding(.bottom, 16)
        }
    }

    private func circleButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 42, height: 42)
                .background(Color.black.opacity(0.45), in: Circle())
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.45), in: Capsule())
    }
}

struct LogView: View {
    @Environment(\.dismiss) private var dismiss

    private let lines: [String] = [
        "[00.0] engine: kiểm tra JIT…",
        "[00.1] engine: JIT ok",
        "[00.2] qemu: -M virt -cpu max -smp 4 -m 3072",
        "[01.4] kernel: Linux aarch64",
        "[03.2] agent: hello proto=1",
        "[05.0] wine: bản ARM64",
        "[06.1] dxvk: D3D11 → Vulkan → Venus",
        "[06.4] game: frame 1"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.green.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(Color.black)
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}
