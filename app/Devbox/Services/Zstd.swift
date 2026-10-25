import Foundation
import Darwin

struct ZSTD_inBuffer {
    var src: UnsafeRawPointer?
    var size: Int
    var pos: Int
}

struct ZSTD_outBuffer {
    var dst: UnsafeMutableRawPointer?
    var size: Int
    var pos: Int
}

final class Zstd {
    static let shared = Zstd()

    private typealias CreateFn = @convention(c) () -> OpaquePointer?
    private typealias InitFn = @convention(c) (OpaquePointer?) -> Int
    private typealias FreeFn = @convention(c) (OpaquePointer?) -> Int
    private typealias DecompressFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int
    private typealias IsErrorFn = @convention(c) (Int) -> UInt32
    private typealias ErrorNameFn = @convention(c) (Int) -> UnsafePointer<CChar>?

    private var handle: UnsafeMutableRawPointer?
    private var createFn: CreateFn?
    private var initFn: InitFn?
    private var freeFn: FreeFn?
    private var decompressFn: DecompressFn?
    private var isErrorFn: IsErrorFn?
    private var errorNameFn: ErrorNameFn?

    private init() {
        load()
    }

    var isAvailable: Bool {
        createFn != nil && initFn != nil && decompressFn != nil
    }

    var version: String {
        guard let handle, let sym = dlsym(handle, "ZSTD_versionString") else { return "không có" }
        let fn = unsafeBitCast(sym, to: (@convention(c) () -> UnsafePointer<CChar>?).self)
        guard let ptr = fn() else { return "không rõ" }
        return String(cString: ptr)
    }

    private func load() {
        guard let frameworks = Bundle.main.privateFrameworksURL,
              let items = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else {
            return
        }
        let names = items.filter { $0.lowercased().hasPrefix("zstd") && $0.hasSuffix(".framework") }
        for item in names {
            let name = String(item.dropLast(".framework".count))
            let url = frameworks.appendingPathComponent("\(item)/\(name)")
            guard let open = dlopen(url.path, RTLD_LAZY | RTLD_LOCAL) else { continue }
            handle = open
            if let sym = dlsym(open, "ZSTD_createDStream") {
                createFn = unsafeBitCast(sym, to: CreateFn.self)
            }
            if let sym = dlsym(open, "ZSTD_initDStream") {
                initFn = unsafeBitCast(sym, to: InitFn.self)
            }
            if let sym = dlsym(open, "ZSTD_freeDStream") {
                freeFn = unsafeBitCast(sym, to: FreeFn.self)
            }
            if let sym = dlsym(open, "ZSTD_decompressStream") {
                decompressFn = unsafeBitCast(sym, to: DecompressFn.self)
            }
            if let sym = dlsym(open, "ZSTD_isError") {
                isErrorFn = unsafeBitCast(sym, to: IsErrorFn.self)
            }
            if let sym = dlsym(open, "ZSTD_getErrorName") {
                errorNameFn = unsafeBitCast(sym, to: ErrorNameFn.self)
            }
            if isAvailable {
                return
            }
            dlclose(open)
            handle = nil
        }
    }

    func decompress(from source: URL, to destination: URL, progress: (Double) -> Void) throws {
        guard let createFn, let initFn, let decompressFn else {
            throw InstallError.zstd("không tìm thấy libzstd trong app")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let totalIn = (attributes[.size] as? NSNumber)?.doubleValue ?? 0
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        guard let stream = createFn() else {
            throw InstallError.zstd("không tạo được stream")
        }
        defer { _ = freeFn?(stream) }

        let check = initFn(stream)
        if let isErrorFn, isErrorFn(check) != 0 {
            throw InstallError.zstd(errorName(check))
        }

        let inputCapacity = 1 << 20
        let outputCapacity = 4 << 20
        let inputPointer = UnsafeMutableRawPointer.allocate(byteCount: inputCapacity, alignment: 8)
        let outputPointer = UnsafeMutableRawPointer.allocate(byteCount: outputCapacity, alignment: 8)
        defer {
            inputPointer.deallocate()
            outputPointer.deallocate()
        }

        var inBuffer = ZSTD_inBuffer(src: inputPointer, size: 0, pos: 0)
        var outBuffer = ZSTD_outBuffer(dst: outputPointer, size: outputCapacity, pos: 0)
        var endOfInput = false
        var consumed: Double = 0

        while true {
            if inBuffer.pos == inBuffer.size && !endOfInput {
                let data = try input.read(upToCount: inputCapacity) ?? Data()
                if data.isEmpty {
                    endOfInput = true
                } else {
                    data.copyBytes(to: inputPointer.assumingMemoryBound(to: UInt8.self), count: data.count)
                    inBuffer.size = data.count
                    inBuffer.pos = 0
                    consumed += Double(data.count)
                    if totalIn > 0 {
                        progress(min(consumed / totalIn, 0.99))
                    }
                }
            }

            outBuffer.pos = 0
            let result = withUnsafeMutablePointer(to: &outBuffer) { outPointer in
                withUnsafeMutablePointer(to: &inBuffer) { inPointer in
                    decompressFn(stream, UnsafeMutableRawPointer(outPointer), UnsafeMutableRawPointer(inPointer))
                }
            }
            if let isErrorFn, isErrorFn(result) != 0 {
                throw InstallError.zstd(errorName(result))
            }
            if outBuffer.pos > 0 {
                output.write(Data(bytes: outputPointer, count: outBuffer.pos))
            }
            if result == 0 && endOfInput && inBuffer.pos == inBuffer.size {
                break
            }
            if endOfInput && inBuffer.pos == inBuffer.size && outBuffer.pos == 0 {
                break
            }
        }

        try output.synchronize()
        progress(1.0)
    }

    private func errorName(_ code: Int) -> String {
        guard let errorNameFn, let ptr = errorNameFn(code) else { return "mã \(code)" }
        return String(cString: ptr)
    }
}
