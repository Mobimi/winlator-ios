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
        lines.append("UIBackgroundModes: \(backgroundModes())")
        lines.append("Engine: \(engine.state.text) · \(engine.uptimeText)")
        lines.append("Image: \(imageState())")
        if !engine.logLines.isEmpty {
            lines.append("QEMU log:")
            for line in engine.logLines.suffix(10) {
                lines.append("  \(line)")
            }
        }
        if let error = keeper.lastError {
            lines.append("Lỗi nền: \(error)")
        }
        lines.append("Nhiệt: \(thermalText()) · Pin thấp: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "có" : "không")")
        return lines.joined(separator: "\n")
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
}
