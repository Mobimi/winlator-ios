import Foundation
import Darwin

enum QMPClient {
    static func quit(port: UInt16, timeout: TimeInterval) {
        guard let session = Session(port: port, timeout: timeout) else { return }
        session.write(["{\"execute\":\"qmp_capabilities\"}", "{\"execute\":\"quit\"}"])
        session.close()
    }

    static func probe(port: UInt16, timeout: TimeInterval = 2) -> String {
        let replies = run(["{\"execute\":\"query-status\"}"], port: port, timeout: timeout)
        guard let text = replies.first else { return "không trả lời" }
        guard let object = json(text) else { return "trả lời lạ" }
        if let error = object["error"] as? [String: Any] {
            return "lỗi: \(error["desc"] as? String ?? "?")"
        }
        guard let result = object["return"] as? [String: Any] else { return "trả lời lạ" }
        guard let status = result["status"] as? String else { return "ok" }
        return status
    }

    static func shutdownGuest(port: UInt16, timeout: TimeInterval = 3) -> String {
        let replies = run(["{\"execute\":\"system_powerdown\"}"], port: port, timeout: timeout)
        return replies.first ?? ""
    }

    static func hmp(_ command: String, port: UInt16, timeout: TimeInterval = 2) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let payload = "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"\(escaped)\"}}"
        let replies = run([payload], port: port, timeout: timeout)
        guard let text = replies.first, let object = json(text) else { return nil }
        if let error = object["error"] as? [String: Any] {
            return "LỖI: \(error["desc"] as? String ?? "?")"
        }
        return object["return"] as? String
    }

    static func chardevOpen(label: String = "con", port: UInt16, timeout: TimeInterval = 2) -> Bool? {
        let replies = run(["{\"execute\":\"query-chardev\"}"], port: port, timeout: timeout)
        guard let text = replies.first, let object = json(text) else { return nil }
        guard let list = object["return"] as? [[String: Any]] else { return nil }
        for entry in list where (entry["label"] as? String) == label {
            return entry["frontend-open"] as? Bool
        }
        return nil
    }

    static func diskReadBytes(port: UInt16, timeout: TimeInterval = 2) -> Int64? {
        let replies = run(["{\"execute\":\"query-blockstats\"}"], port: port, timeout: timeout)
        guard let text = replies.first, let object = json(text) else { return nil }
        guard let list = object["return"] as? [[String: Any]] else { return nil }
        var best: Int64?
        for entry in list {
            guard let stats = entry["stats"] as? [String: Any] else { continue }
            guard let value = (stats["rd_bytes"] as? NSNumber)?.int64Value else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }

    static func raw(_ payload: String, port: UInt16, timeout: TimeInterval = 2) -> String {
        run([payload], port: port, timeout: timeout).first ?? ""
    }

    private static func run(_ commands: [String], port: UInt16, timeout: TimeInterval) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let session = Session(port: port, timeout: timeout) else { return [] }
        defer { session.close() }
        session.write(["{\"execute\":\"qmp_capabilities\"}"] + commands)
        let deadline = Date().addingTimeInterval(timeout)
        var replies: [String] = []
        for _ in 0...(commands.count) {
            guard let text = session.readObject(deadline: deadline) else { break }
            replies.append(text)
        }
        guard !replies.isEmpty else { return [] }
        return Array(replies.dropFirst())
    }

    private static let lock = NSLock()

    static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    fileprivate static func connectLocal(_ descriptor: Int32, port: UInt16) -> Bool {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    fileprivate final class Session {
        private var descriptor: Int32 = -1
        private var buffer: [UInt8] = []

        init?(port: UInt16, timeout: TimeInterval) {
            var fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            if !QMPClient.connectLocal(fd, port: port) {
                close(fd)
                return nil
            }
            descriptor = fd
            if readObject(deadline: Date().addingTimeInterval(timeout)) == nil {
                close(fd)
                descriptor = -1
                fd = -1
                return nil
            }
        }

        func close() {
            if descriptor >= 0 {
                close(descriptor)
                descriptor = -1
            }
            buffer = []
        }

        func write(_ commands: [String]) {
            guard descriptor >= 0 else { return }
            let payload = commands.joined(separator: "\n") + "\n"
            _ = payload.withCString { pointer in
                Darwin.send(descriptor, pointer, strlen(pointer), 0)
            }
        }

        func readObject(deadline: Date) -> String? {
            guard descriptor >= 0 else { return nil }
            while true {
                if let text = extract() { return text }
                if Date() >= deadline { return nil }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = recv(descriptor, &chunk, chunk.count, 0)
                if count <= 0 { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }

        private func extract() -> String? {
            var depth = 0
            var start = -1
            var inString = false
            var escaped = false
            for index in buffer.indices {
                let byte = buffer[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 92 {
                        escaped = true
                    } else if byte == 34 {
                        inString = false
                    }
                    continue
                }
                if byte == 34 {
                    inString = true
                } else if byte == 123 {
                    if depth == 0 { start = index }
                    depth += 1
                } else if byte == 125 {
                    depth -= 1
                    if depth == 0, start >= 0 {
                        let text = String(decoding: buffer[start...index], as: UTF8.self)
                        buffer.removeFirst(index + 1)
                        return text
                    }
                    if depth < 0 {
                        depth = 0
                        start = -1
                    }
                }
            }
            return nil
        }
    }
}
