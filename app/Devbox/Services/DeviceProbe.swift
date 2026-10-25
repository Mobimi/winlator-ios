import Foundation
import Darwin
import UIKit

@_silgen_name("csops")
private func devbox_csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

enum JITState {
    case granted
    case denied
    case unknown

    var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .granted: return "JIT đã bật"
        case .denied: return "JIT chưa bật"
        case .unknown: return "Không xác định được JIT"
        }
    }

    var detail: String {
        switch self {
        case .granted:
            return "Debugger đã attach (CS_DEBUGGED). QEMU dùng được JIT."
        case .denied:
            return "Chưa có debugger attach. Bật bằng StikDebug, rồi mở lại Devbox."
        case .unknown:
            return "iOS này không cho app đọc cờ JIT. Xem errno bên dưới để biết bị chặn ở đâu."
        }
    }
}

struct CsFlagsProbe {
    var flags: UInt32?
    var source: String
    var csopsErrno: Int32
    var sysctlErrno: Int32
}

struct DeviceSnapshot {
    var model: String
    var systemVersion: String
    var physicalMemoryMB: Int
    var cores: Int
    var jit: JITState
    var debugged: Bool
    var csFlags: UInt32?
    var csSource: String
    var csopsErrno: Int32
    var sysctlErrno: Int32
    var traced: Bool
    var parentPID: Int32
    var pid: Int32
}

enum DeviceProbe {
    static func snapshot() -> DeviceSnapshot {
        let trace = traceInfo()
        let probe = csFlagsProbe()
        let jit: JITState
        if let flags = probe.flags {
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
            debugged: (probe.flags.map { ($0 & CS_DEBUGGED) != 0 }) ?? false,
            csFlags: probe.flags,
            csSource: probe.source,
            csopsErrno: probe.csopsErrno,
            sysctlErrno: probe.sysctlErrno,
            traced: trace.traced,
            parentPID: trace.parent,
            pid: getpid()
        )
    }

    static func hardwareModel() -> String {
        sysctlString("hw.machine") ?? UIDevice.current.model
    }

    static func jitState() -> JITState {
        guard let flags = csFlags() else { return .unknown }
        return (flags & CS_DEBUGGED) != 0 ? .granted : .denied
    }

    static func isDebugged() -> Bool {
        guard let flags = csFlags() else { return false }
        return (flags & CS_DEBUGGED) != 0
    }

    static func traceInfo() -> (traced: Bool, parent: Int32) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        let traced = result == 0 && (info.kp_proc.p_flag & pTraced) != 0
        return (traced, getppid())
    }

    static func csFlags() -> UInt32? {
        csFlagsProbe().flags
    }

    static func csFlagsProbe() -> CsFlagsProbe {
        var csopsFlags: UInt32 = 0
        errno = 0
        if devbox_csops(getpid(), csOpsStatus, &csopsFlags, MemoryLayout<UInt32>.size) == 0 {
            return CsFlagsProbe(flags: csopsFlags, source: "csops", csopsErrno: 0, sysctlErrno: 0)
        }
        let csopsError = errno

        var sysctlFlags: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        errno = 0
        if sysctlbyname("sysctl.proc_csflags", &sysctlFlags, &size, nil, 0) == 0 {
            return CsFlagsProbe(flags: sysctlFlags, source: "sysctl", csopsErrno: csopsError, sysctlErrno: 0)
        }

        return CsFlagsProbe(flags: nil, source: "—", csopsErrno: csopsError, sysctlErrno: errno)
    }

    private static let CS_DEBUGGED: UInt32 = 0x1000_0000
    private static let csOpsStatus: UInt32 = 0
    private static let pTraced: Int32 = 0x0000_0800

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
