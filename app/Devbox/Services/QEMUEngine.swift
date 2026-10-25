import Foundation
import Darwin

final class QEMUEngine: ObservableObject {
    static let shared = QEMUEngine()

    enum State: Equatable {
        case idle
        case starting
        case running
        case stopped
        case failed(String)

        var isActive: Bool {
            switch self {
            case .starting, .running:
                return true
            default:
                return false
            }
        }

        var text: String {
            switch self {
            case .idle:
                return "Engine chưa chạy"
            case .starting:
                return "Đang khởi động QEMU…"
            case .running:
                return "Linux đang chạy"
            case .stopped:
                return "Linux đã dừng (mở lại app để boot lại)"
            case .failed(let message):
                return message
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastArguments: [String] = []
    @Published private(set) var hasBooted = false
    @Published private(set) var lastStage = "chưa chạy"

    let consolePort = DevboxConfig.consolePort
    let qmpPort = DevboxConfig.qmpPort

    private typealias InitFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias LoopFn = @convention(c) () -> Int32
    private typealias CleanupFn = @convention(c) (Int32) -> Void

    private var thread: Thread?
    private var handle: UnsafeMutableRawPointer?
    private var logURL: URL?
    private var logTimer: Timer?
    private var watchdog: Timer?

    fileprivate static var runningThread: pthread_t?
    fileprivate static var exitCalled = false
    private static var guardInstalled = false

    private static let traceLock = NSLock()
    private static var traceFD: Int32 = -1
    private static let timeBase = ProcessInfo.processInfo.systemUptime
    private static let devboxMapJit: Int32 = 0x0800

    private init() {}

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var canStart: Bool { !hasBooted }

    var uptimeText: String {
        guard let startedAt else { return "—" }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let minutes = seconds / 60
        return minutes > 0 ? "\(minutes) phút (\(seconds % 60)) giây" : "\(seconds) giây"
    }

    func start(image: InstalledImage, cpuCount: Int = 4, memoryMB: Int = 1792) {
        guard !state.isActive, !hasBooted else { return }
        guard let frameworks = Bundle.main.privateFrameworksURL else {
            state = .failed("App không có thư mục Frameworks")
            return
        }
        guard let dylib = Self.findEngine(in: frameworks) else {
            state = .failed("Thiếu engine QEMU trong app (qemu-aarch64-softmmu.framework)")
            return
        }
        guard image.isComplete else {
            state = .failed("Image Debian chưa cài đủ file")
            return
        }

        let share = DevboxConfig.shareDirectory
        try? FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)

        let jit = Self.probeExecMemory()
        logLines = []
        prepareLog()
        guard jit.execOK else {
            Self.trace("exec memory probe failed: \(jit.note)")
            refreshLog()
            state = .failed("iOS không cấp bộ nhớ thực thi cho QEMU: \(jit.note)")
            saveDiagnostics()
            return
        }

        let availableMemory = DeviceProbe.availableMemoryMB()
        let memory = Self.budgetMemory(requested: memoryMB, available: availableMemory)
        let arguments = buildArguments(image: image, share: share, cpuCount: cpuCount, memoryMB: memory, tbSize: jit.tbSize)
        lastArguments = arguments
        hasBooted = true
        state = .starting
        startedAt = Date()
        Self.exitCalled = false

        Self.trace("=== start ===")
        Self.trace("app: \(Bundle.main.bundlePath)")
        Self.trace("engine: \(dylib.path)")
        Self.trace("engine exists=\(FileManager.default.fileExists(atPath: dylib.path)) size=\(Self.fileSize(dylib))")
        Self.trace("frameworks: \(Self.frameworkNames(in: frameworks).joined(separator: ", "))")
        Self.trace("jit: \(DeviceProbe.jitState().title) debugged=\(DeviceProbe.isDebugged())")
        Self.trace("exec memory: \(jit.note)")
        Self.trace("memory: available=\(availableMemory) MB requested=\(memoryMB) MB using=\(memory) MB footprint=\(DeviceProbe.footprintMB()) MB")
        Self.trace("share: \(share.path)")
        Self.trace("args: \(arguments.joined(separator: " "))")

        installExitGuard()

        stage("tạo thread QEMU")
        let worker = Thread { [weak self] in
            self?.run(dylib: dylib, arguments: arguments)
        }
        worker.name = "devbox-qemu"
        worker.stackSize = 8 << 20
        worker.qualityOfService = .userInteractive
        thread = worker
        worker.start()
        startLogTimer()
        startWatchdog()
    }

    func stop() {
        guard state.isActive else { return }
        let port = qmpPort
        Self.trace("stop requested")
        DispatchQueue.global(qos: .userInitiated).async {
            QMPClient.quit(port: port, timeout: 4)
        }
    }

    func refreshLog() {
        guard let logURL, let data = try? Data(contentsOf: logURL) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        logLines = Array(lines.suffix(400))
    }

    func persistedLog() -> String {
        guard let logURL, let data = try? Data(contentsOf: logURL) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    var logFileURL: URL { DevboxConfig.qemuLogURL }

    func ensureLogFile() -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: DevboxConfig.logsDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: DevboxConfig.qemuLogURL.path) {
            fm.createFile(atPath: DevboxConfig.qemuLogURL.path, contents: nil)
        }
        return DevboxConfig.qemuLogURL
    }

