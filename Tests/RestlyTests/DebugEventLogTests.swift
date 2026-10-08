import XCTest
@testable import Restly

/// 黑匣子日志：格式、追加语义与启动分隔行。
/// 「点了没反应」的悬案全靠它破案，写入路径本身也得有测试盯着。
final class DebugEventLogTests: XCTestCase {
    private func makeTemporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyLogTest-\(UUID().uuidString).log")
    }

    private func readAll(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    func testAppendsTimestampedLinesAcrossWrites() {
        let url = makeTemporaryLogURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var fixedDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let log = DebugEventLog(url: url, dateProvider: { fixedDate })

        log.log("第一条")
        fixedDate = fixedDate.addingTimeInterval(65)
        log.log("第二条")

        let lines = readAll(url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        // 行格式 [HH:mm:ss] 消息 —— 时间差 65 秒要体现在分钟进位上。
        XCTAssertTrue(lines[0].hasSuffix("] 第一条"), String(lines[0]))
        XCTAssertTrue(lines[1].hasSuffix("] 第二条"), String(lines[1]))
        XCTAssertNotEqual(lines[0].prefix(10), lines[1].prefix(10))
        for line in lines {
            XCTAssertTrue(line.hasPrefix("["), String(line))
        }
    }

    @MainActor
    func testSeparatorCarriesVersionInformation() {
        let url = makeTemporaryLogURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = DebugEventLog(url: url)
        log.logLaunchSeparator()

        let content = readAll(url)
        XCTAssertTrue(content.contains("Restly 启动"), content)
    }

    @MainActor
    func testAppendingToExistingFileKeepsHistory() throws {
        let url = makeTemporaryLogURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try "旧内容\n".write(to: url, atomically: true, encoding: .utf8)
        let log = DebugEventLog(url: url)
        log.log("新内容")

        let content = readAll(url)
        XCTAssertTrue(content.hasPrefix("旧内容\n"), "追加语义：不能覆盖既有日志")
        XCTAssertTrue(content.contains("] 新内容\n"))
    }
}
