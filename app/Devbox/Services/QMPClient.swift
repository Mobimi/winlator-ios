import Foundation
import Darwin

enum QMPClient {
    static func quit(port: UInt16, timeout: TimeInterval) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard connectLocal(descriptor, port: port) else { return }

        var greeting = [UInt8](repeating: 0, count: 4096)
        _ = recv(descriptor, &greeting, greeting.count, 0)

        let commands = "{\"execute\":\"qmp_capabilities\"}\n{\"execute\":\"quit\"}\n"
        _ = commands.withCString { pointer in
            send(descriptor, pointer, strlen(pointer), 0)
        }
    }

    static func probe(port: UInt16, timeout: TimeInterval = 2) -> String {
        let payload = "{\"execute\":\"qmp_capabilities\"}\n{\"execute\":\"query-status\"}\n"
        let reply = exchange(payload, port: port, timeout: timeout)
        if reply.contains("\"status\": \"running\"") || reply.contains("\"status\":\"running\"") {
            return "running"
        }
        if reply.contains("\"return\"") {
            return "qmp-ok"
        }
        return reply.isEmpty ? "không trả lời" : String(reply.suffix(120))
    }

    static func shutdownGuest(port: UInt16, timeout: TimeInterval = 3) -> String {
        let payload = "{\"execute\":\"qmp_capabilities\"}\n{\"execute\":\"system_powerdown\"}\n"
        return exchange(payload, port: port, timeout: timeout)
    }

    static func resetConsoleChardev(qmpPort: UInt16, consolePort: UInt16, timeout: TimeInterval = 3) -> String {
        let change = "{\"execute\":\"chardev-change\",\"arguments\":{\"id\":\"con\",\"backend\":{\"type\":\"socket\",\"data\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"127.0.0.1\",\"port\":\"\(consolePort)\"}},\"server\":true,\"wait\":false}}}}"
        let payload = "{\"execute\":\"qmp_capabilities\"}\n" + change + "\n"
        return exchange(payload, port: qmpPort, timeout: timeout)
    }

    private static func exchange(_ payload: String, port: UInt16, timeout: TimeInterval) -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return "" }
        defer { close(descriptor) }

        var tv = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard connectLocal(descriptor, port: port) else { return "" }

        var greeting = [UInt8](repeating: 0, count: 4096)
        _ = recv(descriptor, &greeting, greeting.count, 0)

        _ = payload.withCString { pointer in
            send(descriptor, pointer, strlen(pointer), 0)
        }

        var collected = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 {
                break
            }
            collected += String(decoding: buffer[0..<count], as: UTF8.self)
        }
        return collected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func connectLocal(_ descriptor: Int32, port: UInt16) -> Bool {
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
}
