import Foundation
import Combine

/// Engine giả: mô phỏng các bước boot để hoàn thiện UI trước khi nối QEMU.
/// Khi làm M1, thay lớp này bằng CellarEngine (ObjC++).
final class MockEngine: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var message: String = "Chưa khởi động"
    @Published private(set) var isRunning: Bool = false

    private let steps = [
        "Kiểm tra JIT",
        "Khởi động QEMU",
        "Boot Linux ARM64",
        "Kết nối cellar-agent",
        "Khởi chạy Wine"
    ]

    func boot() async {
        guard !isRunning else { return }
        isRunning = true
        progress = 0

        for (index, step) in steps.enumerated() {
            message = step
            try? await Task.sleep(nanoseconds: 350_000_000)
            progress = Double(index + 1) / Double(steps.count)
        }

        message = "Game đang chạy (giả lập)"
        isRunning = false
    }

    func reset() {
        progress = 0
        message = "Chưa khởi động"
        isRunning = false
    }
}
