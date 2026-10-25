import Foundation
import Network

final class GuestConsole: ObservableObject {
    static let shared = GuestConsole()

    @Published private(set) var lines: [String] = []
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var lastError: String?
    @Published private(set) var receivedBytes = 0
    @Published private(set) var lastActivity = Date.distantPast
    @Published private(set) var connectedAt: Date?
    @Published private(set) var autoRecoveries = 0

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "devbox.guest.console")
    private var retryTimer: Timer?
    private var wantConnection = false
    private var parser = ANSIParser()
    private var pendingCR = false
    private var retryPort: UInt16 = 0
    private var generation = 0
    private var openTries = 0
    private var lastSendAt = Date.distantPast
    private var bytesAtSend = 0
    private var lastAutoRecovery = Date.distantPast
    @Published private(set) var currentLine = ""

    private let maxLines = 2000

    private init() {}

    func connect(port: UInt16) {
        wantConnection = true
        retryPort = port
        if connection == nil && !connected {
            open(port: port)
        }
        startRetryTimer(port: port)
    }

    func reconnect(port: UInt16) {
        wantConnection = true
        retryPort = port
        QEMUEngine.trace("console: yêu cầu nối lại")
        hardClose()
        reopenAfter = .distantPast
        let qmp = DevboxConfig.qmpPort
        DispatchQueue.global(qos: .userInitiated).async {
            QEMUEngine.trace("console: đang kiểm tra QEMU/serial qua 127.0.0.1:\(qmp)")
            let status = QMPClient.probe(port: qmp, timeout: 2)
            let open = QMPClient.chardevOpen(port: qmp, timeout: 2)
            let disk = QMPClient.diskReadBytes(port: qmp, timeout: 2)
            let diskText = disk.map { "\($0) B" } ?? "?"
            QEMUEngine.trace("console: qmp=\(status) · serial=\(Self.describe(open)) · đĩa đọc=\(diskText)")
        }
        startRetryTimer(port: port)
    }

    static func describe(_ value: Bool?) -> String {
        guard let value else { return "?" }
        return value ? "có client" : "không client"
    }

    func appBecameActive() {
        guard wantConnection, retryPort != 0 else { return }
        let port = retryPort
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.wantConnection else { return }
            guard self.connected else {
                if self.connection == nil {
                    self.open(port: port)
                }
                return
            }
            let qmp = DevboxConfig.qmpPort
            DispatchQueue.global(qos: .userInitiated).async {
                let open = QMPClient.chardevOpen(port: qmp, timeout: 2)
                QEMUEngine.trace("console: app quay lại · serial-open = \(Self.describe(open))")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.wantConnection, self.connected else { return }
                    if open == false {
                        QEMUEngine.trace("console: socket cũ đã chết, mở lại ngay")
                        self.reconnect(port: port)
                    } else {
                        self.send("\r")
                    }
                }
            }
        }
    }

    func reconnect() {
        guard retryPort != 0 else { return }
        reconnect(port: retryPort)
    }

    private func startRetryTimer(port: UInt16) {
        stopRetryTimer()
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self, self.wantConnection else { return }
            if self.connected {
                self.checkSilence(port: port)
                return
            }
            guard Date() >= self.reopenAfter else { return }
            if self.connection == nil {
                self.open(port: port)
            } else if self.connecting, let started = self.connectingSince,
                      Date().timeIntervalSince(started) > 6 {
                QEMUEngine.trace("console: kết nối treo quá 6s, tạo lại")
                self.hardClose()
                self.open(port: port)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private var connectingSince: Date?
    private var reopenAfter = Date.distantPast

    private func checkSilence(port: UInt16) {
        guard lastSendAt > Date.distantPast, retryPort != 0 else { return }
        let quiet = Date().timeIntervalSince(lastSendAt)
        let answered = receivedBytes - bytesAtSend
        let limit: TimeInterval = autoRecoveries == 0 ? 8 : 22
        guard quiet > limit, answered <= 0 else { return }
        guard autoRecoveries < 2, Date().timeIntervalSince(lastAutoRecovery) > 25 else { return }
        autoRecoveries += 1
        lastAutoRecovery = Date()
        QEMUEngine.trace("console: gửi lệnh \(Int(quiet))s không thấy trả lời, tự mở lại serial (lần \(autoRecoveries))")
        reconnect(port: port)
    }

    private func hardClose() {
        generation += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        parser = ANSIParser()
        pendingCR = false
        connected = false
        connecting = false
        connectingSince = nil
        lastError = nil
    }

    func disconnect() {
        wantConnection = false
        stopRetryTimer()
        hardClose()
    }

    func clear() {
        DispatchQueue.main.async {
            self.lines = []
            self.currentLine = ""
            self.pendingCR = false
            self.parser = ANSIParser()
        }
    }

    func send(_ text: String, expectReply: Bool = true) {
        guard let data = text.data(using: .utf8) else { return }
        guard connected else {
            QEMUEngine.trace("console: bỏ qua gửi \(text.count) ký tự vì chưa nối")
            return
        }
        if expectReply {
            lastSendAt = Date()
            bytesAtSend = receivedBytes
        }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func sendControl(_ code: UInt8) {
        send(String(Character(Unicode.Scalar(code))))
    }

    func sendLine(_ text: String, expectReply: Bool = true) {
        send(text + "\r", expectReply: expectReply)
    }

    func applySize(cols: Int, rows: Int) {
        guard connected, cols > 0, rows > 0 else { return }
        sendLine("stty cols \(cols) rows \(rows) 2>/dev/null", expectReply: false)
    }

    func sendKey(_ key: TerminalKey) {
        send(key.sequence)
    }

    private func open(port: UInt16) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        generation += 1
        let gen = generation
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        openTries += 1
        connecting = true
        connectingSince = Date()
        QEMUEngine.trace("console: mở 127.0.0.1:\(port) (lần \(openTries))")
        let candidate = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort, using: .tcp)
        candidate.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == gen else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.connected = true
                    self.connecting = false
                    self.connectingSince = nil
                    self.lastError = nil
                    self.connectedAt = Date()
                    self.openTries = 0
                    QEMUEngine.trace("console: đã nối 127.0.0.1:\(port)")
                    let qmp = DevboxConfig.qmpPort
                    DispatchQueue.global(qos: .utility).async {
                        let open = QMPClient.chardevOpen(port: qmp, timeout: 2)
                        QEMUEngine.trace("console: QEMU thấy client serial = \(Self.describe(open))")
                    }
                }
                self.receive(on: candidate, generation: gen)
            case .waiting(let error):
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.lastError = error.localizedDescription
                    QEMUEngine.trace("console: chờ \(error.localizedDescription)")
                }
            case .failed(let error):
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.connected = false
                    self.connecting = false
                    self.connectingSince = nil
                    self.lastError = error.localizedDescription
                    self.connection = nil
                    QEMUEngine.trace("console: lỗi \(error.localizedDescription)")
                }
                candidate.cancel()
            case .cancelled:
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.connected = false
                    self.connecting = false
                }
            default:
                break
            }
        }
        candidate.start(queue: queue)
        connection = candidate
    }

    private func receive(on connection: NWConnection, generation gen: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.generation == gen else { return }
            if let data, !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    if self.receivedBytes == 0 {
                        let sample = text.prefix(160).replacingOccurrences(of: "\n", with: " ")
                        QEMUEngine.trace("console: byte đầu tiên · \"\(sample)\"")
                    }
                    self.receivedBytes += data.count
                    self.lastActivity = Date()
                    self.autoRecoveries = 0
                    self.consume(text)
                    if text.contains("login:") || text.contains("dev@devbox") {
                        if !self.promptSeen {
                            self.promptSeen = true
                            QEMUEngine.trace("console: thấy prompt guest sau \(Int(Date().timeIntervalSince(self.connectedAt ?? Date())))s")
                        }
                    }
                }
            }
            if isComplete || error != nil {
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.connected = false
                    self.connecting = false
                    self.connection = nil
                    QEMUEngine.trace("console: đóng kết nối \(isComplete ? "EOF" : (error?.localizedDescription ?? ""))")
                }
                return
            }
            self.receive(on: connection, generation: gen)
        }
    }

    private var promptSeen = false

    private func consume(_ text: String) {
        for character in text {
            if parser.isInsideSequence {
                parser.feed(character)
                continue
            }
            if pendingCR {
                if character == "\n" {
                    pendingCR = false
                    endLine()
                    continue
                }
                if character == "\r" {
                    continue
                }
                pendingCR = false
                currentLine = ""
            }
            switch character {
            case "\u{1B}":
                parser.begin()
            case "\r":
                pendingCR = true
            case "\n":
                endLine()
            case "\u{8}":
                if !currentLine.isEmpty {
                    currentLine.removeLast()
                }
            case "\t":
                currentLine += "    "
            default:
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20 {
                    continue
                }
                currentLine.append(character)
            }
        }
        if currentLine.count > 4000 {
            currentLine = String(currentLine.suffix(4000))
        }
    }

    private func endLine() {
        lines.append(currentLine)
        currentLine = ""
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    var displayLines: [String] {
        var result = lines
        if !currentLine.isEmpty || lines.isEmpty {
            result.append(currentLine)
        }
        return result
    }

    var rows: [ConsoleRow] {
        displayLines.enumerated().map { ConsoleRow(id: $0.offset, text: $0.element) }
    }

    func tail(_ count: Int) -> [ConsoleRow] {
        guard count > 0 else { return [] }
        let all = rows
        return Array(all.suffix(count))
    }
}

