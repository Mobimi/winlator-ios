import Foundation
import UIKit

/// Nhiều tác vụ cùng cần màn hình không tự tắt (đang cài image, đang chạy
/// máy ảo). Đếm theo khoá để tác vụ này không tắt cờ của tác vụ kia.
enum IdleTimer {
    private static let lock = NSLock()
    private static var holders: Set<String> = []

    static func hold(_ key: String, _ active: Bool) {
        lock.lock()
        let changed: Bool
        if active {
            changed = holders.insert(key).inserted
        } else {
            changed = holders.remove(key) != nil
        }
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async {
            lock.lock()
            let disabled = !holders.isEmpty
            lock.unlock()
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }
}
