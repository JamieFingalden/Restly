import AppKit
import Foundation

/// 番茄钟与 macOS 专注模式的桥。
///
/// 联动的载体是两条固定名字的快捷指令（「设置专注模式」动作封装成
/// 开启/关闭各一条），执行走 `shortcuts` CLI —— 它只有 run / list /
/// view / sign 四个子命令、没有 import，所以「安装」只能生成
/// `.shortcut` 文件交给系统打开，由快捷指令 App 弹预览、用户点一次
/// 「添加快捷指令」。这是系统唯一开放的路，不碰任何私有 API。
///
/// 设计取舍：
/// - 零轮询。运行期的成败本身就是存在性检查 —— `shortcuts run` 一个
///   不存在的指令会以非零退出，此时才补一次（带 TTL 缓存的）
///   `shortcuts list` 来区分「缺失」与「其它失败」，之后置 `isMissing`
///   停止后续重试，避免每个状态流转都白跑进程。
/// - 进程全部异步、同一时刻最多一个：执行器在串行后台队列里
///   `waitUntilExit`，主线程只收结果。参照 ScreenLockManager 跑
///   pmset 的既有模式，绝不阻塞。
/// - 动作标识符 `is.workflow.actions.dnd.set` 与参数键（Operation /
///   Enabled / FocusModes）是在本机 WorkflowKit 运行时上查证的
///   （WFActionDefinitionRegistry 的 Set Focus 注册表项），
///   专注模式的目标值从 `~/Library/DoNotDisturb/DB/ModeConfigurations.json`
///   只读解析，读不到就放弃一键创建、退到手动教程，不硬凑。
@MainActor
final class FocusModeBridge: ObservableObject {
    /// 快捷指令的名字就是它们的 API：生成文件、存在性检查、教程文案
    /// 全部引用这两个常量，改名等于同时断掉三处。
    static let onShortcutName = "Restly 专注开启"
    static let offShortcutName = "Restly 专注关闭"

    /// 联动执行的失败种类。missing 会触发「重新创建」引导，其余只留痕。
    enum LinkageError: Error, Equatable {
        /// 快捷指令不存在（或被删了）。run 与 list 双重确认过。
        case missing
        /// 其它失败（比如指令跑了但动作本身出错）：不打扰用户。
        case failed(status: Int32, output: String)
        /// 系统里读不到可用的专注模式目标，一键创建无从生成文件。
        case noFocusTarget
    }

    /// 存在性检查的结论。unknown 表示连 list 都没能跑成，别下断言。
    enum Existence: Equatable {
        case ready
        case missing
        case unknown
    }

    /// 一键创建用的专注模式目标：reverse-DNS 的 modeIdentifier 是
    /// 快捷指令真正引用的值，名字只用于展示与教程文案。
    struct FocusTarget: Equatable, Sendable {
        let identifier: String
        let displayName: String
    }

    /// 进程执行器。参数是完整 argv，回调带回退出码与合并后的标准输出/错误。
    /// 回调不绑执行者（默认实现在主队列上回调），可注入以便测试桩替换，
    /// 真实进程的串行化由默认实现保证。
    typealias ProcessRunner = @Sendable (_ arguments: [String], _ completion: @escaping @Sendable (Int32, String) -> Void) -> Void

    /// 存在性结果的 TTL。设置页开关流程里的重复检查与失败确认
    /// 都落在缓存上，同一分钟内不会重复起 list 进程。
    private let existenceCacheTTL: TimeInterval

    /// 联动的目标专注模式来源，注入以便测试。默认读系统的
    /// ModeConfigurations.json（只读）。
    private let focusTargetProvider: () -> FocusTarget?

    private let runner: ProcessRunner
    private let workQueue = DispatchQueue(label: "com.restly.focus-mode-bridge")

    /// 一旦确认缺失就停止后续 run：用户删除快捷指令后，每次状态流转
    /// 都白起一个进程毫无意义，重建成功（或下次启动）才复位。
    private(set) var isMissing = false

    private var existenceCache: (result: Existence, timestamp: Date)?

    init(
        runner: ProcessRunner? = nil,
        focusTargetProvider: @escaping () -> FocusTarget? = FocusModeBridge.readFocusTargetFromSystem,
        existenceCacheTTL: TimeInterval = 60
    ) {
        self.runner = runner ?? Self.defaultRunner(workQueue: workQueue)
        self.focusTargetProvider = focusTargetProvider
        self.existenceCacheTTL = existenceCacheTTL
    }

