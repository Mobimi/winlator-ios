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

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return }

        var greeting = [UInt8](repeating: 0, count: 4096)
        _ = recv(descriptor, &greeting, greeting.count, 0)

        let commands = "{\"execute\":\"qmp_capabilities\"}\n{\"execute\":\"quit\"}\n"
        _ = commands.withCString { pointer in
            send(descriptor, pointer, strlen(pointer), 0)
        }
    }
}
