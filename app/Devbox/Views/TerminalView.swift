import SwiftUI
import Foundation

struct TerminalView: View {
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @StateObject private var shell = MockShell()

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private let quickCommands = [
        "help",
        "python --version",
        "node -v",
        "npm install express",
        "npm run dev",
        "git status"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                console
                quickBar
                inputBar
            }
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .navigationTitle(project.name.isEmpty ? "Terminal" : project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(project.runtime.shortLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Tab") { input += "  " }
                    Spacer()
                    Button("Chạy") { submit() }
                }
            }
            .onAppear {
                shell.boot(project: project)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    inputFocused = true
                }
            }
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shell.lines) { line in
                        Text(line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.role.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: shell.lines.count) { _, _ in
                guard let last = shell.lines.last?.id else { return }
                withAnimation(.linear(duration: 0.12)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var quickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickCommands, id: \.self) { command in
                    Button {
                        shell.run(command)
                    } label: {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(Color.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text(shell.prompt)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.green)
                .lineLimit(1)

            TextField("lệnh…", text: $input)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }

    private func submit() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        input = ""
        shell.run(command)
    }
}

extension LineRole {
    var color: Color {
        switch self {
        case .command:
            return Color(red: 0.55, green: 0.85, blue: 0.55)
        case .output:
            return Color(white: 0.85)
        case .error:
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .success:
            return Color(red: 0.45, green: 0.95, blue: 0.6)
        case .info:
            return Color(white: 0.55)
        }
    }
}
