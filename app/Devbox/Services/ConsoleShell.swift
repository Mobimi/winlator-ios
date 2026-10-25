import Foundation
import Darwin
import UIKit

enum LineRole {
    case command
    case output
    case error
    case success
    case info
}

struct ShellLine: Identifiable {
    let id = UUID()
    var text: String
    var role: LineRole
}

/// Console **thật** của app.
///
/// Bản này chỉ chạy những lệnh đọc trạng thái thật trên máy
/// (JIT, RAM, kernel, dung lượng, file trong sandbox).
/// Không có lệnh Linux giả: khi engine QEMU được nối ở M1,
/// các lệnh của guest sẽ đi qua đúng console này.
final class ConsoleShell: ObservableObject {
    @Published private(set) var lines: [ShellLine] = []
    @Published private(set) var cwd: String = "~"

    private let documents: URL
    private let projects: URL
    private var currentDirectory: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        documents = docs.standardizedFileURL
        projects = documents.appendingPathComponent("Projects", isDirectory: true)
        currentDirectory = documents
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    var prompt: String { "devbox:\(cwd)$" }

    func boot() {
        lines = []
        append("Devbox console — chạy thật trên máy, không giả lập.", .info)
        append("Engine Linux: CHƯA NỐI. Các lệnh python/npm sẽ không chạy ở bản này.", .error)
        append("Gõ “help” để xem lệnh chẩn đoán thật.", .info)
        append("", .output)
    }

    func run(_ raw: String) {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        append("\(prompt) \(command)", .command)

        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first?.lowercased() else { return }
        let arguments = Array(parts.dropFirst())

        switch head {
        case "help", "?":
            append(
                """
                Lệnh chạy thật trên máy:
                  jit              trạng thái JIT + cờ code signing
                  mem              RAM, nhiệt, tiết kiệm pin
                  uname            kernel iOS thật
                  df               dung lượng sandbox
                  ls [thư mục]     liệt kê file thật
                  cd [thư mục]     đổi thư mục (trong sandbox)
                  pwd              đường dẫn hiện tại
                  engine           trạng thái engine/image
                  clear

                Lệnh Linux (python, pip, node, npm, git…): CHƯA CÓ.
                Chúng cần QEMU + image Debian, tức mốc M1/M2.
                App sẽ không in kết quả giả cho các lệnh này.
                """,
                .output
            )

        case "jit":
            printJIT()

        case "mem":
            printMemory()

        case "uname":
            printUname()

        case "df":
            printDisk()

        case "ls":
            list(arguments.first)

        case "cd":
            changeDirectory(arguments.first)

        case "pwd":
            append(currentDirectory.path, .output)

        case "engine":
            printEngine()

        case "clear":
            lines = []
            return

        default:
            append("\(head): lệnh Linux chưa chạy được — chưa nối engine QEMU (M1).", .error)
            append("App không in kết quả giả. Gõ “help” để xem lệnh thật.", .info)
        }

        append("", .output)
        trimHistory()
    }

    // MARK: - Lệnh thật

    private func printJIT() {
        let flags = DeviceProbe.csFlags()
        let state = DeviceProbe.jitState()

        if let flags {
            append(String(format: "sysctl.proc_csflags = 0x%08X", flags), .output)
            append("CS_DEBUGGED (0x10000000) = \((flags & 0x1000_0000) != 0 ? "BẬT" : "TẮT")", .output)
        } else {
            append("Không đọc được sysctl.proc_csflags.", .error)
        }

        switch state {
        case .granted:
            append("→ JIT: đã bật (debugger đang attach).", .success)
        case .denied:
            append("→ JIT: CHƯA bật. Mở StikDebug → Enable JIT cho Devbox.", .error)
        case .unknown:
            append("→ JIT: không xác định.", .error)
        }
    }