    // MARK: - 联动执行

    /// 执行开启/关闭快捷指令。已确认缺失时直接短路，不再起进程。
    func setFocusEngaged(_ engaged: Bool) async -> Result<Void, LinkageError> {
        guard !isMissing else { return .failure(.missing) }
        let name = engaged ? Self.onShortcutName : Self.offShortcutName
        let (status, output) = await run(["run", name])
        guard status == 0 else {
            // run 失败本身不足以断言缺失（也可能是动作内部报错），
            // 补一次带缓存的存在性检查再定性。
            let existence = await checkShortcutsExist()
            if existence == .missing {
                markMissing()
                return .failure(.missing)
            }
            NSLog("Restly 专注模式快捷指令「\(name)」执行失败（\(status)）：\(output)")
            return .failure(.failed(status: status, output: output))
        }
        return .success(())
    }

    /// 检查两条快捷指令是否都已就位。带 TTL 缓存；`forceRefresh`
    /// 给安装确认轮询用 —— 那里要的就是绕过缓存的新答案。
    func checkShortcutsExist(forceRefresh: Bool = false) async -> Existence {
        if !forceRefresh, let cache = existenceCache,
           Date().timeIntervalSince(cache.timestamp) < existenceCacheTTL {
            return cache.result
        }

        let (status, output) = await run(["list"])
        guard status == 0 else {
            NSLog("Restly 无法列出快捷指令（\(status)）：\(output)")
            return .unknown
        }
        let names = Set(output.split(separator: "\n").map(String.init))
        let result: Existence = names.isSuperset(of: [Self.onShortcutName, Self.offShortcutName])
            ? .ready
            : .missing
        existenceCache = (result, Date())
        return result
    }

    // MARK: - 一键创建

    /// 生成两个 `.shortcut` 文件并交给系统打开（快捷指令 App 弹预览）。
    /// 返回 false 表示连打开都没成（或生成失败），调用方退到教程路线。
    /// 安装是否完成由后续的 `confirmInstalled()` 有界轮询确认 ——
    /// 用户点不点「添加快捷指令」只有系统知道，这里不猜。
    func installShortcuts() async -> Bool {
        guard let files = try? generateShortcutFiles() else {
            NSLog("Restly 无法生成专注模式快捷指令文件，退回手动教程。")
            return false
        }
        for file in files {
            guard NSWorkspace.shared.open(file) else {
                NSLog("Restly 无法打开快捷指令文件：\(file.path)")
                return false
            }
        }
        return true
    }

    /// 安装确认：清掉缓存与缺失标记后重新检查。轮询里检测到就绪即停。
    func confirmInstalled() async -> Bool {
        existenceCache = nil
        let existence = await checkShortcutsExist(forceRefresh: true)
        if existence == .ready {
            isMissing = false
            return true
        }
        return false
    }

