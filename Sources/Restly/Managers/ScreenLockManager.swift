import Foundation

/// 锁屏。
///
/// 走 login.framework 的 `SACLockScreenImmediate` —— 也就是 Ctrl+Cmd+Q 和
/// 苹果菜单「锁定屏幕」走的同一条路：由 loginwindow 负责那个淡入动画，
/// 显示器保持亮着，之后按系统自己的超时进入休眠。
///
/// 从前用的是 `pmset displaysleepnow`，那是直接切显示器背光：没有动画，
/// 所以会「先黑一下」；而且它本身并不锁屏 —— 锁不锁完全取决于用户有没有
/// 开「睡眠后立即要求密码」，设置项写着「锁定电脑」其实名不副实。
///
/// `SACLockScreenImmediate` 是私有符号，不在文档里，但十多年来一直稳定
/// （已在 macOS 26 上确认存在）。万一将来没了就退回 pmset：
/// 行为退化成从前那样，但不会崩，也不需要任何系统权限。
@MainActor
final class ScreenLockManager {
    private typealias LockScreenFunction = @convention(c) () -> Int32

    private static let systemLockScreen: LockScreenFunction? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            return nil
        }
        return unsafeBitCast(symbol, to: LockScreenFunction.self)
    }()

    func lockScreen() {
        if let lock = Self.systemLockScreen {
            let status = lock()
            guard status != 0 else { return }
            NSLog("Restly 调用系统锁屏返回 \(status)，改用显示器休眠。")
        }
        sleepDisplay()
    }

    private func sleepDisplay() {
        let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
        guard FileManager.default.isExecutableFile(atPath: pmsetURL.path) else {
            NSLog("Restly 无法找到 macOS 系统显示器睡眠工具。")
            return
        }

        let process = Process()
        process.executableURL = pmsetURL
        process.arguments = ["displaysleepnow"]

        do {
            try process.run()
        } catch {
            NSLog("Restly 无法锁定屏幕：\(error.localizedDescription)")
        }
    }
}
