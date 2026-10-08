import AppKit
import Foundation

/// 番茄钟与 macOS 专注模式的桥。
///
/// 联动的载体是两条固定名字的快捷指令（「设置专注模式」动作封装成
/// 开启/关闭各一条），执行走 `shortcuts` CLI —— 它只有 run / list /
/// view / sign 四个子命令、没有 import，所以「安装」= 运行时生成
/// `.shortcut` plist，先 `shortcuts sign` 签名（macOS 27 的快捷指令
/// App 拒收未签名文件，实测；sign 走默认 people-who-know-me，离线
/// 秒回），再交给系统打开、由快捷指令 App 弹预览，用户点一次
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
/// - 快捷指令的名字由设置注入（namesProvider）：用户可能早已手动建过
///   名字不同的两条指令，名字是唯一对接凭据，该由用户说了算，
///   默认值才是「Restly 专注开启/关闭」。
@MainActor
final class FocusModeBridge: ObservableObject {
    /// 出厂默认的快捷指令名字。只是默认值不是铁律 —— 用户可以
    /// 在设置里指认自己已有的任意两条指令。
    static let defaultOnShortcutName = "Restly 专注开启"
    static let defaultOffShortcutName = "Restly 专注关闭"

    /// 联动依赖的两条指令名字。名字就是它们的 API：run、存在性
    /// 检查、生成文件名、教程文案全部由此而来。
    struct ShortcutNames: Equatable, Sendable {
        var on: String
        var off: String
    }

    typealias NamesProvider = () -> ShortcutNames

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

    /// 一键创建的结局。失败必须带原因回去给界面展示 ——
    /// 静默降级教程曾让用户对着一个毫无动静的开关不知所措。
    enum InstallOutcome: Equatable {
        case opened
        case generationFailed(String)
        case openFailed(String)
        /// 用户在流程中途取消：已跳过剩余的外部副作用，
        /// 未打开的临时文件已清。
        case cancelled
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

    private let namesProvider: NamesProvider
    private let openHandler: (URL) -> Bool
    /// 两次打开之间的停顿：连开两个文件会让快捷指令 App 叠两个导入
    /// 预览互相抢占前台，中间留一秒让用户处理完第一条。
    private let interOpenDelay: TimeInterval

    /// 签名前拉起快捷指令 App（sign 走它的 XPC 服务）。可注入：
    /// 测试里数调用、不真拉 App。
    typealias AppRunningEnsurer = () async -> Void

    private let runner: ProcessRunner
    private let ensureAppRunning: AppRunningEnsurer
    private let workQueue = DispatchQueue(label: "com.restly.focus-mode-bridge")

    /// 一旦确认缺失就停止后续 run：用户删除快捷指令后，每次状态流转
    /// 都白起一个进程毫无意义，重建成功（或下次启动）才复位。
    private(set) var isMissing = false

    /// 最近一次存在性结论，执行侧与设置页共用同一份事实 ——
    /// 执行层已经知道指令没了，设置页不能还挂着旧的绿色「已就绪」。
    /// 只有 ready/missing 算结论，unknown 不覆盖旧值。
    @Published private(set) var lastKnownExistence: Existence?
    /// 最近一次真的问过系统（跑了 list）的时刻。缓存命中不算 ——
    /// 设置页的「上次检测」要反映数据的新鲜度。
    @Published private(set) var lastExistenceCheckDate: Date?

    /// 缓存连同当时的名字一起存：用户改指认名字后旧结论一律作废。
    private var existenceCache: (names: ShortcutNames, result: Existence, timestamp: Date)?

    /// 熔断从 true → false（就绪检测复位）时回调一次。PomodoroManager
    /// 借此重跑联动结算：用户「装好指令时正在计时的这段专注」要补上
    /// 开启，否则要等下一次流转才有机会。
    var onMissingCleared: (() -> Void)?