    @discardableResult
    func saveDiagnostics() -> URL? {
        Diagnostics.write()
    }

    func preflight() -> String {
        var lines: [String] = []
        lines.append("== Kiểm tra engine ==")
        lines.append("App: \(Bundle.main.bundlePath)")
        guard let frameworks = Bundle.main.privateFrameworksURL else {
            lines.append("Frameworks: KHÔNG CÓ")
            return lines.joined(separator: "\n")
        }
        let names = Self.frameworkNames(in: frameworks)
        lines.append("Frameworks (\(names.count)): \(names.joined(separator: ", "))")

        guard let dylib = Self.findEngine(in: frameworks) else {
            lines.append("Engine: KHÔNG TÌM THẤY (qemu-aarch64-softmmu.framework)")
            return lines.joined(separator: "\n")
        }
        lines.append("Engine: \(dylib.lastPathComponent)")
        lines.append("Kích thước: \(Self.fileSize(dylib)) byte")

        var missing: [String] = []
        for name in names {
            let path = frameworks.appendingPathComponent(name).appendingPathComponent(String(name.dropLast(".framework".count))).path
            if !FileManager.default.fileExists(atPath: path) {
                missing.append(name)
            }
        }
        lines.append("Framework thiếu binary: \(missing.isEmpty ? "không" : missing.joined(separator: ", "))")

        errno = 0
        if let open = dlopen(dylib.path, RTLD_NOW | RTLD_LOCAL) {
            lines.append("dlopen: OK")
            for symbol in ["qemu_init", "qemu_main_loop", "qemu_cleanup"] {
                lines.append("dlsym \(symbol): \(dlsym(open, symbol) == nil ? "THIẾU" : "OK")")
            }
        } else {
            let message = dlerror().map { String(cString: $0) } ?? "không rõ"
            lines.append("dlopen: LỖI")
            lines.append("  \(message)")
        }

        lines.append("JIT: \(DeviceProbe.jitState().title) · CS_DEBUGGED=\(DeviceProbe.isDebugged())")
        lines.append("RAM còn dùng được: \(DeviceProbe.availableMemoryMB()) MB · app đang dùng \(DeviceProbe.footprintMB()) MB")
        lines.append(contentsOf: Self.codeMemoryTest())
        lines.append("Engine state: \(state.text)")
        lines.append("Bước cuối: \(lastStage)")
        if Self.exitCalled {
            lines.append("QEMU đã gọi exit() ở lần boot trước")
        }
        let log = persistedLog()
        lines.append("== qemu.log (\(log.utf8.count) byte) ==")
        lines.append(log.isEmpty ? "(trống)" : log)
        return lines.joined(separator: "\n")
    }

