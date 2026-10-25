import Foundation
import Darwin
import UIKit

enum JITState {
    case granted
    case denied
    case unknown

    var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }

    var detail: String {
        switch self {
        case .granted:
            return "Debugger đã attach (CS_DEBUGGED). QEMU dùng được JIT."
        case .denied:
            return "Chưa có debugger attach. Bật bằng StikDebug, rồi mở lại Devbox."
        case .unknown:
            return "Không đọc được sysctl.proc_csflags."
        }
    }
}

struct DeviceSnapshot {
    var model: String
    var systemVersion: String
    var physicalMemoryMB: Int
    var cores: Int
    var jit: JITState
    /// Cờ `CS_DEBUGGED` trong `sysctl.proc_csflags`.
    var debugged: Bool
    var csFlags: UInt32?
    /// Tiến trình đang bị debugger trace (`P_TRACED` trong `kinfo_proc`).
    var traced: Bool
    var parentPID: Int32
    var pid: Int32
}

enum DeviceProbe {
    static func snapshot() -> DeviceSnapshot {
        let trace = traceInfo()
        let flags = csFlags()
        let jit: JITState
        if let flags {
            jit = (flags & CS_DEBUGGED) != 0 ? .granted : .denied
        } else {
            jit = .unknown
        }

        return DeviceSnapshot(
            model: hardwareModel(),
            systemVersion: UIDevice.current.systemVersion,
            physicalMemoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            cores: ProcessInfo.processInfo.processorCount,
            jit: jit,
            debugged: (flags.map { ($0 & CS_DEBUGGED) != 0 }) ?? false,
            csFlags: flags,
            traced: trace.traced,
            parentPID: trace.parent,
            pid: getpid()
        )
    }

    static func hardwareModel() -> String {
        sysctlString("hw.machine") ?? UIDevice.current.model
    }

    /// JIT trên iOS chỉ có khi tiến trình đang bị debugger attach
    /// (StikDebug / debugserver) → cờ CS_DEBUGGED bật.
    ///
    /// Bài học: `mprotect(PROT_EXEC)` trả về 0 **không** chứng minh JIT đã bật.
    /// iOS vẫn kill tiến trình khi CPU thực thi trang nhớ chưa được ký,
    /// nên cách kiểm tra cũ cho kết quả dương tính giả.
    static func jitState() -> JITState {
        guard let flags = csFlags() else { return .unknown }
        return (flags & CS_DEBUGGED) != 0 ? .granted : .denied
    }

    static func isDebugged() -> Bool {
        guard let flags = csFlags() else { return false }
        return (flags & CS_DEBUGGED) != 0
    }

    /// Tín hiệu thứ hai: `P_TRACED` cho biết có debugger đang trace tiến trình,
    /// kể cả khi `CS_DEBUGGED` chưa kịp cập nhật. Dùng để chẩn đoán StikDebug.
    static func traceInfo() -> (traced: Bool, parent: Int32) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        let traced = result == 0 && (info.kp_proc.p_flag & pTraced) != 0
        return (traced, getppid())
    }

    /// CS_DEBUGGED — chỉ bật khi có debugger attach.
    private static let CS_DEBUGGED: UInt32 = 0x1000_0000
    /// P_TRACED trong `kinfo_proc.kp_proc.p_flag`.
    private static let pTraced: Int32 = 0x0000_0800

    static func csFlags() -> UInt32? {
        var flags: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("sysctl.proc_csflags", &flags, &size, nil, 0) == 0 else {
            return nil
        }
        return flags
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
