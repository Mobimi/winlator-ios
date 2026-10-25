import AVFoundation
import Combine
import UIKit

/// Giữ app sống khi rời màn hình, để web server / QEMU trong guest không chết.
///
/// iOS **không** cho app chạy nền vô hạn. Cách duy nhất hợp lệ về mặt kỹ thuật
/// (không phải hợp lệ về mặt App Store) là khai báo `UIBackgroundModes = audio`
/// rồi thật sự phát audio. Ở đây phát một buffer gần như im lặng (-100 dBFS)
/// lặp vô hạn bằng `AVAudioEngine` + category `.playback`, `.mixWithOthers`
/// (để không chặn nhạc của app khác). Hệ thống thấy app đang phát audio nên
/// không suspend tiến trình, nhờ đó socket của dev server vẫn sống.
///
/// Sự thật cần nhớ:
/// - Bấm Home / chuyển sang app khác: Devbox vẫn chạy → `localhost:<cổng>` vẫn trả lời.
/// - Vuốt app khỏi đa nhiệm (Force Quit): tiến trình **luôn** chết. Không có API nào chặn được.
/// - Tốn pin và ấm máy (audio session + QEMU cùng chạy). Tắt công tắc khi không cần.
/// - `UIBackgroundModes` là khoá **Info.plist**, không phải entitlement.
///   Vì vậy nó không làm hỏng profile free 7 ngày của Sideloadly/SideStore.
final class BackgroundKeeper: ObservableObject {
    static let shared = BackgroundKeeper()

    /// Audio im lặng đang phát thật hay không.
    @Published private(set) var isAudioRunning = false
    /// Lúc bắt đầu giữ nền; `nil` khi đang tắt.
    @Published private(set) var startedAt: Date?
    /// Lỗi gần nhất, hiển thị nguyên văn (không giả vờ thành công).
    @Published private(set) var lastError: String?
    /// Số lần audio bị gián đoạn (cuộc gọi, tai nghe rút, …).
    @Published private(set) var interruptionCount = 0
    /// Có `beginBackgroundTask` đang giữ (~30 giây) hay không.
    @Published private(set) var backgroundTaskActive = false
    @Published private(set) var route = "—"
    @Published private(set) var category = "chưa cấu hình"
    @Published private(set) var otherAudioPlaying = false

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var silentBuffer: AVAudioPCMBuffer?
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var wantsAudio = false
    private var configured = false

    private init() {
        installObservers()
        refreshSessionInfo()
    }

    // MARK: - Trạng thái