    private func buildArguments(image: InstalledImage, share: URL, cpuCount: Int, memoryMB: Int, tbSize: Int) -> [String] {
        var args: [String] = ["qemu-system-aarch64"]
        args += ["-M", "virt,highmem=on"]
        args += ["-cpu", "max"]
        args += ["-smp", "\(cpuCount)"]
        args += ["-m", "\(memoryMB)"]
        args += ["-accel", "tcg,thread=multi,tb-size=\(tbSize)"]
        args += ["-rtc", "base=utc,clock=host"]
        args += ["-kernel", image.kernel.path]
        args += ["-initrd", image.initrd.path]
        args += ["-append", "console=ttyAMA0 root=/dev/vda rw loglevel=4 net.ifnames=0"]
        args += ["-drive", "if=virtio,format=raw,cache=writeback,file=\(image.rootfs.path)"]
        args += ["-virtfs", "local,path=\(share.path),mount_tag=share,security_model=none,multidevs=remap"]
        args += ["-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080,hostfwd=tcp:127.0.0.1:3000-:3000,hostfwd=tcp:127.0.0.1:5173-:5173"]
        args += ["-device", "virtio-net-pci,netdev=n0"]
        args += ["-object", "rng-random,filename=/dev/urandom,id=rng0"]
        args += ["-device", "virtio-rng-pci,rng=rng0"]
        args += ["-chardev", "socket,id=con,host=127.0.0.1,port=\(consolePort),server=on,wait=off"]
        args += ["-serial", "chardev:con"]
        args += ["-qmp", "tcp:127.0.0.1:\(qmpPort),server=on,wait=off"]
        args += ["-display", "none"]
        args += ["-nodefaults"]
        args += ["-no-user-config"]
        args += ["-name", "devbox"]
        return args
    }

    private func run(dylib: URL, arguments: [String]) {
        QEMUEngine.runningThread = pthread_self()
        QEMUEngine.trace("thread start")

        let logPath = logURL?.path ?? "/dev/null"
        errno = 0
        let logFD = open(logPath, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        if logFD >= 0 {
            dup2(logFD, STDOUT_FILENO)
            dup2(logFD, STDERR_FILENO)
            if logFD > STDERR_FILENO {
                close(logFD)
            }
        } else {
            QEMUEngine.trace("open log failed errno=\(errno)")
        }
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        signal(SIGPIPE, SIG_IGN)
        QEMUEngine.trace("fd 1/2 -> \(logPath)")

        stage("dlopen engine")
        errno = 0
        guard let open = dlopen(dylib.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "dlopen thất bại errno \(errno)"
            QEMUEngine.trace("dlopen FAILED: \(message)")
            fail("dlopen lỗi: \(message)")
            return
        }
        handle = open
        QEMUEngine.trace("dlopen OK")

        stage("tìm symbol")
        guard let initSym = dlsym(open, "qemu_init"),
              let loopSym = dlsym(open, "qemu_main_loop"),
              let cleanupSym = dlsym(open, "qemu_cleanup") else {
            QEMUEngine.trace("dlsym FAILED")
            fail("Thiếu symbol qemu_init/qemu_main_loop/qemu_cleanup")
            return
        }
        QEMUEngine.trace("dlsym OK")

        let initFn = unsafeBitCast(initSym, to: InitFn.self)
        let loopFn = unsafeBitCast(loopSym, to: LoopFn.self)
        let cleanupFn = unsafeBitCast(cleanupSym, to: CleanupFn.self)

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer {
            for pointer in argv {
                if let pointer {
                    free(UnsafeMutableRawPointer(pointer))
                }
            }
        }

        stage("gọi qemu_init")
        QEMUEngine.trace("qemu_init begin")
        initFn(Int32(arguments.count), &argv)
        QEMUEngine.trace("qemu_init returned")
        stage("qemu_init xong, chờ main loop")

        DispatchQueue.main.async {
            QEMUEngine.trace("main: state -> running")
            self.stopWatchdog()
            if self.state == .starting {
                self.state = .running
                self.startedAt = Date()
            }
        }

        stage("main loop chạy")
        QEMUEngine.trace("qemu_main_loop begin")
        let status = loopFn()
        QEMUEngine.trace("qemu_main_loop returned \(status)")
        stage("main loop trả về \(status)")

        cleanupFn(status)
        QEMUEngine.trace("qemu_cleanup done")

        dlclose(open)
        handle = nil
        QEMUEngine.trace("thread end")

        DispatchQueue.main.async {
            self.stopLogTimer()
            self.refreshLog()
            if case .failed = self.state {
                return
            }
            self.state = .stopped
        }
    }

    private func fail(_ message: String) {
        QEMUEngine.trace("FAIL: \(message)")
        DispatchQueue.main.async {
            self.stopLogTimer()
            self.refreshLog()
            if self.logLines.isEmpty {
                self.logLines = [message]
            }
            self.state = .failed(message)
            self.saveDiagnostics()
        }
    }

    private func stage(_ text: String) {
        QEMUEngine.trace("stage: \(text)")
        DispatchQueue.main.async {
            self.lastStage = text
        }
    }

    private func prepareLog() {
        let fm = FileManager.default
        let directory = DevboxConfig.logsDirectory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = DevboxConfig.qemuLogURL
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            let previous = directory.appendingPathComponent("qemu-previous.log")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
        }
        fm.createFile(atPath: url.path, contents: nil)
        logURL = url
        QEMUEngine.openTrace(url: url)
    }