    init(
        runner: ProcessRunner? = nil,
        namesProvider: @escaping NamesProvider = {
            ShortcutNames(on: FocusModeBridge.defaultOnShortcutName, off: FocusModeBridge.defaultOffShortcutName)
        },
        focusTargetProvider: @escaping () -> FocusTarget? = FocusModeBridge.readFocusTargetFromSystem,
        existenceCacheTTL: TimeInterval = 60,
        openHandler: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        interOpenDelay: TimeInterval = 1.0,
        ensureAppRunning: AppRunningEnsurer? = nil,
        synchronousLauncher: @escaping (_ arguments: [String]) throws -> Void = FocusModeBridge.launchProcess
    ) {
        self.runner = runner ?? Self.defaultRunner(workQueue: workQueue)
        self.namesProvider = namesProvider
        self.focusTargetProvider = focusTargetProvider
        self.existenceCacheTTL = existenceCacheTTL
        self.openHandler = openHandler
        self.interOpenDelay = interOpenDelay
        self.ensureAppRunning = ensureAppRunning ?? Self.wakeShortcutsAppInBackground
        self.synchronousLauncher = synchronousLauncher
    }

    /// 退出路径的同步子进程启动器，注入以便测试记录 argv。
    private let synchronousLauncher: (_ arguments: [String]) throws -> Void

    /// 后台拉起快捷指令 App（不抢焦点），再留一秒余量等它的 XPC
    /// 服务可用 —— sign 依赖 App 在跑，否则报误导性的「格式不正确」。
    ///
    /// 刻意用回调版 openApplication 而不是 `try await`：回调在个别
    /// 状态下可能永不到来，第六轮「点了没反应、零文件零日志」的
    /// 现场里这是头号嫌疑 —— 安装链绝不能陪一个系统回调挂死，
    /// 拉不起来的后果由首签失败的重试兜住，最坏也只是报错。
    @MainActor
    static func wakeShortcutsAppInBackground() async {
        DebugEventLog.shared.log("联动安装：后台拉起快捷指令 App")
        let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSLog("Restly 唤起快捷指令 App 失败：\(error.localizedDescription)")
            }
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// 当前生效的两条指令名字。每次现取 —— 设置里改完立刻生效，
    /// 不需要谁记得通知 bridge。
    var names: ShortcutNames { namesProvider() }

    // MARK: - 联动执行