    /// Khoá `UIBackgroundModes` có thật trong Info.plist của bản đang chạy không.
    var hasBackgroundAudioMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("audio") ?? false
    }

    var isKeepingAlive: Bool {
        isAudioRunning
    }

    var stateText: String {
        if isAudioRunning { return "Đang giữ nền" }
        if wantsAudio { return "Bật nhưng audio chưa chạy" }
        return "Tắt"
    }

    var uptimeText: String {
        guard let startedAt else { return "—" }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours) giờ \(minutes) phút" }
        if minutes > 0 { return "\(minutes) phút" }
        return "\(seconds) giây"
    }

    // MARK: - Điều khiển

    /// Bật giữ nền. Gọi lại nhiều lần cũng an toàn.
    func start() {
        wantsAudio = true
        guard !isAudioRunning else {
            refreshSessionInfo()
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            category = "playback · mixWithOthers"

            try prepareEngine()
            guard let buffer = silentBuffer else {
                throw KeeperError.noBuffer
            }

            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }

            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            player.play()

            isAudioRunning = true
            startedAt = startedAt ?? Date()
            lastError = nil
            endGraceTask()
        } catch {
            isAudioRunning = false
            lastError = message(for: error)
        }

        refreshSessionInfo()
    }

    /// Tắt giữ nền và trả audio session cho hệ thống.
    func stop() {
        wantsAudio = false
        player.stop()
        engine.stop()
        isAudioRunning = false
        startedAt = nil
        endGraceTask()

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            category = "đã tắt"
        } catch {
            lastError = message(for: error)
        }

        refreshSessionInfo()
    }

    func toggle() {
        if wantsAudio || isAudioRunning { stop() } else { start() }
    }

    // MARK: - Vòng đời app (DevboxApp gọi)

    func appBecameActive() {
        endGraceTask()
        refreshSessionInfo()
        if wantsAudio && !isAudioRunning {
            start()
        }
    }

    func appBecameInactive() {
        // Đang chuyển tiếp (Control Center, cuộc gọi…). Không làm gì để tránh nhấp nháy audio.
        refreshSessionInfo()
    }

    func appDidEnterBackground() {
        guard wantsAudio else { return }
        start()
        if !isAudioRunning {
            // Audio không lên được → chỉ còn ~30 giây do iOS gia hạn.
            beginGraceTask()
        }
        refreshSessionInfo()
    }

    // MARK: - Audio engine

    private func prepareEngine() throws {
        guard !configured else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            throw KeeperError.noBuffer
        }

        buffer.frameLength = buffer.frameCapacity

        // Gần như im lặng (-100 dBFS, tai người không nghe thấy) nhưng **không phải
        // toàn số 0**, để hệ thống không coi đây là "buffer rỗng" và cắt phiên audio.
        var seed: UInt32 = 0x9E37_79B9
        if let channels = buffer.floatChannelData {
            for index in 0..<Int(buffer.frameLength) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let value = Float(Int32(bitPattern: seed)) / Float(Int32.max) * 1e-5
                for channel in 0..<Int(format.channelCount) {
                    channels[channel][index] = value
                }
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        silentBuffer = buffer
        configured = true
    }

    private func rebuildEngine() {
        player.stop()
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        silentBuffer = nil
        configured = false
        isAudioRunning = false
        if wantsAudio {
            start()
        }
    }

    private func refreshSessionInfo() {
        let session = AVAudioSession.sharedInstance()
        otherAudioPlaying = session.isOtherAudioPlaying
        let output = session.currentRoute.outputs.first
        route = output.map { "\($0.portName) (\($0.portType.rawValue))" } ?? "—"
        if isAudioRunning {
            category = "playback · mixWithOthers"
        }
    }

    // MARK: - Background task ngắn hạn (~30 giây)

    private func beginGraceTask() {
        guard taskID == .invalid else { return }
        backgroundTaskActive = true
        taskID = UIApplication.shared.beginBackgroundTask(withName: "devbox.keepalive") { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.backgroundTaskActive = false
                self.taskID = .invalid
                if self.wantsAudio && !self.isAudioRunning {
                    self.lastError = "iOS đã hết thời gian gia hạn nền và audio im lặng chưa chạy. App sẽ bị treo."
                }
            }
        }
    }

    private func endGraceTask() {
        guard taskID != .invalid else {
            backgroundTaskActive = false
            return
        }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
        backgroundTaskActive = false
    }

    // MARK: - Thông báo hệ thống

    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshSessionInfo()
            if self.wantsAudio && !self.isAudioRunning {
                self.start()
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.rebuildEngine()
        })

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.wantsAudio else { return }
            if !self.isAudioRunning {
                self.start()
                if !self.isAudioRunning { self.beginGraceTask() }
            }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            interruptionCount += 1
            isAudioRunning = false
            // Chỉ xin thêm thời gian khi đang ở nền; ở foreground không cần.
            if wantsAudio && UIApplication.shared.applicationState == .background {
                beginGraceTask()
            }
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if wantsAudio && (!isAudioRunning) {
                start()
            }
            if wantsAudio && !options.contains(.shouldResume) {
                // Hệ thống không cho tự resume; vẫn thử lại vì ta là audio im lặng.
                start()
            }
        @unknown default:
            break
        }
        refreshSessionInfo()
    }

    // MARK: - Helpers

    private func message(for error: Error) -> String {
        if let keeper = error as? KeeperError {
            return keeper.text
        }
        return error.localizedDescription
    }

    private enum KeeperError: Error {
        case noBuffer

        var text: String {
            switch self {
            case .noBuffer:
                return "Không tạo được buffer audio im lặng."
            }
        }
    }
}
