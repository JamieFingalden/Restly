import Foundation

/// 追加式黑匣子日志（~/Library/Logs/Restly.log）。
///
/// 只为一件事：下次「点了没反应」时有据可查。联动安装链横跨
/// SwiftUI 呈现状态、后台进程与系统 App，哪一环吞了点击都曾经
/// 只能靠猜（还猜过是不是跑错了实例）；现在每个关键节点落一行，
/// 任何一次点击都能对出真相。行格式 `[HH:mm:ss] 消息`，每次启动
/// 写一行分隔 —— 日志是跨启动追加的，靠它分段。
///
/// 写失败只 NSLog 留痕：日志是诊断工具，绝不能反过来把功能搞挂。
@MainActor
final class DebugEventLog {
    /// 默认落在用户的 Logs 目录（Console.app 能直接看到）。
    nonisolated static var defaultURL: URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
        return (logsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true))
            .appendingPathComponent("Restly.log")
    }

    static let shared = DebugEventLog(url: defaultURL)

    private let url: URL
    private let dateProvider: () -> Date

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(url: URL, dateProvider: @escaping () -> Date = Date.init) {
        self.url = url
        self.dateProvider = dateProvider
    }

    func log(_ message: String) {
        let line = "[\(Self.timestampFormatter.string(from: dateProvider()))] \(message)\n"
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            NSLog("Restly 事件日志写入失败：\(error.localizedDescription)")
        }
    }

    /// 启动分隔行。带版本与构建号 —— 分不清手里跑的是哪次构建的
    /// 教训刚过去不久。
    func logLaunchSeparator() {
        let version = AppVersionText.displayText(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        log("──────── Restly 启动 v\(version) ────────")
    }
}