struct ConsoleRow: Identifiable {
    let id: Int
    let text: String
}

enum TerminalKey {
    case up
    case down
    case left
    case right
    case enter
    case tab
    case escape
    case controlC
    case controlD

    var sequence: String {
        switch self {
        case .up: return "\u{1B}[A"
        case .down: return "\u{1B}[B"
        case .right: return "\u{1B}[C"
        case .left: return "\u{1B}[D"
        case .enter: return "\r"
        case .tab: return "\t"
        case .escape: return "\u{1B}"
        case .controlC: return "\u{03}"
        case .controlD: return "\u{04}"
        }
    }
}

struct ANSIParser {
    private enum Mode {
        case idle
        case escape
        case csi
        case osc
    }

    private var mode: Mode = .idle

    var isInsideSequence: Bool {
        mode != .idle
    }

    mutating func begin() {
        mode = .escape
    }

    mutating func feed(_ character: Character) {
        switch mode {
        case .idle:
            return
        case .escape:
            if character == "[" {
                mode = .csi
            } else if character == "]" {
                mode = .osc
            } else {
                mode = .idle
            }
        case .csi:
            if let scalar = character.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
                mode = .idle
            }
        case .osc:
            if character == "\u{07}" || character == "\u{1B}" {
                mode = .idle
            }
        }
    }
}
