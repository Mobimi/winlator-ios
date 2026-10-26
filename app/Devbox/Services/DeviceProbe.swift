import Foundation
import Darwin
import UIKit

@_silgen_name("csops")
private func devbox_csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

@_silgen_name("os_proc_available_memory")
private func devbox_os_proc_available_memory() -> UInt

@_silgen_name("proc_pidinfo")
private func devbox_proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

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
            return "CS_DEBUGGED đã bật. Engine TCG dùng split-wx, không cần MAP_JIT."
        case .denied:
            return "Chưa có CS_DEBUGGED. Bật bằng StikDebug, rồi mở lại Devbox."
        case .unknown:
            return "iOS không cho app đọc cờ JIT. App vẫn thử split-wx khi khởi động."
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
    var traceNote: String
    var parentPID: Int32
    var pid: Int32

    var jitReady: Bool {
        guard QEMUEngine.engineNeedsJIT else { return true }
        if case .denied = jit { return false }
        return true
    }
}

enum DeviceProbe {
    static func snapshot() -> DeviceSnapshot {
        let trace = traceInfo()
        let probe = csFlagsProbe()
        let debugged = (probe.flags.map { ($0 & CS_DEBUGGED) != 0 }) ?? false
        let jit: JITState
        if let flags = probe.flags {
            jit = (flags & CS_DEBUGGED) != 0 ? .granted : .denied
        } else {
            jit = .unknown
        }

        let traceNote: String
        if !trace.readable {
            traceNote = trace.note
        } else if trace.traced {
            traceNote = "CÓ (debugger đang attach)"
        } else if debugged {
            traceNote = "KHÔNG (bình thường: StikDebug đã detach, JIT vẫn bật nhờ CS_DEBUGGED)"
        } else {
            traceNote = "KHÔNG"
        }

        return DeviceSnapshot(
            model: hardwareModel(),
            systemVersion: UIDevice.current.systemVersion,
            physicalMemoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            cores: ProcessInfo.processInfo.processorCount,
            jit: jit,
            debugged: debugged,
            csFlags: probe.flags,
            csSource: probe.source,
            csopsErrno: probe.csopsErrno,
            sysctlErrno: probe.sysctlErrno,
            traced: trace.traced,
            traceNote: traceNote,
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

    static func availableMemoryMB() -> Int {
        Int(devbox_os_proc_available_memory() / 1_048_576)
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }

    static func isDebugged() -> Bool {
        guard let flags = csFlags() else { return false }
        return (flags & CS_DEBUGGED) != 0
    }

    static func traceInfo() -> (traced: Bool, parent: Int32, readable: Bool, note: String) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        errno = 0
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        let sysctlError = errno
        if result == 0 {
            let traced = (info.kp_proc.p_flag & pTraced) != 0
            return (traced, getppid(), true, traced ? "CÓ (debugger đang attach)" : "KHÔNG")
        }

        var buffer = [UInt8](repeating: 0, count: 256)
        errno = 0
        let got = buffer.withUnsafeMutableBytes { raw in
            devbox_proc_pidinfo(getpid(), procPidTBSDInfo, 0, raw.baseAddress, Int32(raw.count))
        }
        let infoError = errno
        if got > 0 {
            let flags = buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let traced = (flags & procFlagTraced) != 0
            return (traced, getppid(), true, traced ? "CÓ (debugger đang attach)" : "KHÔNG")
        }

        let detail = infoError != 0 ? "\(infoError)" : "0"
        return (false, getppid(), false, "không đọc được (sysctl errno \(sysctlError), proc_pidinfo errno \(detail))")
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
    private static let procPidTBSDInfo: Int32 = 3
    private static let procFlagTraced: UInt32 = 0x0000_0002

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
