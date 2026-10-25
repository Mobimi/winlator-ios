import Foundation
import CryptoKit

final class ImageStore: ObservableObject {
    static let shared = ImageStore()

    enum Phase: Equatable {
        case idle
        case loadingManifest
        case downloading(String, Double)
        case verifying(String)
        case extracting(String, Double)
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .loadingManifest, .downloading, .verifying, .extracting:
                return true
            default:
                return false
            }
        }

        var text: String {
            switch self {
            case .idle:
                return "Chưa cài image"
            case .loadingManifest:
                return "Đang lấy manifest…"
            case .downloading(let name, let progress):
                return "Đang tải \(name) \(Int(progress * 100))%"
            case .verifying(let name):
                return "Đang kiểm tra SHA256 \(name)"
            case .extracting(let name, let progress):
                return "Đang giải nén \(name) \(Int(progress * 100))%"
            case .ready:
                return "Image sẵn sàng"
            case .failed(let message):
                return message
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var image: InstalledImage?

    private init() {
        image = InstalledImage.load()
        if image != nil {
            phase = .ready
        }
    }

    var isInstalled: Bool { image != nil }

    func install() {
        guard !phase.isBusy else { return }
        phase = .loadingManifest
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.runInstall()
            } catch {
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    func remove() {
        guard !phase.isBusy else { return }
        try? FileManager.default.removeItem(at: DevboxConfig.imageDirectory)
        image = nil
        phase = .idle
    }

    private func runInstall() throws {
        let manifestData = try Data(contentsOf: DevboxConfig.manifestURL, options: .uncached)
        let manifest = try JSONDecoder().decode(ImageManifest.self, from: manifestData)

        let dir = DevboxConfig.imageDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try checkSpace()

        let rootfsArchive = dir.appendingPathComponent("rootfs.ext4.zst")
        let kernel = dir.appendingPathComponent("vmlinuz")
        let initrd = dir.appendingPathComponent("initrd.img")

        try download(manifest.kernel, to: kernel, label: "kernel")
        try download(manifest.initrd, to: initrd, label: "initrd")
        try download(manifest.image, to: rootfsArchive, label: "rootfs")

        finish(.extracting("rootfs", 0))
        let rootfs = dir.appendingPathComponent("rootfs.ext4")
        try? FileManager.default.removeItem(at: rootfs)
        try Zstd.shared.decompress(from: rootfsArchive, to: rootfs) { [weak self] progress in
            self?.finish(.extracting("rootfs", progress))
        }
        try? FileManager.default.removeItem(at: rootfsArchive)

        try manifestData.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)

        let installed = InstalledImage(directory: dir, manifest: manifest)
        guard installed.isComplete else {
            throw InstallError.incomplete
        }
        DispatchQueue.main.async {
            self.image = installed
            self.phase = .ready
        }
    }

    private func checkSpace() throws {
        let values = try DevboxConfig.imagesRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        if available < 3_200_000_000 {
            throw InstallError.space(available)
        }
    }

    private func download(_ file: ImageManifest.FileRef, to destination: URL, label: String) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.removeItem(at: temp)
        finish(.downloading(label, 0))

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .failure(InstallError.download)
        let downloader = FileDownloader(destination: temp) { [weak self] progress in
            self?.finish(.downloading(label, progress))
        } completion: { outcome in
            result = outcome
            semaphore.signal()
        }
        downloader.start(url: file.url(for: file))
        semaphore.wait()

        if case .failure(let error) = result {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        finish(.verifying(label))
        let digest = try sha256(of: temp)
        guard digest == file.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: temp)
            throw InstallError.checksum(label)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func finish(_ phase: Phase) {
        DispatchQueue.main.async {
            self.phase = phase
        }
    }
}

private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private let onFinish: (Result<Void, Error>) -> Void
    private var session: URLSession?
    private var lastUpdate = Date.distantPast
    private var done = false

    init(destination: URL, progress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.onProgress = progress
        self.onFinish = completion
    }

    func start(url: URL) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !done else { return }
        done = true
        session?.finishTasksAndInvalidate()
        onFinish(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(.failure(InstallError.http(http.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) > 0.2 else { return }
        lastUpdate = now
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

enum InstallError: LocalizedError {
    case download
    case http(Int)
    case checksum(String)
    case incomplete
    case zstd(String)
    case space(Int64)

    var errorDescription: String? {
        switch self {
        case .download:
            return "Tải image thất bại."
        case .http(let code):
            return "Máy chủ trả về HTTP \(code)."
        case .checksum(let label):
            return "SHA256 của \(label) không khớp. Xoá image rồi tải lại."
        case .incomplete:
            return "Image thiếu file sau khi giải nén."
        case .zstd(let message):
            return "Giải nén zstd lỗi: \(message)"
        case .space(let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Không đủ dung lượng. Còn \(formatter.string(fromByteCount: available)), cần khoảng 3 GB."
        }
    }
}
