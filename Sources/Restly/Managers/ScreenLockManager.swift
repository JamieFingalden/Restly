import Foundation

@MainActor
final class ScreenLockManager {
    private let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")

    func lockScreen() {
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