    private func printMemory() {
        let info = ProcessInfo.processInfo
        let physical = Int(info.physicalMemory / 1_048_576)
        append("RAM vật lý: \(physical) MB", .output)
        append("CPU: \(info.processorCount) nhân · \(info.activeProcessorCount) đang hoạt động", .output)

        switch info.thermalState {
        case .nominal: append("Nhiệt: bình thường", .output)
        case .fair: append("Nhiệt: hơi nóng", .output)
        case .serious: append("Nhiệt: nóng — máy sẽ giảm tốc", .error)
        case .critical: append("Nhiệt: quá nóng — dừng tác vụ nặng", .error)
        @unknown default: append("Nhiệt: không xác định", .output)
        }

        append("Tiết kiệm pin: \(info.isLowPowerModeEnabled ? "đang bật" : "tắt")", .output)
    }

    private func printUname() {
        var value = utsname()
        guard uname(&value) == 0 else {
            append("uname() thất bại.", .error)
            return
        }
        let sysname = string(from: &value.sysname)
        let nodename = string(from: &value.nodename)
        let release = string(from: &value.release)
        let machine = string(from: &value.machine)
        append("\(sysname) \(nodename) \(release) \(machine)", .output)
        append("Đây là kernel iOS. Kernel Linux chỉ có sau khi boot QEMU (M1).", .info)
    }

    private func printDisk() {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: currentDirectory.path),
              let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
        else {
            append("Không đọc được dung lượng.", .error)
            return
        }
        let used = total - free
        append("Sandbox: \(formatBytes(used)) đã dùng / \(formatBytes(total))", .output)
        append("Còn trống: \(formatBytes(free))", .output)
    }

    private func list(_ path: String?) {
        guard let directory = resolve(path) else {
            append("ls: ngoài phạm vi sandbox.", .error)
            return
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            append("ls: không đọc được \(directory.lastPathComponent).", .error)
            return
        }
        if entries.isEmpty {
            append("(thư mục trống)", .info)
            return
        }
        let formatted = entries.sorted().prefix(200).map { name -> String in
            var isDirectory: ObjCBool = false
            let full = directory.appendingPathComponent(name).path
            FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory)
            return isDirectory.boolValue ? "\(name)/" : name
        }
        append(formatted.joined(separator: "  "), .output)
        if entries.count > 200 {
            append("… còn \(entries.count - 200) mục nữa", .info)
        }
    }

    private func changeDirectory(_ path: String?) {
        guard let path, !path.isEmpty else {
            currentDirectory = documents
            cwd = "~"
            return
        }
        guard let target = resolve(path) else {
            append("cd: ngoài phạm vi sandbox.", .error)
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            append("cd: không phải thư mục: \(path)", .error)
            return
        }
        currentDirectory = target
        let relative = target.path.replacingOccurrences(of: documents.path, with: "")
        cwd = relative.isEmpty ? "~" : "~\(relative)"
    }

    private func printEngine() {
        append("QEMU: chưa nhúng vào app (mốc M1).", .error)
        let images = documents.appendingPathComponent("Devbox/images", isDirectory: true)
        let image = images.appendingPathComponent("devbox-rootfs.ext4")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: image.path),
           let size = (attributes[.size] as? NSNumber)?.int64Value {
            append("Image: có (\(formatBytes(size)))", .success)
        } else {
            append("Image: chưa cài", .output)
        }
        append("→ Chưa boot được Linux. Không có lệnh nào giả ở đây.", .info)
    }

    // MARK: - Helpers

    private func resolve(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return currentDirectory }

        let candidate: URL
        if path == "~" {
            candidate = documents
        } else if path.hasPrefix("~/") {
            candidate = documents.appendingPathComponent(String(path.dropFirst(2)))
        } else if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = currentDirectory.appendingPathComponent(path)
        }

        let standardized = candidate.standardizedFileURL
        guard standardized.path == documents.path || standardized.path.hasPrefix(documents.path + "/") else {
            return nil
        }
        return standardized
    }

    private func string<T>(from value: inout T) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cString in
                String(cString: cString)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    private func append(_ text: String, _ role: LineRole) {
        lines.append(ShellLine(text: text, role: role))
    }

    private func trimHistory() {
        let limit = 800
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }
}
