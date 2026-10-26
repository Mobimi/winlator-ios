import Foundation

final class PortWatcher: ObservableObject {
    /// Cổng guest đang LISTEN **và** đã được QEMU forward — vào được từ iOS.
    @Published private(set) var ports: [Int] = []
    /// Mọi cổng guest báo, kể cả cổng chưa forward (không vào được từ iOS).
    @Published private(set) var guestPorts: [Int] = []
    /// Cổng đã forward nhưng gọi HTTP từ iOS không trả lời: thường là server
    /// chỉ bind `127.0.0.1` trong guest. Chỉ là nghi vấn, không phải lỗi.
    @Published private(set) var silentPorts: [Int] = []
    /// Proxy đang chạy: cổng nghe (đã forward) → cổng thật trong guest.
    @Published private(set) var proxies: [Int: Int] = [:]
    @Published var autoOpenPort: Int?

    private var timer: Timer?
    private var known: Set<Int> = []
    private var probed: Set<Int> = []
    private var silent: Set<Int> = []
    /// Lúc bắt đầu proxy. Guest cần 1–2 giây mới ghi cổng nghe vào `.ports`,
    /// nên chưa được xoá proxy ngay khi cổng chưa xuất hiện.
    private var proxyStarted: [Int: Date] = [:]

    private var fileURL: URL {
        DevboxConfig.shareDirectory.appendingPathComponent(".ports")
    }

    func start() {
        stop()
        if let initial = readPorts() {
            known = initial
            apply(initial)
        } else {
            known = []
            probed = []
            silent = []
            apply([])
        }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func preferredPort() -> Int? {
        let order = [3000, 5173, 8080, 8000, 5174, 4173, 5000, 4321, 4000, 8081]
        for candidate in order where ports.contains(candidate) {
            return candidate
        }
        return ports.last
    }

    /// Cổng chưa forward — cần proxy mới vào được từ iOS.
    var unreachable: [Int] {
        guestPorts.filter { !DevboxConfig.displayedPorts.contains($0) }
    }

    /// Cổng guest đang dùng (để không chọn trùng làm cổng proxy).
    private var takenPorts: Set<Int> {
        Set(guestPorts).union(proxies.keys)
    }

    /// Chọn cổng đã forward để proxy nghe, tránh trùng cổng thật và cổng khác.
    func listenPort(for target: Int) -> Int? {
        let taken = takenPorts
        return WebProxy.candidates.first { $0 != target && !taken.contains($0) }
            ?? DevboxConfig.displayedPorts.first { $0 != target && !taken.contains($0) }
    }

    func startProxy(listen: Int, target: Int) {
        proxies[listen] = target
        proxyStarted[listen] = Date()
    }

    func stopProxy(listen: Int) {
        proxies.removeValue(forKey: listen)
        proxyStarted.removeValue(forKey: listen)
    }

    private func tick() {
        guard let current = readPorts() else {
            known = []
            probed = []
            silent = []
            apply([])
            return
        }
        apply(current)
        probed.formIntersection(current)
        silent.formIntersection(current)
        for port in current where !known.contains(port) && !probed.contains(port) {
            probed.insert(port)
            probe(port)
        }
        known = current
    }

    /// Tách cổng vào được từ iOS và cổng chỉ sống trong máy ảo, rồi publish
    /// một lần (mỗi lần gán `@Published` là một lần vẽ lại view).
    private func apply(_ current: Set<Int>) {
        let allowed = Set(DevboxConfig.displayedPorts)
        let forwarded = current.intersection(allowed).sorted()
        let all = current.sorted()
        let quiet = silent.sorted()
        if forwarded != ports { ports = forwarded }
        if all != guestPorts { guestPorts = all }
        if quiet != silentPorts { silentPorts = quiet }
        // Proxy đã tắt ở guest (reboot, kill) thì bỏ khỏi danh sách. Thêm
        // 6 giây ân hạn vì proxy mới bật chưa kịp xuất hiện trong `.ports`.
        let now = Date()
        let stale = proxies.keys.filter { listen in
            guard !current.contains(listen) else { return false }
            return now.timeIntervalSince(proxyStarted[listen] ?? .distantPast) > 6
        }
        if !stale.isEmpty {
            var remaining = proxies
            for listen in stale {
                remaining.removeValue(forKey: listen)
                proxyStarted.removeValue(forKey: listen)
            }
            proxies = remaining
        }
    }

    private func readPorts() -> Set<Int>? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        var result: Set<Int> = []
        for line in text.split(separator: "\n") {
            if let port = Int(line.trimmingCharacters(in: .whitespaces)), port > 0 {
                result.insert(port)
            }
        }
        return result
    }

    private func probe(_ port: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if response is HTTPURLResponse {
                    self.silent.remove(port)
                    self.silentPorts = self.silent.sorted()
                    self.autoOpenPort = port
                } else {
                    // Không trả lời HTTP: server có thể chỉ bind 127.0.0.1
                    // trong guest, hoặc chưa sẵn sàng. Thử lại khi bấm.
                    self.silent.insert(port)
                    self.silentPorts = self.silent.sorted()
                }
            }
        }.resume()
    }

    /// Gọi lại HTTP cho một cổng (sau khi người dùng sửa server hoặc bật proxy).
    func retry(_ port: Int) {
        silent.remove(port)
        silentPorts = silent.sorted()
        probe(port)
    }
}