    /// 生成开启/关闭两个 plist。FocusTarget 读不到就抛错，
    /// 由调用方决定降级（一键创建失败 ≠ 功能不可用，还有手动教程）。
    func generateShortcutFiles() throws -> [URL] {
        guard let target = focusTargetProvider() else {
            throw LinkageError.noFocusTarget
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusShortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let onURL = directory.appendingPathComponent("\(Self.onShortcutName).shortcut")
        let offURL = directory.appendingPathComponent("\(Self.offShortcutName).shortcut")
        try writeWorkflow(Self.makeWorkflow(enable: true, target: target), to: onURL)
        try writeWorkflow(Self.makeWorkflow(enable: false, target: target), to: offURL)
        return [onURL, offURL]
    }

    private func writeWorkflow(_ workflow: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: workflow,
            format: .binary,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    /// 单个「设置专注模式」动作的工作流文件。
    /// Operation 是新版主参数（Turn On / Turn Off / Toggle），Enabled 是
    /// 旧版的开关位 —— 两处都写上且保持一致，老版本客户端与新版本都认。
    /// FocusModes 用 {Identifier, DisplayString}：系统按 reverse-DNS 的
    /// modeIdentifier 引用模式，名字仅作展示。导入后用户可在快捷指令
    /// App 里自由改成别的专注模式。
    static func makeWorkflow(enable: Bool, target: FocusTarget) -> [String: Any] {
        let action: [String: Any] = [
            "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
            "WFWorkflowActionParameters": [
                "UUID": "D4E7A1F0-6C3B-4E8A-9F2D-\(enable ? "000000000001" : "000000000002")",
                "Operation": enable ? "Turn On" : "Turn Off",
                "Enabled": enable,
                "FocusModes": [
                    "Identifier": target.identifier,
                    "DisplayString": target.displayName,
                ],
            ],
        ]

        return [
            "WFWorkflowActions": [action],
            "WFWorkflowClientVersion": "2607.1.3",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": [
                "WFWorkflowIconStartColor": 4271458815,
                "WFWorkflowIconGlyphNumber": 61440,
            ],
            "WFWorkflowImportQuestions": [] as [[String: Any]],
            "WFWorkflowTypes": [] as [String],
            "WFWorkflowInputContentItemClasses": [
                "WFAppContentItem",
                "WFAppStoreAppContentItem",
                "WFArticleContentItem",
                "WFContactContentItem",
                "WFDateContentItem",
                "WFEmailAddressContentItem",
                "WFFolderContentItem",
                "WFGenericFileContentItem",
                "WFImageContentItem",
                "WFiTunesProductContentItem",
                "WFLocationContentItem",
                "WFDCMapsLinkContentItem",
                "WFAVAssetContentItem",
                "WFPDFContentItem",
                "WFPhoneNumberContentItem",
                "WFRichTextContentItem",
                "WFSafariWebPageContentItem",
                "WFStringContentItem",
                "WFURLContentItem",
            ],
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowHasShortcutInputVariables": false,
            "WFQuickActionSurfaces": [] as [String],
            "WFWorkflowOutputContentItemClasses": [] as [String],
        ]
    }

    // MARK: - 专注模式目标

    /// 只读解析系统的专注模式配置，挑联动默认目标。整个文件缺失或
    /// 结构对不上就返回 nil：一键创建退到教程，不该为此崩或弹框。
    /// nonisolated：只碰文件与 JSON，主线程外也能安全调用（默认参数
    /// 表达式要求如此）。
    nonisolated static func readFocusTargetFromSystem() -> FocusTarget? {
        readFocusTarget(
            at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/DoNotDisturb/DB/ModeConfigurations.json")
        )
    }

    /// 挑选规则：优先名字带「专注 / Focus / Work / 工作」的自定义模式
    /// （有自定义模式说明用户真的在用专注模式工作），否则退到系统自带
    /// 的「勿扰模式」—— 它在每个 macOS 上都存在。
    nonisolated static func readFocusTarget(at url: URL) -> FocusTarget? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else {
            return nil
        }

        var modes: [FocusTarget] = []
        for entry in entries {
            guard let configurations = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (_, configuration) in configurations {
                guard let configuration = configuration as? [String: Any],
                      let mode = configuration["mode"] as? [String: Any],
                      let name = mode["name"] as? String,
                      let identifier = mode["modeIdentifier"] as? String else { continue }
                modes.append(FocusTarget(identifier: identifier, displayName: name))
            }
        }
        guard !modes.isEmpty else { return nil }

        let preferredNames = ["专注", "Focus", "Work", "工作"]
        if let preferred = modes.first(where: { preferredNames.contains($0.displayName) }) {
            return preferred
        }
        return modes.first { $0.identifier == "com.apple.donotdisturb.mode.default" }
    }

    // MARK: - 进程执行

    private func markMissing() {
        isMissing = true
        NSLog("Restly 未检测到专注模式快捷指令，联动停止重试，直到重新创建。")
    }

    private func run(_ arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            runner(["/usr/bin/shortcuts"] + arguments) { status, output in
                continuation.resume(returning: (status, output))
            }
        }
    }

    /// 默认执行器：串行后台队列上起进程并等它退出 —— 排队即串行，
    /// 同一时刻最多一个 shortcuts 进程；主线程只负责收结果。
    private static func defaultRunner(workQueue: DispatchQueue) -> ProcessRunner {
        return { arguments, completion in
            workQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: arguments[0])
                process.arguments = Array(arguments.dropFirst())

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    DispatchQueue.main.async {
                        completion(-1, "无法启动 shortcuts：\(error.localizedDescription)")
                    }
                    return
                }
                process.waitUntilExit()
                // stdout + stderr 合并收一份：list 的名字和报错文案都在里面。
                // 输出量远小于管道缓冲（几千行名字才写满），等退出后一次读
                // 没有竞态。
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

                let status = process.terminationStatus
                DispatchQueue.main.async {
                    completion(status, output)
                }
            }
        }
    }
}
