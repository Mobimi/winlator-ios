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
            return "Đã cấp được quyền thực thi bộ nhớ (mmap RWX)."
        case .denied:
            return "iOS đang chặn. Cần StikDebug hoặc AltStore/SideStore có JIT."
        case .unknown:
            return "Không kiểm tra được."
        }
    }
}

struct DeviceSnapshot {
    var model: String
    var systemVersion: String
    var physicalMemoryMB: Int
    var cores: Int
    var jit: JITState
    var debugged: Bool
}

enum DeviceProbe {
    static func snapshot() -> DeviceSnapshot {
        DeviceSnapshot(
            model: hardwareModel(),
            systemVersion: UIDevice.current.systemVersion,
            physicalMemoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            cores: ProcessInfo.processInfo.processorCount,
            jit: jitState(),
            debugged: isDebugged()
        )
    }

    static func hardwareModel() -> String {
        sysctlString("hw.machine") ?? UIDevice.current.model
    }

    /// Cách UTM kiểm tra JIT: xin một trang nhớ có quyền ghi + thực thi.
    /// iOS chỉ cho phép khi tiến trình đã bị debugger attach (CS_DEBUGGED).
    static func jitState() -> JITState {
        let page = Int(getpagesize())
        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, page, page) == 0, let pointer = raw else {
            return .unknown
        }
        defer { free(pointer) }

        memset(pointer, 0, page)
        let result = mprotect(pointer, page, PROT_READ | PROT_WRITE | PROT_EXEC)
        _ = mprotect(pointer, page, PROT_READ | PROT_WRITE)

        return result == 0 ? .granted : .denied
    }

    static func isDebugged() -> Bool {
        var flags: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("sysctl.proc_csflags", &flags, &size, nil, 0) == 0 else {
            return false
        }
        // CS_DEBUGGED = 0x10000000
        return (flags & 0x1000_0000) != 0
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
