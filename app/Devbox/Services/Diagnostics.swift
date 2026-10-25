import Foundation
import UIKit

/// Tạo một khối text ngắn, đầy đủ trạng thái thật, để người dùng copy
/// dán vào chat (không cần chụp ảnh).
enum Diagnostics {
    static func text() -> String {
        let device = DeviceProbe.snapshot()
        let keeper = BackgroundKeeper.shared
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var lines: [String] = []
        lines.append("== Devbox \(version) (\(build)) ==")
        lines.append("Model: \(device.model) · iOS \(device.systemVersion)")
        lines.append("RAM: \(device.physicalMemoryMB) MB · CPU: \(device.cores) nhân")
        lines.append("PID: \(device.pid) · PPID: \(device.parentPID)")
        lines.append("proc_csflags: \(device.csFlags.map { String(format: "0x%08X", $0) } ?? "không đọc được")")
        lines.append("CS_DEBUGGED: \(device.debugged ? "BẬT" : "TẮT")")
        lines.append("P_TRACED: \(device.traced ? "CÓ" : "KHÔNG")")
        lines.append("JIT: \(jitText(device.jit))")
        lines.append("Giữ nền: \(keeper.stateText) · \(keeper.category) · \(keeper.uptimeText)")
        lines.append("UIBackgroundModes: \(backgroundModes())")
        lines.append("Engine: QEMU chưa nối")
        lines.append("Image: \(imageState())")
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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let image = docs.appendingPathComponent("Devbox/images/devbox-rootfs.ext4")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: image.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return "chưa cài"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "có (\(formatter.string(fromByteCount: size)))"
    }
}
