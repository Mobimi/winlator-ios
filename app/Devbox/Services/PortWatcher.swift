import Foundation

final class PortWatcher: ObservableObject {
    @Published private(set) var ports: [Int] = []
    @Published var autoOpenPort: Int?

    private var timer: Timer?
    private var known: Set<Int> = []
    private var probed: Set<Int> = []

    private var fileURL: URL {
        DevboxConfig.shareDirectory.appendingPathComponent(".ports")
    }

    func start() {
        stop()
        known = readPorts()
        ports = known.sorted()
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

    private func tick() {
        let current = readPorts()
        ports = current.sorted()
        probed.formIntersection(current)
        for port in current where !known.contains(port) && !probed.contains(port) {
            probed.insert(port)
            probe(port)
        }
        known = current
    }

    private func readPorts() -> Set<Int> {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        var result: Set<Int> = []
        for line in text.split(separator: "\n") {
            if let port = Int(line.trimmingCharacters(in: .whitespaces)), port > 0, port < 65536 {
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
            guard response is HTTPURLResponse else { return }
            DispatchQueue.main.async {
                self?.autoOpenPort = port
            }
        }.resume()
    }
}
