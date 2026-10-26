import Foundation
import UIKit

enum Diagnostics {
    static func text() -> String {
        let device = DeviceProbe.snapshot()
        let keeper = BackgroundKeeper.shared
        let engine = QEMUEngine.shared
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var lines: [String] = []
        lines.append("== Devbox \(version) (\(build)) ==")
        lines.append("Model: \(device.model) · iOS \(device.systemVersion)")
        lines.append("RAM: \(device.physicalMemoryMB) MB · CPU: \(device.cores) nhân")
        lines.append("PID: \(device.pid) · PPID: \(device.parentPID)")
        lines.append("proc_csflags: \(device.csFlags.map { String(format: "0x%08X", $0) } ?? "không đọc được") [\(device.csSource)]")
        if device.csFlags == nil {
            lines.append("errno: csops=\(device.csopsErrno) · sysctl=\(device.sysctlErrno)")
        }
        lines.append("CS_DEBUGGED: \(device.debugged ? "BẬT" : "TẮT")")
        lines.append("P_TRACED: \(device.traced ? "CÓ" : "KHÔNG")")
        lines.append("JIT: \(jitText(device.jit))")
        lines.append("Giữ nền: \(keeper.stateText) · \(keeper.category) · \(keeper.uptimeText)")
        lines.append("RAM trống cho app: \(DeviceProbe.availableMemoryMB()) MB · app dùng \(DeviceProbe.footprintMB()) MB")
        lines.append("UIBackgroundModes: \(backgroundModes())")
        lines.append("Engine: \(engine.state.text) · \(engine.uptimeText)")
        lines.append("Bước cuối: \(engine.lastStage)")
        lines.append("JIT: \(engine.execNote.isEmpty ? "chưa thử" : engine.execNote)")
        lines.append("Image: \(imageState())")
        if !engine.logLines.isEmpty {
            lines.append("QEMU log:")
            for line in engine.logLines.suffix(40) {
                lines.append("  \(line)")
            }
        } else {
            lines.append("QEMU log: (trống)")
        }
        if let error = keeper.lastError {
            lines.append("Lỗi nền: \(error)")
        }
        lines.append(serialState())
        lines.append("Nhiệt: \(thermalText()) · Pin thấp: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "có" : "không")")
        return lines.joined(separator: "\n")
    }

    @discardableResult
    static func write() -> URL? {
        let directory = DevboxConfig.logsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = DevboxConfig.diagnosticsURL
        do {
            try text().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func jitText(_ state: JITState) -> String {
        switch state {
        case .granted: return "đã bật"
        case .denied: return "chưa bật"
        case .unknown: return "không xác định"
        }
    }

    private static func thermalText() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "bình thường"
        case .fair: return "hơi nóng"
        case .serious: return "nóng"
        case .critical: return "quá nóng"
        @unknown default: return "không rõ"
        }
    }

    private static func backgroundModes() -> String {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
              !modes.isEmpty else {
            return "THIẾU"
        }
        return modes.joined(separator: ",")
    }

    private static func imageState() -> String {
        guard let image = InstalledImage.load() else {
            return "chưa cài"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = (try? image.rootfs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(image.manifest.suite) · rootfs \(formatter.string(fromByteCount: Int64(size)))"
    }

    private static func serialState() -> String {
        let url = DevboxConfig.serialLogURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return "serial.log: (trống, guest chưa in gì)"
        }
        var lines: [String] = []
        lines.append("serial.log (\(data.count) byte), cuối file:")
        let text = String(decoding: data.suffix(4000), as: UTF8.self)
        for line in text.split(separator: "\r", omittingEmptySubsequences: false).suffix(14) {
            let clean = String(line).replacingOccurrences(of: "\n", with: "")
            lines.append("  \(String(clean.prefix(200)))")
        }
        return lines.joined(separator: "\n")
    }
}
