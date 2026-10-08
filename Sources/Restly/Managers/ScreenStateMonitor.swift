import AppKit

/// 「人在不在电脑前」的唯一事实来源。
///
/// Restly 不自己数键鼠。这个判断整个外包给 macOS：锁屏、显示器睡眠、系统睡眠、
/// 切换用户，任意一个发生都视为人已离开。
///
/// 这么做比自己数键鼠 idle 准，因为播放器、会议软件、演示软件都会主动持有
/// `PreventUserIdleDisplaySleep` 断言告诉系统「别关屏，人在看」。于是看视频、
/// 开会时屏幕不会睡，也就不会被误判成离开 —— 这个信息自己数键鼠拿不到。
///
/// 副作用是常态下零轮询：不锁屏就一个通知都不来，进程完全不用醒。
@MainActor
final class ScreenStateMonitor: NSObject {
    /// 屏幕变为不可用（锁屏 / 息屏 / 睡眠 / 切换用户）时调用。
    var onUnavailable: (() -> Void)?
    /// 屏幕重新可用时调用，参数是这次离开持续了多久。
    var onAvailable: ((TimeInterval) -> Void)?

    private(set) var isAvailable = true
    private var unavailableSince: Date?

    // com.apple.screenIsLocked / Unlocked 不是正式文档 API，但十多年来一直稳定，
    // 也是 macOS 上唯一能拿到「主动锁屏」的途径 ——
    // NSWorkspace 的 sessionDidResignActive 只覆盖快速用户切换，锁屏不会触发它。
    private static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    private static let leaveNotifications: [Notification.Name] = [
        NSWorkspace.screensDidSleepNotification,
        NSWorkspace.willSleepNotification,
        NSWorkspace.sessionDidResignActiveNotification
    ]

    private static let returnNotifications: [Notification.Name] = [
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.didWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification
    ]

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in Self.leaveNotifications {
            workspace.addObserver(self, selector: #selector(screenDidLeave), name: name, object: nil)
        }
        for name in Self.returnNotifications {
            workspace.addObserver(self, selector: #selector(screenDidReturn), name: name, object: nil)
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLeave), name: Self.screenLocked, object: nil)
        distributed.addObserver(self, selector: #selector(screenDidReturn), name: Self.screenUnlocked, object: nil)
    }

    /// 供 `--development-mode` 之类的场景手工驱动。
    func simulateLeave() { screenDidLeave() }
    func simulateReturn() { screenDidReturn() }

    @objc private func screenDidLeave() {
        // 多个通知常常一起来（息屏 + 锁屏），只认第一个，避免把离开时长重置掉。
        guard isAvailable else { return }
        isAvailable = false
        unavailableSince = Date()
        onUnavailable?()
    }

    @objc private func screenDidReturn() {
        guard !isAvailable else { return }
        isAvailable = true
        // 这里认「屏幕醒了」而不是只认「解锁了」：没配密码锁的机器上
        // screenIsUnlocked 永远不会来，只听它会导致计时再也不恢复。
        let duration = unavailableSince.map { Date().timeIntervalSince($0) } ?? 0
        unavailableSince = nil
        onAvailable?(max(0, duration))
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