    /// 执行开启/关闭快捷指令。已确认缺失时直接短路，不再起进程。
    func setFocusEngaged(_ engaged: Bool) async -> Result<Void, LinkageError> {
        guard !isMissing else { return .failure(.missing) }
        let currentNames = names
        let name = engaged ? currentNames.on : currentNames.off
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

    /// 检查当前指认的两条快捷指令是否都已就位。带 TTL 缓存，且缓存
    /// 与名字绑定 —— 改了指认名单旧结论作废；`forceRefresh` 给安装
    /// 确认轮询用，那里要的就是绕过缓存的新答案。
    func checkShortcutsExist(forceRefresh: Bool = false) async -> Existence {
        let currentNames = names
        if !forceRefresh, let cache = existenceCache,
           cache.names == currentNames,
           Date().timeIntervalSince(cache.timestamp) < existenceCacheTTL {
            resetMissingIfReady(cache.result)
            return cache.result
        }

        guard let available = await listShortcutNames() else {
            recordExistence(.unknown)
            return .unknown
        }
        let present = Set(available)
        let result: Existence = present.isSuperset(of: [currentNames.on, currentNames.off])
            ? .ready
            : .missing
        existenceCache = (currentNames, result, Date())
        recordExistence(result)
        resetMissingIfReady(result)
        return result
    }

    /// 一次 `shortcuts list` 的原始名单（去空白行）。nil 表示没跑成。
    /// 设置页的「从已有快捷指令中选择」靠它给选项。
    func listShortcutNames() async -> [String]? {
        let (status, output) = await run(["list"])
        guard status == 0 else {
            NSLog("Restly 无法列出快捷指令（\(status)）：\(output)")
            return nil
        }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 当前名字里哪条缺失。教程「我已创建完成」与超时文案都要点名。
    func missingShortcutNames() async -> [String] {
        let currentNames = names
        guard let available = await listShortcutNames() else {
            return [currentNames.on, currentNames.off]
        }
        let present = Set(available)
        return [currentNames.on, currentNames.off].filter { !present.contains($0) }
    }

    /// 退出专用：同步 fire-and-forget 地拉起关闭子进程。
    ///
    /// willTerminate 之后主 actor 随时可能停摆，任何 Task/await 排队
    /// 都可能没轮到执行，专注模式就被留在开着的状态 —— Process.run()
    /// 同步把子进程拉起（不 waitUntilExit），它独立于父进程存活。
    /// 拉起失败只留痕：下次启动恢复 running focus 时会重新联动。
    func launchOffShortcutSynchronously() {
        let currentNames = names
        do {
            try synchronousLauncher(["/usr/bin/shortcuts", "run", currentNames.off])
            DebugEventLog.shared.log("退出：已同步拉起关闭指令「\(currentNames.off)」")
        } catch {
            DebugEventLog.shared.log("退出：拉起关闭指令失败 —— \(error.localizedDescription)")
            NSLog("Restly 退出时无法执行关闭快捷指令：\(error.localizedDescription)")
        }
    }

    nonisolated private static func launchProcess(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        try process.run()
    }

    // MARK: - 一键创建

    /// 生成两个 `.shortcut` 文件并交给系统打开（快捷指令 App 弹预览）。
    /// 每种失败都带原因返回，由设置页映射成明确文案 —— 绝不静默吞掉。
    /// 安装是否完成由后续的 `confirmInstalled()` 有界轮询确认 ——
    /// 用户点不点「添加快捷指令」只有系统知道，这里不猜。
    func installShortcuts() async -> InstallOutcome {
        let currentNames = names
        DebugEventLog.shared.log("联动安装：进入（目标「\(currentNames.on)」「\(currentNames.off)」）")
        sweepStaleTemporaryDirectories()
        let files: [URL]
        do {
            files = try generateShortcutFiles()
        } catch {
            DebugEventLog.shared.log("联动安装：生成失败 —— \(error.localizedDescription)")
            NSLog("Restly 生成专注模式快捷指令文件失败：\(error.localizedDescription)")
            return .generationFailed(error.localizedDescription)
        }
        guard files.count == 2 else {
            DebugEventLog.shared.log("联动安装：生成结果不完整（\(files.count) 个文件）")
            return .generationFailed("生成结果不完整（\(files.count) 个文件）")
        }
        DebugEventLog.shared.log("联动安装：已生成待签文件 \(files.map(\.lastPathComponent).joined(separator: "、"))")
        // 快捷指令 App 拒收未签名文件，而 sign 又依赖 App 在跑
        //（实测：App 退出时签名必失败，报错误导人的「格式不正确」）
        // —— 签名前先把它拉起来；首签失败再补一次拉起 + 重试。
        await ensureAppRunning()
        var openedCount = 0
        for file in files {
            if Task.isCancelled {
                // 取消后不得再有外部副作用：没签的不再签，没开的不再开。
                cancelRemainder(of: files, openedCount: openedCount)
                return .cancelled
            }
            if await signShortcutFile(at: file) != nil {
                // 首签失败常见于 App 还没就绪：补一次拉起再试，仍败才报。
                DebugEventLog.shared.log("联动安装：「\(file.lastPathComponent)」首签失败，补拉 App 后重试")
                await ensureAppRunning()
                if let retryFailure = await signShortcutFile(at: file) {
                    DebugEventLog.shared.log("联动安装：重签仍失败 —— \(retryFailure)")
                    cleanupTemporaryFiles(files)
                    return .generationFailed(retryFailure)
                }
            }
            DebugEventLog.shared.log("联动安装：「\(file.lastPathComponent)」已签名")
        }
        if Task.isCancelled {
            cancelRemainder(of: files, openedCount: openedCount)
            return .cancelled
        }
        DebugEventLog.shared.log("联动安装：打开「\(currentNames.on).shortcut」")
        guard openHandler(files[0]) else {
            DebugEventLog.shared.log("联动安装：打开「\(currentNames.on).shortcut」失败")
            cleanupTemporaryFiles(files)
            NSLog("Restly 无法打开快捷指令文件：\(files[0].path)")
            return .openFailed("无法打开「\(currentNames.on).shortcut」")
        }
        openedCount = 1
        if interOpenDelay > 0 {
            // 两个预览叠在一起会互相抢占前台，中间留一秒。
            try? await Task.sleep(for: .seconds(interOpenDelay))
        }
        if Task.isCancelled {
            // 第一条已经交出去（预览归系统管），只清还没打开的。
            cancelRemainder(of: files, openedCount: openedCount)
            return .cancelled
        }
        DebugEventLog.shared.log("联动安装：打开「\(currentNames.off).shortcut」")
        guard openHandler(files[1]) else {
            DebugEventLog.shared.log("联动安装：打开「\(currentNames.off).shortcut」失败")
            cleanupTemporaryFiles(files)
            NSLog("Restly 无法打开快捷指令文件：\(files[1].path)")
            return .openFailed("无法打开「\(currentNames.off).shortcut」")
        }
        DebugEventLog.shared.log("联动安装：两个文件都已交给系统，等待用户确认导入")
        return .opened
    }

    /// 取消后的收尾：只清尚未交给系统的剩余文件（已打开的预览归
    /// 系统管，删了会让预览失效）。
    private func cancelRemainder(of files: [URL], openedCount: Int) {
        DebugEventLog.shared.log("联动安装：检测到取消，跳过剩余步骤")
        for file in files.dropFirst(openedCount) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 就地签名：`shortcuts sign`（默认 people-who-know-me 模式，无网络
    /// 依赖）签到临时名，再把原路径换成签名产物 —— 调用方拿到的仍是
    /// 同一组 `.shortcut` 路径。失败带退出码与输出回去，绝不静默。
    ///
    /// ⚠️ sign 的输入文件必须带 `.shortcut` 扩展名：实测同内容文件改成
    /// `.unsigned` 就会报「The file couldn't be opened because it isn't in
    /// the correct format」（与「快捷指令 App 没在跑」同款误导性报错）。
    /// 本实现源路径与输出路径都刻意保留扩展名，动这两个路径时别丢了。
    private func signShortcutFile(at url: URL) async -> String? {
        let workingURL = url.deletingLastPathComponent()
            .appendingPathComponent("signed-" + url.lastPathComponent)
        let (status, output) = await run([
            "sign", "-i", url.path, "-o", workingURL.path,
        ])
        guard status == 0 else {
            try? FileManager.default.removeItem(at: workingURL)
            return "签名失败（shortcuts 退出码 \(status)）：\(output)"
        }
        do {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: workingURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: workingURL)
            return "签名后替换文件失败：\(error.localizedDescription)"
        }
        return nil
    }

    /// 临时目录清场：无论哪一步失败，都别把半成品留在 tmp 里。
    /// 只删文件会留下空壳目录（实测清过一轮目录还在），目录一并删。
    private func cleanupTemporaryFiles(_ files: [URL]) {
        var directories: Set<URL> = []
        for file in files {
            directories.insert(file.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: file)
        }
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 清扫更早夭折的安装残留。崩溃、强退或链路挂死都会留下
    /// RestlyFocusShortcuts-* 目录，任何清理逻辑都救不了「没跑到」
    /// 的那次 —— 每次安装开始时把一天前的残留扫掉。
    private func sweepStaleTemporaryDirectories() {
        let temporary = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for item in contents where item.lastPathComponent.hasPrefix("RestlyFocusShortcuts-") {
            let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > 86_400 {
                DebugEventLog.shared.log("联动安装：清扫陈旧临时目录 \(item.lastPathComponent)")
                try? FileManager.default.removeItem(at: item)
            }
        }
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

    /// 生成开启/关闭两个 plist。FocusTarget 读不到就抛错（理论不再
    /// 发生：readFocusTarget 有静态勿扰兜底，这层 guard 纯防御），
    /// 由调用方决定降级（一键创建失败 ≠ 功能不可用，还有手动教程）。
    func generateShortcutFiles() throws -> [URL] {
        guard let target = focusTargetProvider() else {
            throw LinkageError.noFocusTarget
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusShortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let currentNames = names
        let onURL = directory.appendingPathComponent("\(currentNames.on).shortcut")
        let offURL = directory.appendingPathComponent("\(currentNames.off).shortcut")
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
    ///
    /// 参数逐字节对齐系统 UI 写出的格式（从 Shortcuts.sqlite 的
    /// ZSHORTCUTACTIONS.ZDATA 提取、实测 run 双双 exit 0）：
    /// - 开 = Enabled: 1 + FocusModes；关 = 仅 FocusModes（UI 写「关闭」
    ///   时不带任何开关位，写了多余键反而未经验证）；
    /// - 不写 Operation / UUID —— 我们猜的 Turn On/Turn Off 从未在真机
    ///   上验证过，系统模板里也没有；
    /// - FocusModes 的 DisplayString 是运行时的解析键，必须等于模式在
    ///   用户系统里的实际显示名（Identifier 只是陪衬）。
    static func makeWorkflow(enable: Bool, target: FocusTarget) -> [String: Any] {
        var parameters: [String: Any] = [
            "FocusModes": [
                "Identifier": target.identifier,
                "DisplayString": target.displayName,
            ],
        ]
        if enable {
            parameters["Enabled"] = 1
        }
        let action: [String: Any] = [
            "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
            "WFWorkflowActionParameters": parameters,
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

    /// 两大「核心」模式的 identifier：名字是系统起的、随本地化变化，
    /// 运行时按显示名解析必然踩本地化坑，只能靠 localizedDoNotDisturbName
    /// 硬映射。其余模式（哪怕基于系统预设改的，如 graduationcapfill 的
    /// "learn"）名字都是用户自己起的、稳定可用 —— 判定标准是「这个名字
    /// 是否稳定」，不是 identifier 是否内置。
    nonisolated static let coreModeIdentifiers: Set<String> = [
        "com.apple.donotdisturb.mode.default",
        "com.apple.sleep.sleep-mode",
    ]

    /// 挑选规则（层层兜底）：
    /// 1. 名字带「专注 / Focus / Work / 工作」—— 用户的意图明写在那里；
    /// 2. 任何非核心模式 —— DisplayString 即解析键且稳定（实测 "learn"
    ///   可用）；多个时取第一个；
    /// 3. 核心勿扰兜底 —— DisplayString 写本地化显示名（实测写规范名
    ///   "Do Not Disturb" 在中文系统上运行时报「不存在名为…的专注
    ///   模式」），映射不到就原样写并靠教程提示兜底。
    /// 勿扰的显示名：本地化映射命中用之；未覆盖语言（nl/pl 等）回退
    /// 规范英文名 —— DisplayString 是运行时的名字解析键，中文兜底在
    /// 非中文系统上必然「不存在名为勿扰模式的专注模式」。回退时记
    /// 黑匣子一行，教程「导入后确认目标」就是这条路的出路。
    nonisolated private static func resolveDoNotDisturbDisplayName(
        preferredLanguages: [String]
    ) -> String {
        if let localized = localizedDoNotDisturbName(preferredLanguages: preferredLanguages) {
            return localized
        }
        DebugEventLog.shared.log("联动安装：语言未覆盖本地化映射，回退英文名，导入后需确认目标模式")
        return "Do Not Disturb"
    }

    nonisolated static func readFocusTarget(
        at url: URL,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> FocusTarget? {
        // 最终兜底：勿扰模式的 identifier 全系统恒定，不依赖这份文件 ——
        // 文件读取可能因打包身份被系统拒绝（实测：同一构建，终端启动的
        // 进程读得到，open/Finder 启动的被拒，授权随签名身份漂移）。
        // 一键创建永远不能死在「读不到配置」这一步。
        let fallback = FocusTarget(
            identifier: "com.apple.donotdisturb.mode.default",
            displayName: resolveDoNotDisturbDisplayName(preferredLanguages: preferredLanguages)
        )

        guard FileManager.default.fileExists(atPath: url.path) else {
            DebugEventLog.shared.log("联动安装：专注模式配置文件不存在（\(url.path)），用勿扰兜底")
            return fallback
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            DebugEventLog.shared.log("联动安装：专注模式配置读取失败 —— \(error.localizedDescription)，用勿扰兜底")
            return fallback
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else {
            DebugEventLog.shared.log("联动安装：专注模式配置解析失败，用勿扰兜底")
            return fallback
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
        guard !modes.isEmpty else {
            DebugEventLog.shared.log("联动安装：专注模式配置里没有任何模式，用勿扰兜底")
            return fallback
        }

        let preferredNames = ["专注", "Focus", "Work", "工作"]
        if let preferred = modes.first(where: { preferredNames.contains($0.displayName) }) {
            return preferred
        }
        if let stable = modes.first(where: { !coreModeIdentifiers.contains($0.identifier) }) {
            return stable
        }
        guard let dnd = modes.first(where: { $0.identifier == "com.apple.donotdisturb.mode.default" }) else {
            // 名单里连勿扰都没有：静态勿扰兜底照给（identifier 恒定）。
            DebugEventLog.shared.log("联动安装：配置里没有勿扰模式，用静态勿扰兜底")
            return fallback
        }
        return FocusTarget(
            identifier: dnd.identifier,
            displayName: resolveDoNotDisturbDisplayName(preferredLanguages: preferredLanguages)
        )
    }

    /// 系统勿扰模式的本地化显示名（运行时按它匹配）。按用户首选语言
    /// 找不到映射时返回 nil，让调用方退回规范名。
    nonisolated static func localizedDoNotDisturbName(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String? {
        for language in preferredLanguages {
            // 中文要区分简繁（zh-Hans / zh-Hant），其余语言取首段即可。
            let parts = language.split(separator: "-")
            let code: String
            if parts.first == "zh" {
                code = parts.prefix(2).joined(separator: "-")
            } else {
                code = String(parts.first ?? "")
            }
            switch code {
            case "zh-Hans": return "勿扰模式"
            case "zh-Hant": return "勿擾模式"
            case "ja": return "おやすみモード"
            case "ko": return "방해 금지 모드"
            case "en": return "Do Not Disturb"
            case "fr": return "Ne pas déranger"
            case "de": return "Nicht stören"
            case "es": return "No molestar"
            case "ru": return "Не беспокоить"
            case "pt": return "Não Perturbar"
            case "it": return "Non disturbare"
            default: continue
            }
        }
        return nil
    }

    // MARK: - 进程执行

    private func markMissing() {
        isMissing = true
        lastKnownExistence = .missing
        lastExistenceCheckDate = Date()
        let currentNames = names
        DebugEventLog.shared.log("联动熔断：未检测到「\(currentNames.on)」「\(currentNames.off)」，停止重试")
        NSLog("Restly 未检测到快捷指令「\(currentNames.on)」「\(currentNames.off)」，联动停止重试，直到重新创建。")
    }

    private func recordExistence(_ result: Existence) {
        lastExistenceCheckDate = Date()
        if result != .unknown {
            lastKnownExistence = result
        }
    }

    /// 检查（无论走缓存还是真跑）给出 .ready 就复位熔断 —— 不变量是
    /// 「UI 显示就绪，执行就不能短路」：用户照指引手动建好指令/改对
    /// 指认后，不复位的话执行会一直缺席直到重启。缓存命中的 ready
    /// 同样算数；unknown 不复位（没证据就别动开关）。
    private func resetMissingIfReady(_ result: Existence) {
        guard result == .ready, isMissing else { return }
        isMissing = false
        DebugEventLog.shared.log("联动熔断复位：检测到两条指令均已就位")
        onMissingCleared?()
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
    /// internal 只为测试：直测「大输出不死锁」的并发消费契约。
    nonisolated static func defaultRunner(workQueue: DispatchQueue) -> ProcessRunner {
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

                // 必须先并发消费管道、后等退出：子进程输出超过 64KB 管道
                // 缓冲会写阻塞，先 waitUntilExit 的话两边互相等到天荒地老
                // —— 串行队列上这条命令永远占位，后面所有联动指令全部
                // 排队到重启（用户指认的指令可以输出文本/图片/文件，
                // 不只我们自己的 list）。读取线程阻塞到 EOF，与
                // waitUntilExit 在 group.wait 汇合成一个 join 点，无竞态。
                final class OutputBuffer: @unchecked Sendable {
                    var data = Data()
                }
                let buffer = OutputBuffer()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.waitUntilExit()
                group.wait()

                // stdout + stderr 合并收一份：list 的名字和报错文案都在
                // 里面，失败时输出继续用于诊断。
                let text = String(decoding: buffer.data, as: UTF8.self)
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    completion(status, text)
                }
            }
        }
    }
}
