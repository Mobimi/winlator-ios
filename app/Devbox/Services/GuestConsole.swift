import Foundation
import Network

struct ConsoleLineBatch: Equatable {
    var items: [String]
    var total: Int
}

final class GuestConsole: ObservableObject {
    static let shared = GuestConsole()

    /// Không `@Published`: mỗi lần gán sẽ copy mảng 2000 dòng và bắn
    /// `objectWillChange` cho mọi view. `displayRevision` là tín hiệu duy
    /// nhất báo nội dung hiển thị đã đổi.
    private(set) var lineBatch = ConsoleLineBatch(items: [], total: 0)
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var lastError: String?
    @Published private(set) var receivedBytes = 0
    /// Chỉ ShellModel đọc (để phát hiện lệnh treo), không view nào hiển thị
    /// trực tiếp — nên không cần publish mỗi lần guest in ra một chunk.
    private(set) var lastActivity = Date.distantPast
    @Published private(set) var connectedAt: Date?
    @Published private(set) var autoRecoveries = 0
    /// Prompt `dev@devbox:~$ ` đã hiện trong guest. Dùng để không gửi lệnh
    /// `cd` khi getty/bash còn đang khởi động.
    @Published private(set) var shellReady = false
    /// Đã từng thấy prompt bash trong phiên này. Khác `shellReady`: khi một
    /// lệnh đang chạy hoặc đang hỏi `(y/n)` thì prompt biến mất, nhưng vẫn
    /// phải cho người dùng gửi câu trả lời vào stdin của lệnh đó.
    @Published private(set) var shellSeen = false
    /// Prompt thật gần nhất. Tách khỏi `currentLine` để `ShellModel` không
    /// phải nhận thông báo cho từng ký tự output.
    @Published private(set) var promptLine = ""
    /// Tăng mỗi lần nội dung hiển thị đổi; view dùng số này thay vì tự
    /// map lại toàn bộ 2000 dòng để kiểm tra thay đổi.
    @Published private(set) var displayRevision = 0

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "devbox.guest.console")
    private var retryTimer: Timer?
    private var serialTimer: Timer?
    private var serialOffset: UInt64 = 0
    private var serialBytes = 0
    private var socketBytes = 0
    private var wantConnection = false
    private var parser = ANSIParser()
    private var pendingCR = false
    private var retryPort: UInt16 = 0
    private var generation = 0
    private var openTries = 0
    private var openFailures = 0
    private var lastSendAt = Date.distantPast
    private var bytesAtSend = 0
    private var lastAutoRecovery = Date.distantPast
    /// Khi socket đã nối, output lấy trực tiếp từ socket. serial.log chỉ
    /// dùng để lấy phần boot trước khi nối và khi socket đứt.
    private var serialDisplay = true
    /// Socket đã nhận byte nào trong lần nối hiện tại chưa. TCP có thể báo
    /// `.ready` trước khi QEMU attach client vào chardev, nên phải xem byte
    /// thật sự mới biết guest có đang đi qua socket hay không.
    private var socketHeard = false
    /// Đã tạm quay lại đọc serial.log vì socket im lặng. Khi socket có byte
    /// đầu tiên thì tắt lại để không hiển thị trùng dòng.
    private var serialFallback = false
    private var utf8Carry: [UInt8] = []
    /// Dòng cuối chưa có `\n`. Cũng không `@Published` vì nó đổi theo từng
    /// ký tự; view chỉ cần thấy nó qua `displayRows`.
    private(set) var currentLine = ""

    var lines: [String] { lineBatch.items }
    var totalLines: Int { lineBatch.total }

    /// Có thể gửi vào stdin: đã thấy prompt bash ít nhất một lần, hoặc đang
    /// đứng ngay ở prompt. Trước khi bash lên (getty/login) thì không gửi.
    var acceptsInput: Bool { connected && (shellReady || shellSeen) }

    private let maxLines = 2000
    private let serialURL = DevboxConfig.serialLogURL
    /// Bản giữ chỗ cho `lineBatch`; chỉ publish một lần mỗi lần đọc thay vì
    /// mỗi dòng, tránh copy mảng 2000 phần tử liên tục.
    private var lineBuffer: [String] = []
    private var lineTotal = 0
    private var linesDirty = false
    /// Cache `ConsoleRow` dựng một lần cho mỗi lần đọc socket. Trước đây view
    /// tự map 2000 dòng mỗi lần render, kể cả khi chỉ có 1 ký tự mới.
    private var displayRows: [ConsoleRow] = []

    private init() {}

    func connect(port: UInt16) {
        wantConnection = true
        retryPort = port
        startSerialWatch()
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
        openFailures = 0
        reopenAfter = .distantPast
        startSerialWatch()
        let qmp = DevboxConfig.qmpPort
        DispatchQueue.global(qos: .userInitiated).async {
            QEMUEngine.trace("console: đang kiểm tra QEMU/serial qua 127.0.0.1:\(qmp)")
            let status = QMPClient.probe(port: qmp, timeout: 3)
            let open = QMPClient.chardevOpen(port: qmp, timeout: 3)
            let disk = QMPClient.diskReadBytes(port: qmp, timeout: 3)
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
            guard !self.connected else { return }
            guard Date() >= self.reopenAfter else { return }
            if let started = self.connectingSince, Date().timeIntervalSince(started) > 6 {
                QEMUEngine.trace("console: kết nối treo quá 6s, tạo lại")
                self.hardClose()
                self.openFailures += 1
                self.reopenAfter = Date().addingTimeInterval(min(30, Double(self.openFailures) * 3))
            }
            if self.connection == nil {
                self.open(port: port)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private var connectingSince: Date?
    private var reopenAfter = Date.distantPast

    private func startSerialWatch() {
        guard serialTimer == nil else { return }
        drainSerial()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            _ = self?.drainSerial()
        }
        RunLoop.main.add(timer, forMode: .common)
        serialTimer = timer
    }

    @discardableResult
    private func drainSerial() -> Bool {
        let url = serialURL
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        if size < serialOffset {
            serialOffset = 0
        }
        guard size > serialOffset else { return false }
        let wanted = min(size - serialOffset, 1 << 18)
        guard (try? handle.seek(toOffset: serialOffset)) != nil else { return false }
        guard let data = try? handle.read(upToCount: Int(wanted)), !data.isEmpty else { return false }
        serialOffset += UInt64(data.count)
        serialBytes += data.count
        if !serialDisplay {
            // Khi socket đang nối, output đi thẳng qua socket. Vẫn đọc file
            // để giữ offset ở cuối, nhưng không hiển thị lần hai.
            //
            // Ngoại lệ: QEMU có thể chưa attach client vào chardev dù TCP đã
            // `.ready`. Nếu socket im lặng >5 giây mà serial vẫn chảy thì
            // guest đang chỉ ghi vào logfile — hiển thị serial để app không
            // "chết" cho tới khi socket thật sự có dữ liệu.
            let silent = !socketHeard
                && Date().timeIntervalSince(connectedAt ?? Date()) > 5
            guard silent else { return true }
            serialFallback = true
            serialDisplay = true
            QEMUEngine.trace("console: socket im lặng >5s, tạm đọc serial.log")
        }
        receivedBytes += data.count
        lastActivity = Date()
        if serialBytes == data.count {
            let sample = String(decoding: data.prefix(160), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
            QEMUEngine.trace("console: serial.log bắt đầu chảy · \"\(sample)\"")
        }
        consumeSanitized(data)
        return true
    }

    /// Đọc hết backlog trước khi chuyển sang socket. serial.log chứa cả phần
    /// guest in ra lúc chưa có client, còn socket chỉ có dữ liệu từ lúc nối.
    private func drainSerialBacklog() {
        for _ in 0..<64 {
            if !drainSerial() { break }
        }
    }

    private func consumeSanitized(_ data: Data) {
        var bytes = utf8Carry
        utf8Carry.removeAll(keepingCapacity: true)
        bytes.reserveCapacity(bytes.count + data.count)
        for byte in data where byte != 0 {
            bytes.append(byte)
        }
        guard !bytes.isEmpty else { return }

        // Giữ lại phần đuôi UTF-8 chưa đủ byte. Nếu không, ký tự nhiều byte
        // bị cắt giữa hai lần đọc 0.25 s sẽ thành ký tự thay thế.
        var cut = bytes.count
        var index = bytes.count - 1
        var continuation = 0
        while index >= 0, (bytes[index] & 0xC0) == 0x80 {
            continuation += 1
            index -= 1
        }
        if index < 0 {
            cut = 0
        } else {
            let lead = bytes[index]
            let expected: Int
            if lead & 0x80 == 0 {
                expected = 1
            } else if lead & 0xE0 == 0xC0 {
                expected = 2
            } else if lead & 0xF0 == 0xE0 {
                expected = 3
            } else if lead & 0xF8 == 0xF0 {
                expected = 4
            } else {
                expected = 1
            }
            if continuation + 1 < expected {
                cut = index
            }
        }
        if cut < bytes.count {
            utf8Carry = Array(bytes[cut...])
        }
        guard cut > 0 else { return }
        consume(String(decoding: bytes[0..<cut], as: UTF8.self))
    }

    private func hardClose() {
        generation += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        parser = ANSIParser()
        pendingCR = false
        utf8Carry = []
        connected = false
        connecting = false
        connectingSince = nil
        lastError = nil
        shellReady = false
        serialDisplay = true
        socketHeard = false
        serialFallback = false
    }

    func disconnect() {
        wantConnection = false
        stopRetryTimer()
        serialTimer?.invalidate()
        serialTimer = nil
        serialDisplay = true
        hardClose()
    }

    func clear() {
        DispatchQueue.main.async {
            self.lineBatch = ConsoleLineBatch(items: [], total: 0)
            self.lineBuffer = []
            self.lineTotal = 0
            self.linesDirty = false
            self.currentLine = ""
            self.displayRows = []
            self.pendingCR = false
            self.parser = ANSIParser()
            self.utf8Carry = []
            self.displayRevision &+= 1
            // Không đụng `shellReady`/`shellSeen`: xoá màn hình chỉ xoá phần
            // đã hiển thị, bash vẫn đang đứng ở prompt và vẫn nhận lệnh được.
        }
    }

    /// Gọi khi QEMU bắt đầu boot mới: serial.log đã bị xoá nên phải bỏ
    /// toàn bộ output của lần boot trước, tránh lẫn dòng và tránh mốc
    /// `totalLines` cũ.
    func resetForNewBoot() {
        DispatchQueue.main.async {
            self.lineBatch = ConsoleLineBatch(items: [], total: 0)
            self.lineBuffer = []
            self.lineTotal = 0
            self.linesDirty = false
            self.currentLine = ""
            self.displayRows = []
            self.parser = ANSIParser()
            self.pendingCR = false
            self.utf8Carry = []
            self.serialOffset = 0
            self.serialBytes = 0
            self.socketBytes = 0
            self.receivedBytes = 0
            self.lastActivity = .distantPast
            self.connectedAt = nil
            self.shellReady = false
            self.shellSeen = false
            self.promptLine = ""
            self.serialDisplay = true
            self.socketHeard = false
            self.serialFallback = false
            self.displayRevision &+= 1
        }
    }

    @discardableResult
    func send(_ text: String, expectReply: Bool = true) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        guard connected else {
            QEMUEngine.trace("console: bỏ qua gửi \(text.count) ký tự vì chưa nối")
            return false
        }
        if expectReply {
            lastSendAt = Date()
            bytesAtSend = receivedBytes
        }
        connection?.send(content: data, completion: .contentProcessed { _ in })
        return true
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
                    // Lấy nốt phần boot đã ghi vào serial.log trước khi
                    // chuyển sang đọc trực tiếp socket.
                    self.serialDisplay = true
                    self.drainSerialBacklog()
                    self.serialDisplay = false
                    // `hardClose()` (dùng khi Nối lại) xoá `shellReady` nhưng
                    // giữ `currentLine`. Nếu prompt vẫn còn ở cuối dòng, tính
                    // lại ngay; nếu không app sẽ chờ prompt mãi dù bash đã sẵn
                    // sàng.
                    self.recomputeReadiness()
                    self.socketHeard = false
                    self.serialFallback = false
                    self.connected = true
                    self.connecting = false
                    self.connectingSince = nil
                    self.lastError = nil
                    self.connectedAt = Date()
                    self.openTries = 0
                    self.openFailures = 0
                    QEMUEngine.trace("console: đã nối 127.0.0.1:\(port)")
                    let qmp = DevboxConfig.qmpPort
                    DispatchQueue.global(qos: .utility).async {
                        let open = QMPClient.chardevOpen(port: qmp, timeout: 2)
                        QEMUEngine.trace("console: QEMU thấy client serial = \(Self.describe(open))")
                    }
                    self.receive(on: candidate, generation: gen)
                }
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
                    if !self.socketHeard {
                        self.socketHeard = true
                        if self.serialFallback {
                            // Đang hiển thị serial để chống im lặng; giờ
                            // socket đã chạy. Không đọc nốt backlog để tránh
                            // lặp dòng (phần chênh lệch chỉ là ~0.25 s).
                            self.serialFallback = false
                            self.serialDisplay = false
                            QEMUEngine.trace("console: socket có dữ liệu, tắt đọc serial.log")
                        }
                        let sample = text.prefix(160).replacingOccurrences(of: "\n", with: " ")
                        QEMUEngine.trace("console: socket trả byte đầu tiên · \"\(sample)\"")
                    }
                    self.socketBytes += data.count
                    self.lastActivity = Date()
                    self.receivedBytes += data.count
                    self.consumeSanitized(data)
                }
            }
            if isComplete || error != nil {
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.connected = false
                    self.connecting = false
                    self.connection = nil
                    self.serialDisplay = true
                    self.drainSerial()
                    QEMUEngine.trace("console: đóng kết nối \(isComplete ? "EOF" : (error?.localizedDescription ?? ""))")
                }
                return
            }
            self.receive(on: connection, generation: gen)
        }
    }

    private func consume(_ text: String) {
        // Giữ dòng hiện tại trong biến cục bộ. Gán `currentLine` mỗi ký tự sẽ
        // publish qua Combine (view và ShellModel cùng nhận) và làm String bị
        // copy liên tục — đây là lý do console lag khi output dày.
        var line = currentLine
        var promptSeen: String?
        for character in text {
            if parser.isInsideSequence {
                parser.feed(character)
                continue
            }
            if pendingCR {
                if character == "\n" {
                    pendingCR = false
                    appendLine(line)
                    line = ""
                    continue
                }
                if character == "\r" {
                    continue
                }
                pendingCR = false
                line = ""
            }
            switch character {
            case "\u{1B}":
                parser.begin()
            case "\r":
                pendingCR = true
            case "\n":
                appendLine(line)
                line = ""
            case "\u{8}":
                if !line.isEmpty {
                    line.removeLast()
                }
            case "\t":
                line += "    "
            default:
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20 {
                    continue
                }
                line.append(character)
            }
            // `hasSuffix` là phép so 2 ký tự; chỉ khi khớp mới quét cả dòng.
            if line.hasSuffix("$ ") || line.hasSuffix("# ") {
                if line.contains("dev@devbox") || line.contains("root@devbox") {
                    promptSeen = line
                }
            }
        }
        if line.count > 4000 {
            line = String(line.suffix(4000))
        }
        let lineChanged = line != currentLine
        if lineChanged {
            currentLine = line
        }
        // Một lần publish cho cả chunk: dòng đã xong + dòng đang gõ. `lineBatch`
        // và `displayRows` phải cập nhật trước khi bump `displayRevision` vì
        // ShellModel đọc `guest.lineBatch` ngay trong sink.
        rebuildRows(lineChanged: lineChanged)
        // Prompt publish sau cùng để ShellModel thấy output trước khi đóng
        // thẻ lệnh, không bị mất dòng cuối.
        applyReadiness(line: line, promptSeen: promptSeen)
    }

    /// Prompt thật: kết thúc bằng `$ `/`# ` và có tên user của image.
    private static func isPrompt(_ line: String) -> Bool {
        guard line.hasSuffix("$ ") || line.hasSuffix("# ") else { return false }
        return line.contains("dev@devbox") || line.contains("root@devbox")
    }

    private func applyReadiness(line: String, promptSeen: String?) {
        if let prompt = promptSeen {
            if !shellSeen {
                shellSeen = true
            }
            if promptLine != prompt {
                promptLine = prompt
            }
        }
        let ready = Self.isPrompt(line)
        if ready != shellReady {
            shellReady = ready
            if ready {
                QEMUEngine.trace("console: prompt guest đã sẵn sàng")
            }
        }
    }

    /// Dùng khi socket vừa nối lại: `currentLine` có thể vẫn còn prompt cũ.
    private func recomputeReadiness() {
        let line = currentLine
        let ready = Self.isPrompt(line)
        if ready {
            shellSeen = true
            // Publish lại để ShellModel đóng thẻ lệnh đang chờ (nó tự bỏ qua
            // nếu thẻ đã `.done`).
            promptLine = line
        }
        if ready != shellReady {
            shellReady = ready
        }
    }

    private func appendLine(_ text: String) {
        lineBuffer.append(text)
        lineTotal += 1
        linesDirty = true
    }

    /// Dựng lại cache dòng hiển thị đúng một lần cho mỗi lần đọc socket.
    /// Trước đây mỗi dòng mới lại copy mảng 2000 phần tử và mỗi ký tự lại
    /// publish, khiến console chậm dần khi output dày.
    private func rebuildRows(lineChanged: Bool) {
        let linesChanged = linesDirty
        if linesChanged {
            linesDirty = false
            if lineBuffer.count > maxLines {
                lineBuffer.removeFirst(lineBuffer.count - maxLines)
            }
            lineBatch = ConsoleLineBatch(items: lineBuffer, total: lineTotal)
        }
        guard linesChanged || lineChanged || displayRows.isEmpty else { return }
        var all = lineBatch.items
        if !currentLine.isEmpty || all.isEmpty {
            all.append(currentLine)
        }
        let base = max(0, lineBatch.total - all.count)
        displayRows = all.enumerated().map {
            ConsoleRow(id: base + $0.offset, text: $0.element)
        }
        displayRevision &+= 1
    }

    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    /// Cache đã dựng sẵn; trả về tham chiếu, không map lại 2000 dòng.
    var rows: [ConsoleRow] { displayRows }

    var rowCount: Int { displayRows.count }

    /// id của dòng cuối đang hiển thị (dùng để cuộn, không cần map cả mảng).
    var lastRowID: Int { displayRows.last?.id ?? 0 }

    func tail(_ count: Int) -> [ConsoleRow] {
        guard count > 0, !displayRows.isEmpty else { return [] }
        return Array(displayRows.suffix(count))
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
        case oscEscape
        case string
        case stringEscape
        case charset
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
            switch character {
            case "[":
                mode = .csi
            case "]":
                mode = .osc
            case "(", ")", "*", "+", "-", ".", "/":
                // ESC ( B, ESC ) 0 … chọn bảng mã; byte sau là tham số.
                mode = .charset
            case "P", "^", "_", "X":
                // DCS / PM / APC / SOS: bỏ tới ST.
                mode = .string
            default:
                mode = .idle
            }
        case .csi:
            if let scalar = character.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
                mode = .idle
            }
        case .osc:
            if character == "\u{07}" {
                mode = .idle
            } else if character == "\u{1B}" {
                mode = .oscEscape
            }
        case .oscEscape:
            mode = character == "\\" ? .idle : .osc
        case .string:
            if character == "\u{1B}" {
                mode = .stringEscape
            }
        case .stringEscape:
            mode = character == "\\" ? .idle : .string
        case .charset:
            mode = .idle
        }
    }
}
