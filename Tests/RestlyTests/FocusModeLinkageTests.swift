import XCTest
@testable import Restly

/// 番茄钟 × 专注模式联动的行为矩阵。快捷指令是外部进程，
/// 测试通过注入 ProcessRunner 桩观察「发了什么命令」，执行器串行化、
/// 缺失熔断这些逻辑跑的是 FocusModeBridge 真实现。
final class FocusModeLinkageTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 3_000)

    // MARK: - 执行器桩

    /// @unchecked Sendable 只是为了能被 @Sendable 执行器闭包捕获；
    /// 测试里所有调用都发生在主线程，无需加锁。
    private final class RunnerStub: @unchecked Sendable {
        struct Invocation {
            let command: String
            let name: String
        }

        private(set) var invocations: [Invocation] = []
        /// 按次出队的应答；耗尽后走默认成功应答。
        private var responses: [(status: Int32, output: String)] = []

        init(responses: [(Int32, String)] = []) {
            self.responses = responses
        }

        var runner: FocusModeBridge.ProcessRunner {
            { [self] arguments, completion in
                // argv[0] 是 /usr/bin/shortcuts，后面才是子命令与名字。
                let rest = Array(arguments.dropFirst())
                invocations.append(Invocation(command: rest.first ?? "", name: rest.count > 1 ? rest[1] : ""))
                let response = responses.isEmpty ? (Int32(0), "") : responses.removeFirst()
                completion(response.0, response.1)
            }
        }
    }

    @MainActor
    private func makeDefaults(enablingLinkage: Bool = false) -> (UserDefaults, String) {
        let suiteName = "FocusModeLinkageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if enablingLinkage {
            defaults.set(true, forKey: "pomodoroLinksFocusMode")
        }
        return (defaults, suiteName)
    }

    @MainActor
    private func makeBridge(
        runner: @escaping FocusModeBridge.ProcessRunner,
        names: FocusModeBridge.ShortcutNames = .init(
            on: FocusModeBridge.defaultOnShortcutName,
            off: FocusModeBridge.defaultOffShortcutName
        ),
        target: FocusModeBridge.FocusTarget? = FocusModeBridge.FocusTarget(
            identifier: "com.apple.donotdisturb.mode.default",
            displayName: "Do Not Disturb"
        ),
        openHandler: @escaping (URL) -> Bool = { _ in true },
        interOpenDelay: TimeInterval = 0
    ) -> FocusModeBridge {
        FocusModeBridge(
            runner: runner,
            namesProvider: { names },
            focusTargetProvider: { target },
            openHandler: openHandler,
            interOpenDelay: interOpenDelay
        )
    }

    @MainActor
    private func makeManager(
        defaults: UserDefaults,
        bridge: FocusModeBridge,
        settings: ReminderSettings? = nil,
        now: Date = Date(timeIntervalSinceReferenceDate: 3_000)
    ) -> PomodoroManager {
        PomodoroManager(
            settings: settings ?? ReminderSettings(defaults: defaults),
            toastManager: ToastManager(),
            runtimeConfiguration: RuntimeConfiguration(isDevelopmentMode: false, showsEyeRestOnLaunch: false),
            defaults: defaults,
            focusModeBridge: bridge,
            now: now
        )
    }

    /// 联动走的是 MainActor 上的 fire-and-forget Task，
    /// 测试让出执行器几轮，等那条链（Task → 桩应答 → 收尾）走完。
    @MainActor
    private func drain() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private func runCalls(in stub: RunnerStub) -> [RunnerStub.Invocation] {
        stub.invocations.filter { $0.command == "run" }
    }

    // MARK: - 边沿触发矩阵

    @MainActor
    func testStartFocusEngagesAndPauseDisengagesResumeReengages() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub()
        let manager = makeManager(defaults: defaults, bridge: makeBridge(runner: stub.runner))
        await drain()
        // 初始空闲，恢复期不该有任何调用。
        XCTAssertTrue(stub.invocations.isEmpty)

        manager.startFocus()
        await drain()
        XCTAssertEqual(runCalls(in: stub).map(\.name), ["Restly 专注开启"])

        manager.pause()
        await drain()
        XCTAssertEqual(runCalls(in: stub).map(\.name), ["Restly 专注开启", "Restly 专注关闭"])

        manager.resume()
        await drain()
        XCTAssertEqual(runCalls(in: stub).last?.name, "Restly 专注开启")
    }

    @MainActor
    func testSkipAndStopDisengage() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub()
        let manager = makeManager(defaults: defaults, bridge: makeBridge(runner: stub.runner))
        await drain()

        manager.startFocus()
        manager.skip()
        await drain()
        // 专注被跳过落到休息就绪态：联动关闭。
        XCTAssertEqual(runCalls(in: stub).map(\.name), ["Restly 专注开启", "Restly 专注关闭"])

        manager.startFocus()
        manager.stop()
        await drain()
        XCTAssertEqual(runCalls(in: stub).last?.name, "Restly 专注关闭")
    }

    @MainActor
    func testAutoTransitionDisengagesIntoBreakAndReengagesIntoFocus() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // 休息结束自动开始专注，才能测出「休息 → 专注」的再开启边沿。
        defaults.set(true, forKey: "pomodoroAutoStartFocus")
        let stub = RunnerStub()
        let manager = makeManager(defaults: defaults, bridge: makeBridge(runner: stub.runner))
        await drain()

        manager.startFocus()
        // startFocus 按真实时钟落 endsAt，注入时刻必须在其之后才算到期。
        // 专注自然到期，自动开始休息：联动应关。
        manager.fireIfDue(now: Date().addingTimeInterval(30 * 60))
        await drain()
        XCTAssertEqual(runCalls(in: stub).map(\.name), ["Restly 专注开启", "Restly 专注关闭"])

        // 休息自然到期，自动开始下一个专注：联动应再开。
        manager.fireIfDue(now: Date().addingTimeInterval(60 * 60))
        await drain()
        XCTAssertEqual(runCalls(in: stub).last?.name, "Restly 专注开启")
    }

    @MainActor
    func testLockFreezeDisengagesAndUnlockReengages() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub()
        let manager = makeManager(defaults: defaults, bridge: makeBridge(runner: stub.runner))
        await drain()

        manager.startFocus()
        manager.screenDidBecomeUnavailable()
        await drain()
        XCTAssertEqual(runCalls(in: stub).map(\.name), ["Restly 专注开启", "Restly 专注关闭"])

        manager.screenDidBecomeAvailable(after: 60)
        await drain()
        XCTAssertEqual(runCalls(in: stub).last?.name, "Restly 专注开启")
    }

    @MainActor
    func testTogglingSettingMidRunFollowsImmediately() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub()
        let settings = ReminderSettings(defaults: defaults)
        let manager = makeManager(defaults: defaults, bridge: makeBridge(runner: stub.runner), settings: settings)
        await drain()

        manager.startFocus()
        await drain()
        XCTAssertTrue(runCalls(in: stub).isEmpty, "联动开关没开时不应有任何快捷指令调用")

        // 计时中打开开关：立即开启联动。
        settings.pomodoroLinksFocusMode = true
        await drain()
        XCTAssertEqual(runCalls(in: stub).map(\.name), ["Restly 专注开启"])

        // 计时中再关掉：立即执行关闭快捷指令恢复原状，不等下一次流转。
        settings.pomodoroLinksFocusMode = false
        await drain()
        XCTAssertEqual(runCalls(in: stub).map(\.name), ["Restly 专注开启", "Restly 专注关闭"])
        XCTAssertFalse(manager.hasShownFocusLinkageWarning)
    }

    @MainActor
    func testRestartWithRunningFocusReengages() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let endsAt = origin.addingTimeInterval(20 * 60)
        defaults.set("focus", forKey: "pomodoroPhase")
        defaults.set("running", forKey: "pomodoroStatus")
        defaults.set(endsAt, forKey: "pomodoroEndsAt")

        let stub = RunnerStub()
        let manager = makeManager(defaults: defaults, bridge: makeBridge(runner: stub.runner), now: origin)
        await drain()

        XCTAssertEqual(
            runCalls(in: stub).map(\.name),
            ["Restly 专注开启"],
            "重启恢复出计时中的专注应重新开启联动"
        )
        guard case .running = manager.session.status else {
            return XCTFail("存档未过期时应恢复为计时中")
        }
    }

    // MARK: - 缺失熔断

    @MainActor
    func testMissingShortcutStopsRetriesAndWarnsOncePerLaunch() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // run 失败 + list 也找不到：判定缺失并熔断。
        let stub = RunnerStub(responses: [
            (1, "Error: 未能完成该操作。找不到快捷指令"),   // run 开启
            (0, "别的快捷指令\n"),                            // list：没有 Restly 两条
        ])
        let manager = makeManager(defaults: defaults, bridge: makeBridge(runner: stub.runner))
        await drain()

        manager.startFocus()
        await drain()

        XCTAssertTrue(manager.hasShownFocusLinkageWarning, "缺失应弹一次提醒")
        XCTAssertEqual(stub.invocations.count, 2, "run + list 各一次")

        // 熔断后继续流转：不再起新进程，也不再重复提醒。
        manager.pause()
        manager.resume()
        manager.stop()
        await drain()

        XCTAssertEqual(stub.invocations.count, 2)
        XCTAssertTrue(manager.hasShownFocusLinkageWarning)
    }

    // MARK: - 名字可配置

    /// 用户手动建的指令（名字与出厂默认不同）按名字指认后必须能被
    /// 识别并直接执行 —— 这正是 P0-C 要打通的场景。
    @MainActor
    func testConfiguredNamesDriveRunAndDetection() async {
        let stub = RunnerStub(responses: [
            (0, ""),                              // run 开启
            (0, "设定专注模式\n关闭专注模式\n别的指令\n"),  // list
        ])
        let bridge = makeBridge(
            runner: stub.runner,
            names: .init(on: "设定专注模式", off: "关闭专注模式")
        )

        let runResult = await bridge.setFocusEngaged(true)
        guard case .success = runResult else {
            return XCTFail("指认的名字应当被用于 run，实际 \(runResult)")
        }
        XCTAssertEqual(stub.invocations.first?.name, "设定专注模式")

        let existence = await bridge.checkShortcutsExist()
        XCTAssertEqual(existence, .ready, "按名字指认的已有指令应识别为就绪")
    }

    @MainActor
    func testPartialNameMatchReportsMissingAndNamesTheGap() async {
        let stub = RunnerStub(responses: [
            (0, "设定专注模式\n别的指令\n"),   // list：只有开启那条
            (0, "设定专注模式\n别的指令\n"),   // missingNames 复核时再 list 一次
        ])
        let bridge = makeBridge(
            runner: stub.runner,
            names: .init(on: "设定专注模式", off: "关闭专注模式")
        )

        let existence = await bridge.checkShortcutsExist()
        XCTAssertEqual(existence, .missing)
        let missing = await bridge.missingShortcutNames()
        XCTAssertEqual(missing, ["关闭专注模式"], "要点名缺的是哪条")
    }

    @MainActor
    func testExistenceCacheInvalidatesWhenNamesChange() async {
        var names = FocusModeBridge.ShortcutNames(on: "A", off: "B")
        let stub = RunnerStub(responses: [
            (0, "A\nB\n"),                       // 第一次 list：ready
            (0, "设定专注模式\n别的指令\n"),      // 改名后的 list：missing
        ])
        let bridge = FocusModeBridge(runner: stub.runner, namesProvider: { names })

        _ = await bridge.checkShortcutsExist()
        names = .init(on: "设定专注模式", off: "关闭专注模式")
        let afterRename = await bridge.checkShortcutsExist()

        XCTAssertEqual(afterRename, .missing, "改了指认名字后旧缓存结论必须作废")
        XCTAssertEqual(stub.invocations.filter { $0.command == "list" }.count, 2)
    }

    // MARK: - 一键创建的结局必须可见

    @MainActor
    func testInstallOpensBothFilesInOrderAndReportsOpened() async {
        var opened: [String] = []
        var removed: Set<String> = []
        let bridge = makeBridge(
            runner: RunnerStub().runner,
            names: .init(on: "设定专注模式", off: "关闭专注模式"),
            openHandler: { url in
                opened.append(url.lastPathComponent)
                removed.insert(url.lastPathComponent)
                return true
            }
        )

        let outcome = await bridge.installShortcuts()

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(opened, ["设定专注模式.shortcut", "关闭专注模式.shortcut"], "两次打开的顺序就是开启、关闭")
    }

    @MainActor
    func testInstallReportsGenerationFailureWithReason() async {
        let bridge = makeBridge(runner: RunnerStub().runner, target: nil)

        let outcome = await bridge.installShortcuts()

        guard case .generationFailed(let reason) = outcome else {
            return XCTFail("读不到专注模式目标应报 generationFailed，实际 \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty, "失败原因要能拿去给用户看")
    }

    @MainActor
    func testInstallReportsOpenFailureWithShortcutName() async {
        let bridge = makeBridge(
            runner: RunnerStub().runner,
            names: .init(on: "设定专注模式", off: "关闭专注模式"),
            openHandler: { _ in false }
        )

        let outcome = await bridge.installShortcuts()

        guard case .openFailed(let reason) = outcome else {
            return XCTFail("打不开文件应报 openFailed，实际 \(outcome)")
        }
        XCTAssertTrue(reason.contains("设定专注模式"), "失败文案要点名哪条没打开")
    }

    // MARK: - FocusModeBridge 本体

    @MainActor
    func testSetFocusEngagedRunsShortcutAndSuccessPasses() async {
        let stub = RunnerStub()
        let bridge = makeBridge(runner: stub.runner)

        let result = await bridge.setFocusEngaged(true)

        guard case .success = result else {
            return XCTFail("默认成功应答应返回 success，实际 \(result)")
        }
        XCTAssertEqual(stub.invocations.map(\.command), ["run"])
        XCTAssertEqual(stub.invocations.map(\.name), ["Restly 专注开启"])
    }

    @MainActor
    func testRunFailureWithBothShortcutsPresentIsNotMissing() async {
        // run 失败但 list 里两条都在：其它失败，只留痕不熔断。
        let stub = RunnerStub(responses: [
            (1, "动作执行失败"),
            (0, "Restly 专注开启\nRestly 专注关闭\n"),
        ])
        let bridge = makeBridge(runner: stub.runner)

        let result = await bridge.setFocusEngaged(false)

        guard case .failure(.failed(let status, let output)) = result else {
            return XCTFail("run 失败且指令都在时应归类为 failed，实际 \(result)")
        }
        XCTAssertEqual(status, 1)
        XCTAssertEqual(output, "动作执行失败")
        XCTAssertFalse(bridge.isMissing, "其它失败不该停止后续重试")
    }

    @MainActor
    func testExistenceCheckCachesWithinTTL() async {
        let stub = RunnerStub()
        let bridge = FocusModeBridge(
            runner: stub.runner,
            focusTargetProvider: { nil },
            existenceCacheTTL: 60
        )

        let first = await bridge.checkShortcutsExist()
        let second = await bridge.checkShortcutsExist()

        XCTAssertEqual(first, .missing)
        XCTAssertEqual(second, .missing)
        XCTAssertEqual(stub.invocations.filter { $0.command == "list" }.count, 1, "TTL 内的第二次检查不该再起进程")
    }

    @MainActor
    func testConfirmInstalledClearsMissingFlag() async {
        let stub = RunnerStub(responses: [
            (1, "找不到快捷指令"),                       // run
            (0, ""),                                     // list：缺失
            (0, "Restly 专注开启\nRestly 专注关闭\n"),   // confirmInstalled 的 list
        ])
        let bridge = makeBridge(runner: stub.runner)

        _ = await bridge.setFocusEngaged(true)
        XCTAssertTrue(bridge.isMissing)

        let confirmed = await bridge.confirmInstalled()

        XCTAssertTrue(confirmed)
        XCTAssertFalse(bridge.isMissing, "重建成功应解除熔断")
        // 解除后能正常再执行。
        let again = await bridge.setFocusEngaged(false)
        guard case .success = again else {
            return XCTFail("熔断解除后应能正常执行，实际 \(again)")
        }
    }

    @MainActor
    func testGeneratedWorkflowCarriesVerifiedActionFormat() throws {
        let target = FocusModeBridge.FocusTarget(identifier: "com.apple.focus.learn", displayName: "learn")
        let workflow = FocusModeBridge.makeWorkflow(enable: true, target: target)

        let actions = try XCTUnwrap(workflow["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(actions[0]["WFWorkflowActionIdentifier"] as? String),
            "is.workflow.actions.dnd.set",
            "「设置专注模式」的动作标识符，已在本机 WorkflowKit 注册表上查证"
        )
        let parameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(parameters["Operation"] as? String), "Turn On")
        XCTAssertEqual(try XCTUnwrap(parameters["Enabled"] as? Bool), true)
        let focus = try XCTUnwrap(parameters["FocusModes"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(focus["Identifier"] as? String), "com.apple.focus.learn")
        XCTAssertEqual(try XCTUnwrap(focus["DisplayString"] as? String), "learn")

        // 关闭文件用同一动作、相反参数。
        let off = FocusModeBridge.makeWorkflow(enable: false, target: target)
        let offParameters = try XCTUnwrap(
            ((off["WFWorkflowActions"] as? [[String: Any]])?[0]["WFWorkflowActionParameters"] as? [String: Any])
        )
        XCTAssertEqual(try XCTUnwrap(offParameters["Operation"] as? String), "Turn Off")
        XCTAssertEqual(try XCTUnwrap(offParameters["Enabled"] as? Bool), false)
    }

    @MainActor
    func testGenerateShortcutFilesWritesParseablePlists() throws {
        let bridge = makeBridge(runner: RunnerStub().runner)
        let files = try bridge.generateShortcutFiles()
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].lastPathComponent, "Restly 专注开启.shortcut")
        XCTAssertEqual(files[1].lastPathComponent, "Restly 专注关闭.shortcut")

        for (file, operation) in zip(files, ["Turn On", "Turn Off"]) {
            let data = try Data(contentsOf: file)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            let actions = try XCTUnwrap(plist as? [String: Any])["WFWorkflowActions"] as? [[String: Any]]
            let parameters = try XCTUnwrap(actions?[0]["WFWorkflowActionParameters"] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(parameters["Operation"] as? String), operation)
        }
    }

    @MainActor
    func testGenerateShortcutFilesThrowsWithoutFocusTarget() async {
        let bridge = makeBridge(runner: RunnerStub().runner, target: nil)
        do {
            _ = try bridge.generateShortcutFiles()
            XCTFail("读不到专注模式目标应抛错，让调用方退到教程路线")
        } catch {
            // 预期路径。
        }
    }

    // MARK: - 专注模式目标解析

    func testFocusTargetParsingPrefersFocusLikeNames() throws {
        let fixture = """
        {"data": [{"modeConfigurations": {
            "com.apple.donotdisturb.mode.default": {"mode": {"name": "Do Not Disturb", "modeIdentifier": "com.apple.donotdisturb.mode.default"}},
            "com.apple.focus.learn": {"mode": {"name": "learn", "modeIdentifier": "com.apple.focus.learn"}}
        }}]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try XCTUnwrap(FocusModeBridge.readFocusTarget(at: url))
        XCTAssertEqual(target.identifier, "com.apple.donotdisturb.mode.default")
        // 名字表（专注/Focus/Work/工作）都没有时退回系统勿扰，别乱挑。
    }

    func testFocusTargetParsingFallsBackToDNDThenNil() throws {
        let noPreferred = """
        {"data": [{"modeConfigurations": {
            "com.apple.focus.work": {"mode": {"name": "工作", "modeIdentifier": "com.apple.focus.work"}},
            "com.apple.donotdisturb.mode.default": {"mode": {"name": "Do Not Disturb", "modeIdentifier": "com.apple.donotdisturb.mode.default"}}
        }}]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-\(UUID().uuidString).json")
        try noPreferred.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // 「工作」在优先名单里，应被选中而不是勿扰。
        let target = try XCTUnwrap(FocusModeBridge.readFocusTarget(at: url))
        XCTAssertEqual(target.identifier, "com.apple.focus.work")

        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-\(UUID().uuidString).json")
        try "not json".data(using: .utf8)!.write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        XCTAssertNil(FocusModeBridge.readFocusTarget(at: garbage))
    }
}
