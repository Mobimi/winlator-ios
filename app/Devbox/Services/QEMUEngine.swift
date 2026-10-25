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

    private static var runningThread: pthread_t?
    private static var guardInstalled = false

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

        let arguments = buildArguments(image: image, share: share, cpuCount: cpuCount, memoryMB: memoryMB)
        lastArguments = arguments
        hasBooted = true
        state = .starting
        startedAt = Date()
        logLines = []
        prepareLog()
        installExitGuard()

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
        stopRequested = true
        let port = qmpPort
        DispatchQueue.global(qos: .userInitiated).async {
            QMPClient.quit(port: port, timeout: 4)
        }
    }

    func refreshLog() {
        guard let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        logLines = Array(lines.suffix(200))
    }

    private func buildArguments(image: InstalledImage, share: URL, cpuCount: Int, memoryMB: Int) -> [String] {
        var args: [String] = ["qemu-system-aarch64"]
        args += ["-M", "virt,highmem=on"]
        args += ["-cpu", "max"]
        args += ["-smp", "\(cpuCount)"]
        args += ["-m", "\(memoryMB)"]
        args += ["-accel", "tcg,thread=multi,tb-size=256"]
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
        freopen(logURL?.path ?? "/dev/null", "a", stdout)
        freopen(logURL?.path ?? "/dev/null", "a", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)

        signal(SIGPIPE, SIG_IGN)

        guard let open = dlopen(dylib.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "dlopen thất bại"
            fail(message)
            return
        }
        handle = open

        guard let initSym = dlsym(open, "qemu_init"),
              let loopSym = dlsym(open, "qemu_main_loop"),
              let cleanupSym = dlsym(open, "qemu_cleanup") else {
            fail("Thiếu symbol qemu_init/qemu_main_loop/qemu_cleanup")
            return
        }

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

        initFn(Int32(arguments.count), &argv)

        DispatchQueue.main.async {
            if self.state == .starting {
                self.state = .running
                self.startedAt = Date()
                self.stopWatchdog()
            }
        }

        let status = loopFn()
        cleanupFn(status)

        dlclose(open)
        handle = nil

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
        DispatchQueue.main.async {
            self.stopLogTimer()
            self.state = .failed(message)
        }
    }

    private func prepareLog() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qemu.log")
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logURL = url
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
        let timer = Timer(timeInterval: 40, repeats: false) { [weak self] _ in
            guard let self, self.state == .starting else { return }
            self.refreshLog()
            let tail = self.logLines.suffix(4).joined(separator: " ")
            let message = tail.isEmpty ? "QEMU không khởi động được (JIT chưa bật?)" : "QEMU dừng khi khởi động: \(tail)"
            self.state = .failed(message)
            self.stopLogTimer()
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
}

private func devboxExitGuard() {
    guard let running = QEMUEngine.runningThread else { return }
    if pthread_equal(pthread_self(), running) != 0 {
        pthread_exit(nil)
    }
}
