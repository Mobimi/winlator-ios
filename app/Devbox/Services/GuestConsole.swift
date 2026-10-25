import Foundation
import Network

final class GuestConsole: ObservableObject {
    static let shared = GuestConsole()

    @Published private(set) var lines: [String] = []
    @Published private(set) var connected = false
    @Published private(set) var lastError: String?
    @Published private(set) var receivedBytes = 0

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "devbox.guest.console")
    private var retryTimer: Timer?
    private var wantConnection = false
    private var parser = ANSIParser()
    @Published private var currentLine = ""

    private let maxLines = 2000

    private init() {}

    func connect(port: UInt16) {
        wantConnection = true
        if connection != nil {
            startRetryTimer(port: port)
            return
        }
        open(port: port)
        startRetryTimer(port: port)
    }

    private func startRetryTimer(port: UInt16) {
        stopRetryTimer()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.wantConnection, !self.connected else { return }
            self.open(port: port)
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    func disconnect() {
        wantConnection = false
        stopRetryTimer()
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async {
            self.connected = false
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.lines = []
            self.currentLine = ""
        }
    }

    func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func sendControl(_ code: UInt8) {
        send(String(Character(Unicode.Scalar(code))))
    }

    func sendKey(_ key: TerminalKey) {
        send(key.sequence)
    }

    private func open(port: UInt16) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        connection?.cancel()
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.connected = true
                    self.lastError = nil
                }
                self.receive(on: connection)
            case .failed(let error):
                DispatchQueue.main.async {
                    self.connected = false
                    self.lastError = error.localizedDescription
                }
                connection.cancel()
            case .cancelled:
                DispatchQueue.main.async {
                    self.connected = false
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    self.receivedBytes += data.count
                    self.consume(text)
                }
            }
            if isComplete || error != nil {
                DispatchQueue.main.async {
                    self.connected = false
                }
                return
            }
            self.receive(on: connection)
        }
    }

    private func consume(_ text: String) {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if parser.isInsideSequence {
                parser.feed(character)
                continue
            }
            switch character {
            case "\u{1B}":
                parser.begin()
            case "\r":
                if index < characters.count, characters[index] == "\n" {
                    index += 1
                    lines.append(currentLine)
                    currentLine = ""
                    if lines.count > maxLines {
                        lines.removeFirst(lines.count - maxLines)
                    }
                } else {
                    currentLine = ""
                }
            case "\n":
                lines.append(currentLine)
                currentLine = ""
                if lines.count > maxLines {
                    lines.removeFirst(lines.count - maxLines)
                }
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
