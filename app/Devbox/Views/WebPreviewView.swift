import SwiftUI
import WebKit
import UIKit

struct PreviewTarget: Identifiable {
    let id = UUID()
    let port: Int
    /// true khi chưa có server thật (giai đoạn hoàn thiện UI).
    let isMock: Bool
}

struct WebPreviewView: View {
    let target: PreviewTarget

    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    private var url: URL {
        URL(string: "http://127.0.0.1:\(target.port)/") ?? URL(fileURLWithPath: "/")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.07)
                    .ignoresSafeArea()

                if target.isMock {
                    MockServerPage(port: target.port)
                } else {
                    WebView(url: url, reloadToken: reloadToken)
                }
            }
            .navigationTitle("localhost:\(target.port)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .disabled(target.isMock)
                }
            }
            .safeAreaInset(edge: .bottom) {
                footer
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(target.isMock ? "Mô phỏng — server thật sẽ có ở M2" : url.absoluteString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        context.coordinator.lastToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        webView.load(URLRequest(url: url))
    }

    final class Coordinator {
        var lastToken = -1
    }
}

struct MockServerPage: View {
    let port: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                harnessCard
                note
            }
            .padding(18)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Web Preview")
                    .font(.headline)
                Text("localhost:\(port)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("Server đang chạy")
                    .font(.subheadline.bold())
                Spacer()
                Text("200 OK")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.8))
            }

            HStack(spacing: 8) {
                chip("HTTP")
                chip("127.0.0.1")
                chip("cổng \(port)")
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var harnessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent harness · demo")
                .font(.subheadline.bold())

            Text("Đây là trang mô phỏng. Khi engine thật chạy, WKWebView sẽ tải đúng giao diện web của dự án bạn — ví dụ dashboard của một harness Python/Node.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().overlay(Color.white.opacity(0.1))

            row("Runtime", "python3 / node")
            row("Trạng thái", "sẵn sàng")
            row("Log", "đang stream trong terminal")
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var note: some View {
        Text("Ở M2, khung này là WKWebView thật, có nút reload, mở Safari, và tự phát hiện cổng khi bạn chạy `npm run dev`, `uvicorn`, `streamlit`…")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(Color.white.opacity(0.7))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}