    private func startLogTimer() {
        stopLogTimer()
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.refreshLog()
        }
        RunLoop.main.add(timer, forMode: .common)
        logTimer = timer
    }

    private func stopLogTimer() {
        logTimer?.invalidate()
        logTimer = nil
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 90, repeats: false) { [weak self] _ in
            guard let self, self.state == .starting else { return }
            self.refreshLog()
            let jit = DeviceProbe.jitState().title
            if QEMUEngine.exitCalled {
                self.state = .failed("QEMU gọi exit() khi khởi động (JIT: \(jit)). Bước cuối: \(self.lastStage). Copy log để xem lý do.")
            } else {
                self.state = .failed("QEMU chưa vào main loop sau 90 giây (JIT: \(jit)). Bước cuối: \(self.lastStage). Copy log để xem.")
            }
            self.stopLogTimer()
            self.saveDiagnostics()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func installExitGuard() {
        guard !Self.guardInstalled else { return }
        Self.guardInstalled = true
        atexit(devboxExitGuard)
    }

    private static func findEngine(in frameworks: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else {
            return nil
        }
        for item in items where item.hasSuffix(".framework") {
            let name = String(item.dropLast(".framework".count))
            guard name.hasPrefix("qemu-") else { continue }
            let candidate = frameworks.appendingPathComponent("\(item)/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func frameworkNames(in frameworks: URL) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return items.filter { $0.hasSuffix(".framework") }.sorted()
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    private static func budgetMemory(requested: Int, available: Int) -> Int {
        guard available > 0 else { return requested }
        let cap = max(768, available - 700)
        return min(requested, cap)
    }

    private struct ExecProbe {
        var execOK: Bool
        var tbSize: Int
        var note: String
    }

    private static func mapMemory(_ bytes: Int, protection: Int32, flags: Int32 = MAP_PRIVATE | MAP_ANONYMOUS) -> (pointer: UnsafeMutableRawPointer?, code: Int32) {
        errno = 0
        let pointer = mmap(nil, bytes, protection, flags, -1, 0)
        let code = errno
        if let pointer, UInt(bitPattern: pointer) != UInt.max {
            return (pointer, 0)
        }
        return (nil, code == 0 ? EPERM : code)
    }

    private static func probeExecMemory() -> ExecProbe {
        var failures: [String] = []
        for megabytes in [256, 192, 128, 64, 32, 16] {
            let bytes = megabytes << 20
            let mapping = mapMemory(bytes, protection: PROT_READ | PROT_WRITE | PROT_EXEC)
            if let pointer = mapping.pointer {
                munmap(pointer, bytes)
                let tb = min(megabytes, 256)
                let note = failures.isEmpty
                    ? "RWX \(megabytes) MB OK · tb-size=\(tb)"
                    : "RWX \(megabytes) MB OK · tb-size=\(tb) · bị chặn: \(failures.joined(separator: ", "))"
                return ExecProbe(execOK: true, tbSize: tb, note: note)
            }
            failures.append("\(megabytes) MB errno \(mapping.code)")
        }

        let reclaim = mapMemory(16 << 20, protection: PROT_READ | PROT_WRITE)
        if let pointer = reclaim.pointer {
            errno = 0
            let result = mprotect(pointer, 16 << 20, PROT_READ | PROT_EXEC)
            let protectErrno = errno
            munmap(pointer, 16 << 20)
            let extra = result == 0 ? "mprotect RX được nhưng QEMU cần mmap RWX ngay từ đầu" : "mprotect RX errno \(protectErrno)"
            return ExecProbe(execOK: false, tbSize: 0, note: "mmap RWX bị chặn (\(failures.joined(separator: ", "))) · \(extra)")
        }

        return ExecProbe(execOK: false, tbSize: 0, note: "mmap RWX bị chặn: \(failures.joined(separator: ", "))")
    }

    private static func codeMemoryTest() -> [String] {
        var lines: [String] = []

        let small = mapMemory(16 << 20, protection: PROT_READ | PROT_WRITE | PROT_EXEC)
        if let pointer = small.pointer {
            lines.append("mmap 16 MB RWX: OK")
            munmap(pointer, 16 << 20)
        } else {
            lines.append("mmap 16 MB RWX: LỖI errno \(small.code) (\(String(cString: strerror(small.code))))")
        }

        let big = mapMemory(256 << 20, protection: PROT_READ | PROT_WRITE | PROT_EXEC)
        if let pointer = big.pointer {
            lines.append("mmap 256 MB RWX: OK (đủ cho tb-size=256)")
            munmap(pointer, 256 << 20)
        } else {
            lines.append("mmap 256 MB RWX: LỖI errno \(big.code) (\(String(cString: strerror(big.code))))")
        }

        let reclaim = mapMemory(16 << 20, protection: PROT_READ | PROT_WRITE)
        if let pointer = reclaim.pointer {
            errno = 0
            if mprotect(pointer, 16 << 20, PROT_READ | PROT_EXEC) == 0 {
                lines.append("mprotect RW → RX: OK")
            } else {
                lines.append("mprotect RW → RX: LỖI errno \(errno) (\(String(cString: strerror(errno))))")
            }
            munmap(pointer, 16 << 20)
        } else {
            lines.append("mmap 16 MB RW: LỖI errno \(reclaim.code)")
        }

        let reserved = mapMemory(32 << 20, protection: PROT_NONE, flags: MAP_PRIVATE | MAP_ANONYMOUS | devboxMapJit)
        if let pointer = reserved.pointer {
            lines.append("mmap PROT_NONE + MAP_JIT: OK")
            munmap(pointer, 32 << 20)
        } else {
            lines.append("mmap PROT_NONE + MAP_JIT: LỖI errno \(reserved.code) — QEMU bản cũ dùng cờ này nên bị chặn")
        }

        lines.append("Chọn: \(probeExecMemory().note)")
        return lines
    }

    fileprivate static func openTrace(url: URL) {
        traceLock.lock()
        defer { traceLock.unlock() }
        if traceFD >= 0 {
            close(traceFD)
        }
        traceFD = open(url.path, O_CREAT | O_WRONLY | O_APPEND, 0o644)
    }

    fileprivate static func trace(_ message: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - timeBase
        traceLock.lock()
        defer { traceLock.unlock() }
        guard traceFD >= 0 else { return }
        let line = "[t+\(String(format: "%.2f", elapsed))] \(message)\n"
        let bytes = Array(line.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(traceFD, base, buffer.count)
        }
    }
}

private func devboxExitGuard() {
    QEMUEngine.exitCalled = true
    fflush(stdout)
    fflush(stderr)
    guard let running = QEMUEngine.runningThread else {
        QEMUEngine.trace("atexit guard: no qemu thread")
        return
    }
    if pthread_equal(pthread_self(), running) != 0 {
        QEMUEngine.trace("atexit guard: exit() called on qemu thread -> pthread_exit")
        pthread_exit(nil)
    }
    QEMUEngine.trace("atexit guard: exit() called on other thread")
}
