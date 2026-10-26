import Foundation

/// Cầu nối cho server chỉ nghe `127.0.0.1` trong máy ảo.
///
/// QEMU forward cổng vào địa chỉ guest (`10.0.2.15`), nên một server Python
/// bind `127.0.0.1` **không** vào được từ iOS dù cổng đã forward. Cách chữa
/// không cần sửa code người dùng: chạy một proxy TCP nhỏ trong guest, nghe
/// `0.0.0.0:<cổng đã forward>` rồi chuyển tiếp vào `127.0.0.1:<cổng thật>`.
enum WebProxy {
    static let fileName = "devbox-webproxy.py"

    /// Cổng đã forward, dùng làm cổng nghe của proxy. Phải nằm trong
    /// `DevboxConfig.forwardedHostPorts` thì iOS mới vào được.
    static let candidates = [8081, 3001, 5001, 8001, 8082, 9001, 3002, 5175, 8002, 8083, 4200]

    /// Ghi script vào `share` (guest thấy ở `/mnt/share/...`). Gọi mỗi lần
    /// trước khi chạy để bản cũ trong share không ghi đè bản mới.
    @discardableResult
    static func ensureScript() -> Bool {
        let dir = DevboxConfig.shareDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Lệnh chạy nền: tắt proxy cũ cùng cổng (nếu có) rồi bật proxy mới, sau
    /// đó gọi thử HTTP để biết ngay nó có sống không.
    static func startCommand(listen: Int, target: Int) -> String {
        let pid = "/mnt/share/.webproxy-\(listen).pid"
        let log = "/mnt/share/.webproxy-\(listen).log"
        return [
            "p=\(pid)",
            "[ -f \"$p\" ] && kill \"$(cat \"$p\")\" 2>/dev/null",
            "sleep 0.3",
            "nohup python3 /mnt/share/\(fileName) --listen \(listen) --target \(target) >\(log) 2>&1 & echo $! > \"$p\"",
            "sleep 1.5",
            "curl -s -o /dev/null -w \"web \(listen) -> \(target): HTTP %{http_code}\\n\" --max-time 8 http://127.0.0.1:\(listen)/ || cat \(log)"
        ].joined(separator: "; ")
    }

    static func stopCommand(listen: Int) -> String {
        let pid = "/mnt/share/.webproxy-\(listen).pid"
        return "[ -f \"\(pid)\" ] && kill \"$(cat \"\(pid)\")\" 2>/dev/null; rm -f \"\(pid)\"; echo \"đã tắt proxy \(listen)\""
    }

    /// Proxy TCP hai chiều. Dùng `threading` để WebSocket/HMR của Vite vẫn
    /// chạy: chỉ chuyển byte, không hiểu HTTP.
    private static let script = """
    #!/usr/bin/env python3
    \"\"\"devbox-webproxy — chuyển cổng 127.0.0.1 ra 0.0.0.0 trong máy ảo.\"\"\"
    import argparse
    import socket
    import sys
    import threading


    def pump(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass


    def handle(client, target):
        try:
            upstream = socket.create_connection(("127.0.0.1", target), timeout=10)
        except OSError as exc:
            print("upstream 127.0.0.1:%s: %s" % (target, exc), file=sys.stderr, flush=True)
            client.close()
            return
        upstream.settimeout(None)
        client.settimeout(None)
        threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
        pump(upstream, client)
        client.close()
        upstream.close()


    def main():
        ap = argparse.ArgumentParser()
        ap.add_argument("--listen", type=int, required=True)
        ap.add_argument("--target", type=int, required=True)
        args = ap.parse_args()
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            server.bind(("0.0.0.0", args.listen))
        except OSError as exc:
            print("bind 0.0.0.0:%s: %s" % (args.listen, exc), file=sys.stderr, flush=True)
            sys.exit(1)
        server.listen(64)
        print("devbox-webproxy: 0.0.0.0:%s -> 127.0.0.1:%s" % (args.listen, args.target), flush=True)
        while True:
            try:
                client, _ = server.accept()
            except OSError:
                break
            threading.Thread(target=handle, args=(client, args.target), daemon=True).start()


    main()
    """
}
