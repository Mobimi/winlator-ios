import Foundation
import Darwin
import CryptoKit

@_silgen_name("mach_vm_remap")
private func devbox_mach_vm_remap(
    _ targetTask: vm_map_t,
    _ targetAddress: UnsafeMutablePointer<mach_vm_address_t>?,
    _ size: mach_vm_size_t,
    _ mask: mach_vm_offset_t,
    _ flags: Int32,
    _ srcTask: vm_map_t,
    _ srcAddress: mach_vm_address_t,
    _ copy: boolean_t,
    _ curProtection: UnsafeMutablePointer<vm_prot_t>?,
    _ maxProtection: UnsafeMutablePointer<vm_prot_t>?,
    _ inheritance: vm_inherit_t
) -> kern_return_t


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
    @Published private(set) var guestBooted = false
    @Published private(set) var guestAliveAt: Date?
    @Published private(set) var lastStage = "chưa chạy"
    @Published private(set) var execNote = ""

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
    private var bootMonitor: Timer?
    private var probeEarlyDone = false
    private var probeLateDone = false
    private static var lastPC = "?"

    fileprivate static var runningThread: pthread_t?
    fileprivate static var exitCalled = false
    private static var guardInstalled = false

    private static let traceLock = NSLock()
    private static var traceFD: Int32 = -1
    private static let timeBase = ProcessInfo.processInfo.systemUptime
    private static let devboxMapJit: Int32 = 0x0800

    static let engineMode = "TCG + split-wx (cần JIT)"
    static let engineNeedsJIT = true

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

        logLines = []
        prepareLog()
        GuestConsole.shared.resetForNewBoot()
        Self.trace("=== start ===")
        errno = 0

        let jit = DeviceProbe.jitState()
        let debugged = DeviceProbe.isDebugged()
        Self.trace("engine mode: \(Self.engineMode) needsJIT=\(Self.engineNeedsJIT) jit=\(jit.title) debugged=\(debugged)")

        if Self.engineNeedsJIT {
            if case .denied = jit {
                Self.trace("jit denied: CS_DEBUGGED chưa bật")
                refreshLog()
                state = .failed("Chưa bật JIT (CS_DEBUGGED). Mở StikDebug → Enable JIT cho Devbox, rồi mở lại app.")
                saveDiagnostics()
                return
            }
        }

        // UTM's path for sideloaded apps: RW anonymous mapping + RX alias via
        // mach_vm_remap + mprotect(RX). No MAP_JIT, no dynamic-codesigning.
        let split = Self.splitWXProbe()
        let mapJIT = split.execOK ? nil : Self.mapJITProbe()
        let tbSize: Int
        let splitWX: Bool
        if split.execOK {
            tbSize = split.tbSize
            splitWX = true
            execNote = split.note
            Self.trace("codegen: \(split.note)")
        } else if let mapJIT, mapJIT.ok {
            tbSize = mapJIT.tbSize
            splitWX = false
            execNote = "\(split.note) · \(mapJIT.note)"
            Self.trace("codegen: MAP_JIT fallback · \(mapJIT.note)")
        } else {
            let fallback = mapJIT?.note ?? "MAP_JIT không thử"
            execNote = "\(split.note) · \(fallback)"
            Self.trace("codegen failed: \(execNote)")
            refreshLog()
            state = .failed("Không tạo được vùng code TCG. \(split.note). \(fallback). Kiểm tra lại JIT (StikDebug) rồi thử lại.")
            saveDiagnostics()
            return
        }

        let availableMemory = DeviceProbe.availableMemoryMB()
        let memory = Self.budgetMemory(requested: memoryMB, available: availableMemory)
        let arguments = buildArguments(image: image, share: share, cpuCount: cpuCount, memoryMB: memory, tbSize: tbSize, splitWX: splitWX)
        lastArguments = arguments
        hasBooted = true
        state = .starting
        startedAt = Date()
        Self.exitCalled = false
        IdleTimer.hold("engine", true)

        Self.trace("app: \(Bundle.main.bundlePath)")
        Self.trace("engine: \(dylib.path)")
        Self.trace("engine exists=\(FileManager.default.fileExists(atPath: dylib.path)) size=\(Self.fileSize(dylib)) sha256=\(Self.fileDigest(dylib))")
        Self.trace("frameworks: \(Self.frameworkNames(in: frameworks).joined(separator: ", "))")
        Self.trace("jit: \(DeviceProbe.jitState().title) debugged=\(DeviceProbe.isDebugged())")
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
        startBootMonitor()
    }

    func stop() {
        guard state.isActive else { return }
        let port = qmpPort
        Self.trace("stop requested")
        stage("đang dừng QEMU")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // QEMU có thể chưa mở cổng QMP khi state còn .starting. Thử lại
            // đến khi main loop thoát (run() đặt .stopped) hoặc hết 15 s.
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                var active = true
                DispatchQueue.main.sync {
                    active = self?.state.isActive ?? false
                }
                if !active { return }
                QMPClient.quit(port: port, timeout: 2)
                Thread.sleep(forTimeInterval: 0.8)
            }
            QEMUEngine.trace("stop: QMP quit không làm QEMU thoát sau 15s")
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
        lines.append("Engine mode: \(Self.engineMode) · needsJIT=\(Self.engineNeedsJIT)")
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

        let debugged = DeviceProbe.isDebugged()
        lines.append("JIT (bắt buộc): \(DeviceProbe.jitState().title) · CS_DEBUGGED=\(debugged)")
        lines.append("P_TRACED: \(DeviceProbe.traceInfo().note) · chỉ CÓ khi debugger còn attach")
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
        let serial = (try? String(contentsOf: DevboxConfig.serialLogURL, encoding: .utf8)) ?? ""
        lines.append("== serial.log (\(serial.utf8.count) byte) ==")
        lines.append(serial.isEmpty ? "(trống)" : String(serial.suffix(3000)))
        return lines.joined(separator: "\n")
    }

    private func buildArguments(image: InstalledImage, share: URL, cpuCount: Int, memoryMB: Int, tbSize: Int, splitWX: Bool) -> [String] {
        let stored = UserDefaults.standard.object(forKey: "devbox.singleCPU") as? Bool
        let single = stored ?? true
        let cpus = single ? 1 : cpuCount
        var args: [String] = ["qemu-system-aarch64"]
        args += ["-M", "virt,highmem=on"]
        args += ["-cpu", "max"]
        args += ["-smp", "\(cpus)"]
        args += ["-m", "\(memoryMB)"]
        let accel = "tcg,thread=\(single ? "single" : "multi"),tb-size=\(tbSize)" + (splitWX ? ",split-wx=on" : "")
        args += ["-accel", accel]
        args += ["-rtc", "base=utc,clock=host"]
        args += ["-kernel", image.kernel.path]
        args += ["-initrd", image.initrd.path]
        args += ["-append", "console=ttyAMA0 root=/dev/vda rw loglevel=4 net.ifnames=0"]
        args += ["-drive", "if=virtio,format=raw,cache=writeback,file=\(image.rootfs.path)"]
        args += ["-virtfs", "local,path=\(share.path),mount_tag=share,security_model=none,multidevs=remap"]
        let forwarded = DevboxConfig.forwardedHostPorts
        let forwards = forwarded.map { "hostfwd=tcp:127.0.0.1:\($0)-:\($0 == 2222 ? 22 : $0)" }.joined(separator: ",")
        args += ["-netdev", "user,id=n0,\(forwards)"]
        args += ["-device", "virtio-net-pci,netdev=n0,romfile="]
        args += ["-object", "rng-random,filename=/dev/urandom,id=rng0"]
        args += ["-device", "virtio-rng-pci,rng=rng0"]
        args += ["-chardev", "socket,id=con,host=127.0.0.1,port=\(consolePort),server=on,wait=off,logfile=\(DevboxConfig.serialLogURL.path)"]
        args += ["-serial", "chardev:con"]
        args += ["-qmp", "tcp:127.0.0.1:\(qmpPort),server=on,wait=off"]
        args += ["-d", "guest_errors"]
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
            self.finishRun()
        }
    }

    /// Dọn trạng thái chỉ có ý nghĩa khi QEMU còn chạy: mốc `.ports` (để
    /// PortWatcher không hiện cổng cũ), boot monitor và cờ giữ màn hình sáng.
    private func finishRun() {
        stopBootMonitor()
        guestBooted = false
        guestAliveAt = nil
        try? FileManager.default.removeItem(at: DevboxConfig.shareDirectory.appendingPathComponent(".ports"))
        IdleTimer.hold("engine", false)
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
            self.finishRun()
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
        try? fm.removeItem(at: DevboxConfig.serialLogURL)
        // Xoá mốc .ports của lần boot trước; nếu không, guestBooted có thể
        // bật ngay từ mtime cũ trước khi guest thật sự chạy portwatch.
        try? fm.removeItem(at: DevboxConfig.shareDirectory.appendingPathComponent(".ports"))
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

    private func startBootMonitor() {
        stopBootMonitor()
        guestBooted = false
        guestAliveAt = nil
        probeEarlyDone = false
        probeLateDone = false
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.state == .running else { return }
            let marker = DevboxConfig.shareDirectory.appendingPathComponent(".ports")
            if let values = try? marker.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate,
               modified >= (self.startedAt ?? .distantPast) {
                self.guestAliveAt = modified
                if !self.guestBooted {
                    self.guestBooted = true
                    let seconds = Int(Date().timeIntervalSince(self.startedAt ?? Date()))
                    Self.trace("guest: đã boot (thấy /mnt/share/.ports sau \(seconds)s)")
                }
            }
            self.guestProbe()
        }
        RunLoop.main.add(timer, forMode: .common)
        bootMonitor = timer
    }

    private func guestProbe() {
        let age = Date().timeIntervalSince(startedAt ?? Date())
        guard age > 20 else { return }
        let late = age > 90
        if probeEarlyDone && (!late || probeLateDone) { return }
        if late {
            probeLateDone = true
        } else {
            probeEarlyDone = true
        }
        let qmp = qmpPort
        let rootfs = InstalledImage.load()?.rootfs
        DispatchQueue.global(qos: .utility).async {
            let status = QMPClient.probe(port: qmp, timeout: 3)
            let registers = QMPClient.hmp("info registers", port: qmp, timeout: 3) ?? ""
            let cpuStatus = (QMPClient.hmp("info status", port: qmp, timeout: 3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cpus = (QMPClient.hmp("info cpus", port: qmp, timeout: 3) ?? "").split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.joined(separator: " | ")
            let jit = (QMPClient.hmp("info jit", port: qmp, timeout: 3) ?? "").split(separator: "\n").first.map(String.init) ?? ""
            let open = QMPClient.chardevOpen(port: qmp, timeout: 3)
            let disk = QMPClient.diskReadBytes(port: qmp, timeout: 3)
            let diskText = disk.map { "\($0) B" } ?? "?"
            let pc = QEMUEngine.pcValue(registers)
            let previous = QEMUEngine.lastPC
            QEMUEngine.lastPC = pc
            let instructions = pc == "?" ? "" : (QMPClient.hmp("xp /6i \(pc)", port: qmp, timeout: 3) ?? "")
            let kernelHead = QMPClient.hmp("xp /16wx 0x40000000", port: qmp, timeout: 3) ?? ""
            let mtime = rootfs.flatMap { url -> String? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let date = values?.contentModificationDate else { return nil }
                return String(format: "%.0f", date.timeIntervalSince1970)
            } ?? "?"
            QEMUEngine.trace("guest: t+\(Int(age))s · qmp=\(status) · \(cpuStatus) · pc=\(pc) (trước \(previous)) · đĩa đọc=\(diskText) · serial=\(QEMUEngine.describe(open)) · tb=\(jit) · rootfs_mtime=\(mtime)")
            QEMUEngine.trace("cpus: \(String(cpus.prefix(400)))")
            QEMUEngine.trace("mã tại pc: \(String(instructions.replacingOccurrences(of: "\n", with: " | ").prefix(300)))")
            QEMUEngine.trace("ram 0x40000000: \(String(kernelHead.replacingOccurrences(of: "\n", with: " | ").prefix(300)))")
            guard late else { return }
            let rawChardev = QMPClient.raw("{\"execute\":\"query-chardev\"}", port: qmp, timeout: 3)
            let rawBlock = QMPClient.raw("{\"execute\":\"query-blockstats\"}", port: qmp, timeout: 3)
            QEMUEngine.trace("qmp raw chardev: \(String(rawChardev.prefix(400)))")
            QEMUEngine.trace("qmp raw blockstats: \(String(rawBlock.prefix(400)))")
            let head = registers.split(separator: "\n").prefix(4).joined(separator: " | ")
            QEMUEngine.trace("qmp registers: \(String(head.prefix(600)))")
        }
    }

    private static func describe(_ value: Bool?) -> String {
        guard let value else { return "?" }
        return value ? "có client" : "không client"
    }

    private static func pcValue(_ registers: String) -> String {
        guard let range = registers.range(of: "PC=") else { return "?" }
        let tail = registers[range.upperBound...]
        let digits = tail.prefix { $0.isHexDigit }
        return digits.isEmpty ? "?" : "0x" + String(digits)
    }

    private func stopBootMonitor() {
        bootMonitor?.invalidate()
        bootMonitor = nil
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
            self.finishRun()
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

    private static func fileDigest(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "-" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try? handle.read(upToCount: 1 << 20)
            guard let data = chunk ?? nil, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
                let write = writeCodeTest(pointer)
                munmap(pointer, bytes)
                let tb = min(megabytes, 256)
                let note = failures.isEmpty
                    ? "RWX \(megabytes) MB OK · tb-size=\(tb) · \(write)"
                    : "RWX \(megabytes) MB OK · tb-size=\(tb) · \(write) · bị chặn: \(failures.joined(separator: ", "))"
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

    // QEMU TCG on iOS without dynamic-codesigning: one RW mapping for writes and a
    // second RX alias of the same pages for execution (tcg/region.c split-wx).
    private static func splitWXProbe() -> ExecProbe {
        var failures: [String] = []
        for megabytes in [256, 192, 128, 64, 32, 16] {
            let bytes = megabytes << 20
            let rwMap = mapMemory(bytes, protection: PROT_READ | PROT_WRITE)
            guard let rw = rwMap.pointer else {
                failures.append("\(megabytes) MB RW errno \(rwMap.code)")
                continue
            }

            var rxAddress: mach_vm_address_t = 0
            var current: vm_prot_t = 0
            var maximum: vm_prot_t = 0
            let remap = devbox_mach_vm_remap(
                mach_task_self_,
                &rxAddress,
                mach_vm_size_t(bytes),
                0,
                VM_FLAGS_ANYWHERE,
                mach_task_self_,
                mach_vm_address_t(UInt(bitPattern: rw)),
                0,
                &current,
                &maximum,
                vm_inherit_t(VM_INHERIT_NONE)
            )
            guard remap == KERN_SUCCESS, let rx = UnsafeMutableRawPointer(bitPattern: UInt(rxAddress)) else {
                munmap(rw, bytes)
                failures.append("\(megabytes) MB remap kr=\(remap)")
                continue
            }

            errno = 0
            let protected = mprotect(rx, bytes, PROT_READ | PROT_EXEC)
            let protectErrno = errno
            if protected != 0 {
                munmap(rx, bytes)
                munmap(rw, bytes)
                failures.append("\(megabytes) MB mprotect RX errno \(protectErrno)")
                continue
            }

            let write = writeCodeTest(rw)
            let mirrored = rx.load(as: UInt32.self) == 0x52800540
            munmap(rx, bytes)
            munmap(rw, bytes)

            let mirror = mirrored ? "alias RX thấy mã vừa ghi" : "alias RX KHÔNG thấy mã vừa ghi"
            let tail = failures.isEmpty ? "" : " · trước đó: \(failures.joined(separator: ", "))"
            let note = "split-wx \(megabytes) MB OK · tb-size=\(megabytes) · \(write) · \(mirror)\(tail)"
            trace("split-wx: \(note)")
            return ExecProbe(execOK: mirrored, tbSize: megabytes, note: note)
        }

        let text = "split-wx bị chặn: \(failures.joined(separator: ", "))"
        trace("split-wx: \(text)")
        return ExecProbe(execOK: false, tbSize: 0, note: text)
    }

    static func mapJITProbe() -> (ok: Bool, tbSize: Int, note: String) {
        var failures: [String] = []
        for megabytes in [256, 128, 64, 32, 16] {
            let bytes = megabytes << 20

            let direct = mapMemory(bytes, protection: PROT_READ | PROT_WRITE | PROT_EXEC, flags: MAP_PRIVATE | MAP_ANONYMOUS | devboxMapJit)
            if let pointer = direct.pointer {
                munmap(pointer, bytes)
                return jitProbeResult(megabytes, failures: failures, via: "mmap RWX")
            }
            failures.append("\(megabytes) MB mmap errno \(direct.code)")

            let reserved = mapMemory(bytes, protection: PROT_NONE, flags: MAP_PRIVATE | MAP_ANONYMOUS | devboxMapJit)
            if let pointer = reserved.pointer {
                errno = 0
                let result = mprotect(pointer, bytes, PROT_READ | PROT_WRITE | PROT_EXEC)
                let code = errno
                munmap(pointer, bytes)
                if result == 0 {
                    return jitProbeResult(megabytes, failures: failures, via: "mmap NONE + mprotect RWX")
                }
                failures.append("\(megabytes) MB mprotect errno \(code)")
            } else {
                failures.append("\(megabytes) MB reserve errno \(reserved.code)")
            }
        }
        let text = "MAP_JIT bị chặn: \(failures.joined(separator: ", "))"
        trace("map_jit: \(text)")
        return (false, 0, text)
    }

    private static func jitProbeResult(_ megabytes: Int, failures: [String], via: String) -> (ok: Bool, tbSize: Int, note: String) {
        let head = "MAP_JIT \(megabytes) MB OK (\(via))"
        let text = failures.isEmpty ? head : "\(head) · trước đó: \(failures.joined(separator: ", "))"
        trace("map_jit: \(text)")
        return (true, megabytes, text)
    }

    private static func writeCodeTest(_ pointer: UnsafeMutableRawPointer) -> String {
        let words: [UInt32] = [0x52800540, 0xD65F03C0]
        let code = pointer.assumingMemoryBound(to: UInt32.self)
        for (index, word) in words.enumerated() {
            code[index] = word
        }
        devbox_icache_invalidate(pointer, words.count * 4)
        let written = code[0]
        let writtenText = "0x" + String(written, radix: 16)
        trace("write-test: đọc lại bộ nhớ = \(writtenText) (cần 0x52800540)")
        return written == words[0] ? "ghi/đọc mã máy OK" : "ghi mã máy bị nuốt (\(writtenText))"
    }

    private static func codeMemoryTest() -> [String] {
        var lines: [String] = []
        lines.append("split-wx (engine dùng): \(splitWXProbe().note)")
        lines.append("MAP_JIT (dự phòng): \(mapJITProbe().note)")
        lines.append("RWX trực tiếp (không dùng): \(probeExecMemory().note)")
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

    static func trace(_ message: String) {
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

@_silgen_name("sys_icache_invalidate")
private func devbox_icache_invalidate(_ start: UnsafeMutableRawPointer?, _ length: Int)

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
