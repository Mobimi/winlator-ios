import SwiftUI
import WebKit
import UIKit

struct PreviewTarget: Identifiable {
    let id = UUID()
    let port: Int
}

/// Khung web thật cho dev server trong guest.
/// Chưa dùng được ở bản hiện tại vì chưa có QEMU + port forwarding (M2).
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

                WebView(url: url, reloadToken: reloadToken)
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
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(url.absoluteString)
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
        .presentationDetents([.medium, .large])
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
