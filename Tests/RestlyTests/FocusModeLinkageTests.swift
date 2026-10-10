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
            /// /usr/bin/shortcuts 之后的完整 argv，供 sign 参数断言用。
            let argv: [String]
        }

        private(set) var invocations: [Invocation] = []
        /// 按次出队的应答；耗尽后走默认成功应答。
        private var responses: [(status: Int32, output: String)] = []
        /// 挂住所有 run 命令不回结果（模拟 enable 在飞）。
        private let holdRuns: Bool
        /// 只挂第一条 run（模拟最老的开启指令慢于后续所有操作）。
        private let holdFirstRun: Bool
        private let heldLock = NSLock()
        private var heldCompletions: [@Sendable (Int32, String) -> Void] = []
        /// 释放所有挂起的 run（模拟慢 enable 终于跑完），可指定结果。
        func releaseHeldRuns(status: Int32 = 0, output: String = "") {
            heldLock.lock()
            let pending = heldCompletions
            heldCompletions = []
            heldLock.unlock()
            pending.forEach { $0(status, output) }
        }
        /// 每次 sign 调用前回调（序号从 0 起），供测试在精确时机取消。
        var signGate: ((Int) -> Void)?

        init(
            responses: [(Int32, String)] = [],
            holdRuns: Bool = false,
            holdFirstRun: Bool = false
        ) {
            self.responses = responses
            self.holdRuns = holdRuns
            self.holdFirstRun = holdFirstRun
        }

        var runner: FocusModeBridge.ProcessRunner {
            { [self] arguments, onProcessExit, completion in
                // argv[0] 是 /usr/bin/shortcuts，后面才是子命令与参数。
                let rest = Array(arguments.dropFirst())
                invocations.append(Invocation(
                    command: rest.first ?? "",
                    name: rest.count > 1 ? rest[1] : "",
                    argv: rest
                ))
                let isRun = rest.first == "run"
                let isFirstRun = isRun
                    && invocations.filter { $0.command == "run" }.count == 1
                if isRun, holdRuns || (holdFirstRun && isFirstRun) {
                    // 挂起：子进程退出信号与完成回调一起存起来，
                    // 等 releaseHeldRuns 按序触发。
                    heldLock.lock()
                    // 挂起条目转发释放时给定的结果（失败回滚测试要用）。
                    let entry: @Sendable (Int32, String) -> Void = { [onProcessExit, completion] status, output in
                        onProcessExit()
                        completion(status, output)
                    }
                    heldCompletions.append(entry)
                    heldLock.unlock()
                    return
                }
                if rest.first == "sign" {
                    let signCount = invocations.filter { $0.command == "sign" }.count
                    signGate?(signCount - 1)
                }
                onProcessExit()
                let response = responses.isEmpty ? (Int32(0), "") : responses.removeFirst()
                // 模拟真 sign 的契约：成功时要在 -o 位置产出文件，
                // 否则 bridge 的「签名后写回原路径」无从谈起。
                if rest.first == "sign", response.0 == 0,
                   let inputIndex = rest.firstIndex(of: "-i"),
                   let outputIndex = rest.firstIndex(of: "-o"),
                   rest.count > max(inputIndex, outputIndex) + 1 {
                    try? FileManager.default.copyItem(
                        atPath: rest[inputIndex + 1],
                        toPath: rest[outputIndex + 1]
                    )
                }
                completion(response.0, response.1)
            }
        }
    }

    /// 记录 bridge 拉起快捷指令 App 的次数。
    private final class AppWakeCounter: @unchecked Sendable {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// 记录退出路径同步启动器的完整 argv（可注入抛错验证失败路径）。
    private final class SyncLaunchRecorder: @unchecked Sendable {
        private(set) var argvList: [[String]] = []
        private(set) var lastLaunchDate: Date?
        let error: Error?
        init(shouldFail: Bool = false) {
            error = shouldFail ? NSError(domain: "test", code: 1) : nil
        }
        func record(_ arguments: [String]) throws {
            argvList.append(arguments)
            lastLaunchDate = Date()
            if let error { throw error }
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
        interOpenDelay: TimeInterval = 0,
        appWakeCount: AppWakeCounter? = nil,
        syncLaunchRecorder: SyncLaunchRecorder? = nil
    ) -> FocusModeBridge {
        FocusModeBridge(
            runner: runner,
            namesProvider: { names },
            focusTargetProvider: { target },
            openHandler: openHandler,
            interOpenDelay: interOpenDelay,
            ensureAppRunning: { appWakeCount?.record() },
            synchronousLauncher: { arguments in
                if let syncLaunchRecorder {
                    try syncLaunchRecorder.record(arguments)
                } else {
                    // 测试没显式指认时也不能真拉起系统进程。
                    NSLog("测试桩拦截同步启动：\(arguments)")
                }
            }
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

    // MARK: - 状态发布（设置页与执行侧共用事实）

    /// 执行层确认缺失时必须把结论广播出去 —— 设置页开着时不能
    /// 还挂着旧的绿色「已就绪」。
    @MainActor
    func testMissingExecutionUpdatesPublishedStateForOpenSettings() async {
        let stub = RunnerStub(responses: [
            (1, "找不到快捷指令"),   // run 失败
            (0, ""),                // list：缺失
        ])
        let bridge = makeBridge(runner: stub.runner)
        XCTAssertNil(bridge.lastKnownExistence, "没查过就不该有结论")

        _ = await bridge.setFocusEngaged(true)

        XCTAssertEqual(bridge.lastKnownExistence, .missing)
        XCTAssertNotNil(bridge.lastExistenceCheckDate)
    }

    /// unknown（连 list 都没跑成）不覆盖旧结论，但检测时间要刷新 ——
    /// 时间戳是用户判断「这条结论多新鲜」的依据。
    @MainActor
    func testUnknownCheckKeepsPreviousConclusionButRefreshesDate() async {
        let stub = RunnerStub(responses: [
            (0, "A\nB\n"),   // list：就绪
            (1, "boom"),      // 强制重检时 list 失败
        ])
        let bridge = makeBridge(runner: stub.runner, names: .init(on: "A", off: "B"))

        _ = await bridge.checkShortcutsExist()
        XCTAssertEqual(bridge.lastKnownExistence, .ready)
        let firstDate = bridge.lastExistenceCheckDate

        let second = await bridge.checkShortcutsExist(forceRefresh: true)

        XCTAssertEqual(second, .unknown)
        XCTAssertEqual(bridge.lastKnownExistence, .ready, "unknown 不覆盖旧结论")
        XCTAssertNotEqual(bridge.lastExistenceCheckDate, firstDate)
    }

    // MARK: - 退出路径同步拉起（codex 评审 ③）

    @MainActor
    func testTerminateLaunchesOffShortcutSynchronouslyOnlyWhenEngaged() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SyncLaunchRecorder()
        let bridge = makeBridge(runner: RunnerStub().runner, syncLaunchRecorder: recorder)
        let manager = makeManager(defaults: defaults, bridge: bridge)
        await drain()

        // 没联动时退出：不该拉任何东西。
        manager.handleAppWillTerminate()
        XCTAssertEqual(recorder.argvList, [], "未联动时退出不应执行指令")

        manager.startFocus()
        await drain()
        manager.handleAppWillTerminate()
        XCTAssertEqual(recorder.argvList.count, 1)
        XCTAssertEqual(
            recorder.argvList.first,
            ["/usr/bin/shortcuts", "run", "Restly 专注关闭"],
            "退出要同步拉起关闭指令"
        )

        // 再触发一次不该重复（联动已在退出时视为关闭）。
        manager.handleAppWillTerminate()
        XCTAssertEqual(recorder.argvList.count, 1)
    }

    @MainActor
    func testSyncLaunchFailureIsContainedWithoutCrashing() {
        let recorder = SyncLaunchRecorder(shouldFail: true)
        let bridge = makeBridge(runner: RunnerStub().runner, syncLaunchRecorder: recorder)
        // 抛错必须在 bridge 内被吃掉（留痕即可），不能炸出调用方。
        bridge.launchOffShortcutSynchronously()
        XCTAssertEqual(recorder.argvList.count, 1)
    }

    // MARK: - 熔断复位（codex 评审 ①）

    @MainActor
    func testReadyExistenceCheckResetsMissingCircuitBreaker() async {
        let stub = RunnerStub(responses: [
            (1, "找不到快捷指令"),   // run 失败
            (0, ""),                // list：缺失 → 熔断
            (0, "设定专注模式\n关闭专注模式\n"),  // 用户补齐后的检查 → ready
            (0, ""),                // 复位后的真正执行
        ])
        let bridge = makeBridge(
            runner: stub.runner,
            names: .init(on: "设定专注模式", off: "关闭专注模式")
        )

        _ = await bridge.setFocusEngaged(true)
        XCTAssertTrue(bridge.isMissing)

        // 用户恢复走的是设置页的强制重检路径（教程完成/重新检测按钮）。
        let existence = await bridge.checkShortcutsExist(forceRefresh: true)
        XCTAssertEqual(existence, .ready)
        XCTAssertFalse(bridge.isMissing, "检测到就绪应复位熔断，否则执行继续短路直到重启")

        let result = await bridge.setFocusEngaged(true)
        guard case .success = result else {
            return XCTFail("熔断复位后应真正执行，实际 \(result)")
        }
        XCTAssertEqual(stub.invocations.filter { $0.command == "run" }.count, 2, "第二次 run 要真的跑出去")
    }

    // MARK: - 安装等待页让位语义（codex 评审 ②）

    func testInstallSheetPresentationStateYieldsToOutcome() {
        // 结局未定：到点呈现等待页；结局已定：让位（nil），终态由结局任务写。
        XCTAssertEqual(
            SettingsView.installSheetPresentationState(hasOutcome: false),
            .waiting(remainingSeconds: 30)
        )
        XCTAssertNil(SettingsView.installSheetPresentationState(hasOutcome: true))
    }

    /// 轮询写等待页前的取消闸：Esc 关掉又被弹回来的 bug 缺的就是它。
    func testWaitingSheetUpdateGateHonoursCancellation() {
        XCTAssertNil(SettingsView.waitingSheetUpdate(isCancelled: true, remainingSeconds: 12))
        XCTAssertEqual(
            SettingsView.waitingSheetUpdate(isCancelled: false, remainingSeconds: 12),
            .waiting(remainingSeconds: 12)
        )
    }

    /// ① 中途开联动碰上缺失、随后装好：本段专注要被补上开启指令，
    /// 而不是拖到下一段（期望态/已应用态分离 + 熔断复位钩子）。
    @MainActor
    func testMidRunEnableWithMissingThenInstallEngagesCurrentSession() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub(responses: [
            (1, "找不到快捷指令"),                    // 中途开联动首跑失败
            (0, ""),                                 // list 缺失 → 熔断
            (0, "设定专注模式\n关闭专注模式\n"),       // 安装确认 → ready → 复位+钩子
            (0, ""),                                 // 钩子触发的补执行
            (0, ""),                                 // 停止时的关闭
        ])
        let settings = ReminderSettings(defaults: defaults)
        let bridge = makeBridge(
            runner: stub.runner,
            names: .init(on: "设定专注模式", off: "关闭专注模式")
        )
        let manager = makeManager(defaults: defaults, bridge: bridge, settings: settings)
        await drain()

        manager.startFocus()
        settings.pomodoroLinksFocusMode = true
        await drain()
        XCTAssertTrue(bridge.isMissing, "首跑失败 + list 缺失应熔断")
        XCTAssertEqual(runCalls(in: stub).map(\.name), ["设定专注模式"])

        // 用户装好指令：安装确认复位熔断，钩子带 manager 重跑结算。
        bridge.onMissingCleared = { manager.syncFocusLinkage() }
        let confirmed = await bridge.confirmInstalled()
        XCTAssertTrue(confirmed)
        await drain()

        XCTAssertEqual(
            runCalls(in: stub).map(\.name),
            ["设定专注模式", "设定专注模式"],
            "本段专注要补上开启指令"
        )

        // applied 已跟上：停止能正常执行关闭。
        manager.stop()
        await drain()
        XCTAssertEqual(runCalls(in: stub).last?.name, "关闭专注模式")
    }

    // MARK: - 管道并发消费（codex 三轮 ①）

    /// 子进程输出超过 64KB 管道缓冲时，先 waitUntilExit 的旧实现会
    /// 死锁（子进程写阻塞 vs 父进程等退出）——这条用 200KB 输出钉住
    /// 「先并发读、后等退出」的契约。defaultRunner internal 即为此。
    func testDefaultRunnerDrainsLargeChildOutput() async {
        let workQueue = DispatchQueue(label: "FocusModeLinkageTests.runner")
        let runner = FocusModeBridge.defaultRunner(workQueue: workQueue)
        final class OutputBox: @unchecked Sendable {
            var status: Int32?
            var output = ""
        }
        let box = OutputBox()
        let expectation = XCTestExpectation(description: "默认执行器返回大输出")
        runner(["/bin/sh", "-c", "head -c 200000 /dev/zero | base64"], {}) { status, output in
            box.status = status
            box.output = output
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 30)
        XCTAssertEqual(box.status, 0)
        XCTAssertGreaterThan(box.output.utf8.count, 128 * 1024, "超过管道缓冲的输出必须完整收回")
    }

    func testDefaultRunnerPropagatesFailureStatusAndOutput() async {
        let workQueue = DispatchQueue(label: "FocusModeLinkageTests.runner")
        let runner = FocusModeBridge.defaultRunner(workQueue: workQueue)
        final class OutputBox: @unchecked Sendable {
            var status: Int32?
            var output = ""
        }
        let box = OutputBox()
        let expectation = XCTestExpectation(description: "默认执行器带回失败输出")
        runner(["/bin/sh", "-c", "echo boom; exit 3"], {}) { status, output in
            box.status = status
            box.output = output
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 30)
        XCTAssertEqual(box.status, 3)
        XCTAssertTrue(box.output.contains("boom"), "失败输出要用于诊断")
    }

    // MARK: - 取消不留外部副作用（codex 三轮 ②）

    /// 首签一完成就取消：第二次签名、两次打开都必须被拦下。
    @MainActor
    func testInstallCancellationAfterFirstSignSkipsAllOpens() async {
        let stub = RunnerStub()
        final class TaskBox: @unchecked Sendable {
            var task: Task<FocusModeBridge.InstallOutcome, Never>?
        }
        let taskBox = TaskBox()
        stub.signGate = { index in
            if index == 0 { taskBox.task?.cancel() }
        }
        var opened: [String] = []
        let bridge = makeBridge(
            runner: stub.runner,
            names: .init(on: "设定专注模式", off: "关闭专注模式"),
            openHandler: { opened.append($0.lastPathComponent); return true }
        )

        let installTask = Task { await bridge.installShortcuts() }
        taskBox.task = installTask
        let outcome = await installTask.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(opened.isEmpty, "取消后不得再有外部副作用（零 open）")
        // 剩余未交出的文件要清场。
        if let firstSource = stub.invocations.first(where: { $0.command == "sign" })?.argv[2] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: firstSource),
                "未打开的临时文件不留残骸"
            )
        }
    }

    // MARK: - 退出覆盖在飞开启（codex 三轮 ③）

    @MainActor
    func testTerminateCoversInFlightEnable() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SyncLaunchRecorder()
        let bridge = makeBridge(runner: RunnerStub(holdRuns: true).runner, syncLaunchRecorder: recorder)
        let manager = makeManager(defaults: defaults, bridge: bridge)
        await drain()

        manager.startFocus()
        await drain()
        manager.handleAppWillTerminate()

        XCTAssertEqual(
            recorder.argvList,
            [["/usr/bin/shortcuts", "run", "Restly 专注关闭"]],
            "enable 还在飞时退出也要发同步关闭（关闭幂等，宁可多发不可漏发）"
        )
    }

    // MARK: - 关键词子串匹配与选名结算（codex 五轮 ②③）

    /// 「Deep Focus」这类含关键词但不全等的自建模式必须命中：
    /// 全等匹配会把它跳过、错落到不相干的自定义模式上。
    func testFocusTargetParsingMatchesKeywordSubstrings() throws {
        let fixture = """
        {"data": [{"modeConfigurations": {
            "com.apple.donotdisturb.mode.default": {"mode": {"name": "Do Not Disturb", "modeIdentifier": "com.apple.donotdisturb.mode.default"}},
            "com.apple.sleep.sleep-mode": {"mode": {"name": "Sleep", "modeIdentifier": "com.apple.sleep.sleep-mode"}},
            "com.apple.donotdisturb.mode.custom": {"mode": {"name": "Deep Focus", "modeIdentifier": "com.apple.donotdisturb.mode.custom"}}
        }}]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try XCTUnwrap(FocusModeBridge.readFocusTarget(at: url))
        XCTAssertEqual(target.identifier, "com.apple.donotdisturb.mode.custom")
        XCTAssertEqual(target.displayName, "Deep Focus")
    }

    /// 下拉选名后的结算契约：名字变化使旧缓存作废，强制重检给出
    /// .ready 时熔断复位并触发一次 onMissingCleared（manager 靠它
    /// 补执行当前段）。
    @MainActor
    func testSelectingExistingShortcutsByNameSettlesCircuitBreaker() async {
        let stub = RunnerStub(responses: [
            (1, "找不到快捷指令"),          // run 失败
            (0, ""),                       // list：A/B 缺失 → 熔断
            (0, "C\nD\n"),                // 选名后强制重检：ready
        ])
        var names = FocusModeBridge.ShortcutNames(on: "A", off: "B")
        var clearedCount = 0
        let bridge = FocusModeBridge(
            runner: stub.runner,
            namesProvider: { names },
            focusTargetProvider: { nil }
        )
        bridge.onMissingCleared = { clearedCount += 1 }

        // 熔断要经执行侧 run 失败 + list 确认才置位（与生产一致）。
        _ = await bridge.setFocusEngaged(true)
        XCTAssertTrue(bridge.isMissing)

        // 「下拉选中」= 指认换成真实存在的名字 + 强制重检。
        names = .init(on: "C", off: "D")
        let existence = await bridge.checkShortcutsExist(forceRefresh: true)

        XCTAssertEqual(existence, .ready)
        XCTAssertFalse(bridge.isMissing)
        XCTAssertEqual(clearedCount, 1, "熔断复位恰好触发一次重跑钩子")
    }

    // MARK: - 呈现延迟与开关竞态（codex 四轮 ①②）

    /// 对话框退场动画期间 present 会被静默丢弃：统一推迟呈现的
    /// 工具函数契约 —— 延迟到点前不执行、到点后执行。
    /// 取消（如 400ms 内生成失败、重启流程）后闭包不得执行 ——
    /// 否则失败终态会被改回 .waiting、旧 sheet 会被拉回来。
    @MainActor
    func testDeferredPresentationHonoursCancellation() async {
        final class FlagBox: @unchecked Sendable {
            var flag = false
        }
        let box = FlagBox()
        let task = SettingsView.presentAfterDialogDismissal(delay: .milliseconds(200)) {
            box.flag = true
        }
        task.cancel()
        await task.value
        XCTAssertFalse(box.flag, "取消后闭包不得执行")
    }

    @MainActor
    func testDeferredPresentationRunsClosureAfterDelay() async {
        final class FlagBox: @unchecked Sendable {
            var flag = false
        }
        let box = FlagBox()
        let task = SettingsView.presentAfterDialogDismissal(delay: .milliseconds(50)) {
            box.flag = true
        }
        XCTAssertFalse(box.flag, "延迟到点前不得提前执行")
        await task.value
        XCTAssertTrue(box.flag, "延迟到点后必须执行")
    }

    /// await 检查返回后以「关后的设置」为准：已关闭一律不弹引导；
    /// 例行刷新（onAppear/教程关闭，autoGuide=false）不弹，只有用户
    /// 主动动作（autoGuide=true）缺失时才弹 —— 否则刚关掉教程又被弹。
    func testShouldShowCreationGuideHonoursPostAwaitToggleAndAutoGuide() {
        XCTAssertTrue(SettingsView.shouldShowCreationGuide(
            isLinkageEnabled: true,
            existence: .missing,
            autoGuide: true
        ))
        XCTAssertFalse(SettingsView.shouldShowCreationGuide(
            isLinkageEnabled: true,
            existence: .missing,
            autoGuide: false
        ), "例行刷新不得自动弹引导")
        XCTAssertFalse(SettingsView.shouldShowCreationGuide(
            isLinkageEnabled: false,
            existence: .missing,
            autoGuide: true
        ), "await 期间被关掉的功能不得再弹引导")
        XCTAssertFalse(SettingsView.shouldShowCreationGuide(
            isLinkageEnabled: true,
            existence: .ready,
            autoGuide: true
        ))
    }

    // MARK: - 退出保序（codex 四轮 ③）

    /// 慢 enable（挂 2.5 秒）在飞时退出：leave 挂在子进程退出点
    /// （后台队列），等待不被主线程派发卡死 —— 同步关闭必须在 run
    /// 结算之后才拉起（顺序断言，Grove 对第十一轮「必然耗满预算」
    /// 判无效后的重点回归）。
    @MainActor
    func testTerminateWaitsForInFlightEnableBeforeLaunchingOff() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub(holdRuns: true)
        let recorder = SyncLaunchRecorder()
        let bridge = makeBridge(runner: stub.runner, syncLaunchRecorder: recorder)
        let manager = makeManager(defaults: defaults, bridge: bridge)
        await drain()

        manager.startFocus()
        await drain()
        // enable 已挂起在飞；后台 2.5 秒后才结算（慢指令）。
        final class Timestamps: @unchecked Sendable {
            var settledAt: Date?
            var offLaunchedAt: Date?
        }
        let timestamps = Timestamps()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
            timestamps.settledAt = Date()
            stub.releaseHeldRuns()
        }

        manager.handleAppWillTerminate()
        await drain()

        XCTAssertEqual(
            recorder.argvList.first,
            ["/usr/bin/shortcuts", "run", "Restly 专注关闭"]
        )
        let launchedAt = try? XCTUnwrap(recorder.lastLaunchDate)
        let settled = try? XCTUnwrap(timestamps.settledAt)
        if let launchedAt, let settled {
            XCTAssertGreaterThanOrEqual(
                launchedAt, settled,
                "同步关闭必须晚于在飞 enable 的结算（顺序断言）"
            )
        }
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

    // MARK: - 签名环节（macOS 27 拒收未签名文件）

    @MainActor
    func testInstallSignsEachShortcutWithCorrectArgumentsBeforeOpening() async {
        var opened: [String] = []
        let stub = RunnerStub()
        let bridge = makeBridge(
            runner: stub.runner,
            names: .init(on: "设定专注模式", off: "关闭专注模式"),
            openHandler: { opened.append($0.lastPathComponent); return true }
        )

        let outcome = await bridge.installShortcuts()

        XCTAssertEqual(outcome, .opened)
        let signs = stub.invocations.filter { $0.command == "sign" }
        XCTAssertEqual(signs.count, 2, "两个文件各签一次")
        // argv 形如 ["sign", "-i", <源>, "-o", <签名输出>]，顺序固定。
        for (sign, fileName) in zip(signs, ["设定专注模式.shortcut", "关闭专注模式.shortcut"]) {
            XCTAssertEqual(sign.argv.first, "sign")
            XCTAssertEqual(sign.argv.count, 5)
            XCTAssertEqual(sign.argv[1], "-i")
            XCTAssertEqual((sign.argv[2] as NSString).lastPathComponent, fileName)
            XCTAssertEqual(sign.argv[3], "-o")
            XCTAssertEqual((sign.argv[4] as NSString).lastPathComponent, "signed-\(fileName)")
        }
        // 打开的必须是签名后写回原路径的文件。
        XCTAssertEqual(opened, ["设定专注模式.shortcut", "关闭专注模式.shortcut"])
    }

    @MainActor
    func testInstallMapsSignFailureToGenerationFailedAndNeverOpens() async {
        let stub = RunnerStub(responses: [
            (2, "无法验证或签名"),   // 第一条首签失败
            (2, "无法验证或签名"),   // 拉起 App 后重试仍失败
        ])
        var opened: [String] = []
        let wake = AppWakeCounter()
        let bridge = makeBridge(
            runner: stub.runner,
            names: .init(on: "设定专注模式", off: "关闭专注模式"),
            openHandler: { opened.append($0.lastPathComponent); return true },
            appWakeCount: wake
        )

        let outcome = await bridge.installShortcuts()

        guard case .generationFailed(let reason) = outcome else {
            return XCTFail("签名失败应归入 generationFailed，实际 \(outcome)")
        }
        XCTAssertTrue(reason.contains("2"), "reason 要带退出码：\(reason)")
        XCTAssertTrue(reason.contains("无法验证或签名"), "reason 要带输出：\(reason)")
        XCTAssertTrue(opened.isEmpty, "签名失败绝不能再交给系统打开")
        let signs = stub.invocations.filter { $0.command == "sign" }
        XCTAssertEqual(signs.count, 2, "首条签两次（重试一次）即止，不碰第二条")
        XCTAssertEqual(wake.count, 2, "初始拉起 + 重试前补拉，共两次")
        // 失败后临时目录要清干净：sign 的源文件应已不存在。
        if let path = signs.first?.argv[2] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "半成品不该留在临时目录")
        }
    }

    @MainActor
    func testInstallWakesShortcutsAppBeforeSigning() async {
        let stub = RunnerStub()
        let wake = AppWakeCounter()
        let bridge = makeBridge(runner: stub.runner, appWakeCount: wake)

        let outcome = await bridge.installShortcuts()

        XCTAssertEqual(outcome, .opened)
        let firstSignIndex = stub.invocations.firstIndex { $0.command == "sign" }
        XCTAssertNotNil(firstSignIndex)
        XCTAssertGreaterThanOrEqual(wake.count, 1, "签名前要先拉起快捷指令 App")
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

    /// 模板逐字节对齐系统 UI 写出的格式（Shortcuts.sqlite 实证）：
    /// 开 = Enabled:1 + FocusModes；关 = 仅 FocusModes；无 Operation/UUID。
    @MainActor
    func testGeneratedWorkflowCarriesVerifiedActionFormat() throws {
        let target = FocusModeBridge.FocusTarget(identifier: "com.apple.donotdisturb.mode.graduationcapfill", displayName: "learn")
        let workflow = FocusModeBridge.makeWorkflow(enable: true, target: target)

        let actions = try XCTUnwrap(workflow["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(actions[0]["WFWorkflowActionIdentifier"] as? String),
            "is.workflow.actions.dnd.set",
            "「设置专注模式」的动作标识符，已在本机 WorkflowKit 注册表上查证"
        )
        let parameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(
            Set(parameters.keys),
            ["Enabled", "FocusModes"],
            "开启动作的参数键集合必须与系统模板精确一致"
        )
        XCTAssertEqual(try XCTUnwrap(parameters["Enabled"] as? Int), 1, "Enabled 是数字 1，与系统存储一致")
        let focus = try XCTUnwrap(parameters["FocusModes"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(focus["Identifier"] as? String), "com.apple.donotdisturb.mode.graduationcapfill")
        XCTAssertEqual(try XCTUnwrap(focus["DisplayString"] as? String), "learn")

        // 关闭动作：只有 FocusModes，无任何开关位。
        let off = FocusModeBridge.makeWorkflow(enable: false, target: target)
        let offParameters = try XCTUnwrap(
            ((off["WFWorkflowActions"] as? [[String: Any]])?[0]["WFWorkflowActionParameters"] as? [String: Any])
        )
        XCTAssertEqual(Set(offParameters.keys), ["FocusModes"])
        let offFocus = try XCTUnwrap(offParameters["FocusModes"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(offFocus["DisplayString"] as? String), "learn")
    }

    @MainActor
    func testGenerateShortcutFilesWritesParseablePlists() throws {
        let bridge = makeBridge(runner: RunnerStub().runner)
        let files = try bridge.generateShortcutFiles()
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].lastPathComponent, "Restly 专注开启.shortcut")
        XCTAssertEqual(files[1].lastPathComponent, "Restly 专注关闭.shortcut")

        // 开启落盘带 Enabled:1，关闭落盘只有 FocusModes。
        for (file, expectedKeys) in zip(files, [
            Set(["Enabled", "FocusModes"]),
            Set(["FocusModes"]),
        ]) {
            let data = try Data(contentsOf: file)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            let actions = try XCTUnwrap(plist as? [String: Any])["WFWorkflowActions"] as? [[String: Any]]
            let parameters = try XCTUnwrap(actions?[0]["WFWorkflowActionParameters"] as? [String: Any])
            XCTAssertEqual(Set(parameters.keys), expectedKeys)
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

    /// 名字表没命中时优先挑非核心模式：graduationcapfill 这类基于系统
    /// 预设的自定义模式（identifier 看着像内置）名字是用户起的、稳定
    /// 可用 —— 第四轮误把它当系统模式跳过、错落到勿扰兜底，就是教训。
    func testFocusTargetParsingPrefersFocusLikeNamesThenCustomModes() throws {
        let fixture = """
        {"data": [{"modeConfigurations": {
            "com.apple.donotdisturb.mode.default": {"mode": {"name": "Do Not Disturb", "modeIdentifier": "com.apple.donotdisturb.mode.default"}},
            "com.apple.donotdisturb.mode.graduationcapfill": {"mode": {"name": "learn", "modeIdentifier": "com.apple.donotdisturb.mode.graduationcapfill"}}
        }}]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try XCTUnwrap(FocusModeBridge.readFocusTarget(at: url))
        XCTAssertEqual(target.identifier, "com.apple.donotdisturb.mode.graduationcapfill", "非核心模式优先于核心兜底")
        XCTAssertEqual(target.displayName, "learn")
    }

    /// 核心模式（勿扰/睡眠）之间不能互相当兜底：只剩它们时才落勿扰。
    func testCoreModesDoNotShadowEachOtherInSelection() throws {
        let fixture = """
        {"data": [{"modeConfigurations": {
            "com.apple.donotdisturb.mode.default": {"mode": {"name": "Do Not Disturb", "modeIdentifier": "com.apple.donotdisturb.mode.default"}},
            "com.apple.sleep.sleep-mode": {"mode": {"name": "Sleep", "modeIdentifier": "com.apple.sleep.sleep-mode"}}
        }}]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try XCTUnwrap(FocusModeBridge.readFocusTarget(
            at: url,
            preferredLanguages: ["zh-Hans-CN"]
        ))
        XCTAssertEqual(target.identifier, "com.apple.donotdisturb.mode.default")
        XCTAssertEqual(target.displayName, "勿扰模式")
    }

    /// 只剩系统勿扰可兜底时，DisplayString 用本地化显示名 ——
    /// 运行时按显示名匹配，写规范英文名在中文系统上会找不到。
    func testFocusTargetFallsBackToLocalizedDoNotDisturb() throws {
        let fixture = """
        {"data": [{"modeConfigurations": {
            "com.apple.donotdisturb.mode.default": {"mode": {"name": "Do Not Disturb", "modeIdentifier": "com.apple.donotdisturb.mode.default"}}
        }}]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let chinese = try XCTUnwrap(
            FocusModeBridge.readFocusTarget(at: url, preferredLanguages: ["zh-Hans-CN"])
        )
        XCTAssertEqual(chinese.identifier, "com.apple.donotdisturb.mode.default")
        XCTAssertEqual(chinese.displayName, "勿扰模式")

        let english = try XCTUnwrap(
            FocusModeBridge.readFocusTarget(at: url, preferredLanguages: ["en-US"])
        )
        XCTAssertEqual(english.displayName, "Do Not Disturb")

        // 宁可不生成，不生成解析必失败的指令（Grove/codex 维持立场）。
        XCTAssertNil(
            FocusModeBridge.readFocusTarget(at: url, preferredLanguages: ["xx-YY"]),
            "映射不到就别给 DisplayString，让安装走教程路线"
        )
    }

    /// 未覆盖语言的勿扰兜底整条链：readFocusTarget nil → 安装报
    /// generationFailed 且原因带指引 → 零打开。
    @MainActor
    func testUnmappedLanguageSkipsGenerationInsteadOfEmittingBrokenShortcut() async throws {
        let fixture = """
        {"data": [{"modeConfigurations": {
            "com.apple.donotdisturb.mode.default": {"mode": {"name": "Do Not Disturb", "modeIdentifier": "com.apple.donotdisturb.mode.default"}}
        }}]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-unmapped-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // nl 等未覆盖语言下 provider 返回 nil。
        XCTAssertNil(FocusModeBridge.readFocusTarget(at: url, preferredLanguages: ["nl-NL"]))

        let stub = RunnerStub()
        var opened: [String] = []
        let bridge = makeBridge(
            runner: stub.runner,
            target: nil,   // 与 readFocusTarget 返回 nil 的链路等价
            openHandler: { opened.append($0.lastPathComponent); return true }
        )

        let outcome = await bridge.installShortcuts()

        guard case .generationFailed(let reason) = outcome else {
            return XCTFail("未覆盖语言应走 generationFailed，实际 \(outcome)")
        }
        XCTAssertTrue(reason.contains("本地化名称"), "原因要写明症结：\(reason)")
        XCTAssertTrue(reason.contains("手动创建"), "原因要给出路：\(reason)")
        XCTAssertTrue(opened.isEmpty, "生成失败不得打开任何文件")
    }

    // MARK: - 代数账本（codex 八轮 ②③）

    /// ③ 过期失败回滚晚到，不得覆盖新成功状态：
    /// 开始（gen1 挂起）→ 暂停（gen2 off 完成）→ 恢复（gen3 开启完成）
    /// → 此时才释放 gen1 的失败结果：回滚必须被代数门拦下，
    /// applied 保持 true（系统实际开着，账本不能记成关）。
    @MainActor
    func testStaleFailureRollbackDoesNotClobberNewerSuccess() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // gen1 的失败结果（含定性 list）延迟到 gen3 之后才释放。
        let stub = RunnerStub(holdFirstRun: true)
        let bridge = makeBridge(runner: stub.runner)
        let manager = makeManager(defaults: defaults, bridge: bridge)
        await drain()

        manager.startFocus()
        await drain()
        XCTAssertEqual(manager.linkGeneration, 1)
        XCTAssertTrue(manager.isFocusLinkApplied, "开启乐观记账")

        manager.pause()
        await drain()
        XCTAssertEqual(manager.linkGeneration, 2)
        // holdFirstRun 只挂最老的开启：off 正常完成，applied 落到 false。
        XCTAssertFalse(manager.isFocusLinkApplied)
        XCTAssertEqual(manager.pendingOffCount, 0)

        manager.resume()
        await drain()
        XCTAssertEqual(manager.linkGeneration, 3)
        XCTAssertTrue(manager.isFocusLinkApplied)
        XCTAssertEqual(manager.pendingOffCount, 0)

        // 现在才让 gen1 的失败结果晚到。
        stub.releaseHeldRuns(status: 1, output: "找不到快捷指令")
        await drain()

        XCTAssertEqual(manager.linkGeneration, 3, "过期回调不得推进代数")
        XCTAssertTrue(
            manager.isFocusLinkApplied,
            "过期失败回滚无权写账本：系统实际开着，账本不能被写回关"
        )
        XCTAssertEqual(manager.pendingOffCount, 0)
        XCTAssertFalse(
            manager.hasShownFocusLinkageWarning,
            "过期回调连缺失提醒都不该弹（那是新一代指令路径的事）"
        )
    }

    /// ② off 排队未拉起时 terminate：同步关闭必须仍然发生，
    /// 且记账清零（排队的 off 随进程消亡也不留悬账）。
    @MainActor
    func testTerminateDuringPendingOffStillFiresSyncClose() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub(holdRuns: true)   // 开启与关闭都挂住
        let recorder = SyncLaunchRecorder()
        let bridge = makeBridge(runner: stub.runner, syncLaunchRecorder: recorder)
        let manager = makeManager(defaults: defaults, bridge: bridge)
        await drain()

        manager.startFocus()
        await drain()
        XCTAssertTrue(manager.isFocusLinkApplied, "开启乐观记账（子进程还没退出）")

        manager.pause()
        XCTAssertEqual(manager.pendingOffCount, 1, "off 已提交未拉起")
        XCTAssertTrue(manager.isFocusLinkApplied, "off 未拉起前 applied 保持 true")

        manager.handleAppWillTerminate()

        XCTAssertEqual(
            recorder.argvList.first,
            ["/usr/bin/shortcuts", "run", "Restly 专注关闭"],
            "pendingOff 未拉起时退出必须补发同步关闭"
        )
        XCTAssertEqual(manager.pendingOffCount, 0)
        XCTAssertFalse(manager.isFocusLinkApplied)
    }

    /// 代数只拦过期回调：最新一代的失败回滚必须照常生效，
    /// 防止矫枉过正把正常回滚也废了。
    @MainActor
    func testLatestGenerationFailureRollbackStillApplies() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub(responses: [
            (1, "找不到快捷指令"),   // 恢复（最新一代）开启失败
            (0, ""),                // 定性 list：missing
        ])
        let bridge = makeBridge(runner: stub.runner)
        let manager = makeManager(defaults: defaults, bridge: bridge)
        await drain()

        manager.startFocus()
        await drain()
        XCTAssertFalse(manager.isFocusLinkApplied, "gen1 开启已失败并回滚")

        manager.pause()
        await drain()
        XCTAssertFalse(manager.isFocusLinkApplied, "本来就没开，暂停不改变账本")
        XCTAssertEqual(manager.pendingOffCount, 0, "applied 已是关，暂停不再重复发 off")

        manager.resume()
        await drain()

        XCTAssertFalse(
            manager.isFocusLinkApplied,
            "最新一代的失败回滚要照常生效（系统实际没开，账本不能记开）"
        )
        XCTAssertTrue(bridge.isMissing)
        XCTAssertTrue(manager.hasShownFocusLinkageWarning)
    }

    // MARK: - codex 九轮（转场收敛 / missing 豁免 / 组平衡与顺序）

    /// ① 换名 + 新开启持续失败：转场至多一次，不再出现第二次旧关
    /// —— 旧关的记账豁免切断了「旧关成功写回旧对 → 又见缺口 →
    /// 再转场」的无限循环。
    @MainActor
    func testAppliedNamesTransitionConvergesWhenNewOnKeepsFailing() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub(responses: [
            (0, ""),                     // 旧对开启成功
            (0, "新开\n新关\n"),          // 改名后的检测 ready
            (0, ""),                     // 转场旧关成功
            (1, "找不到快捷指令"),         // 新对开启失败
            (0, "新开\n新关\n"),          // 失败定性 list：ready
        ])
        var names = FocusModeBridge.ShortcutNames(on: "旧开", off: "旧关")
        let bridge = FocusModeBridge(
            runner: stub.runner,
            namesProvider: { names },
            focusTargetProvider: { nil }
        )
        let manager = makeManager(defaults: defaults, bridge: bridge)
        bridge.onAppliedNamesChanged = { oldNames in
            manager.handleAppliedNamesTransition(from: oldNames)
        }
        await drain()

        manager.startFocus()
        await drain()
        XCTAssertEqual(bridge.appliedNames, .init(on: "旧开", off: "旧关"))

        // 用户换指认成已就绪的新对，随后结算路径重检。
        names = .init(on: "新开", off: "新关")
        _ = await bridge.checkShortcutsExist(forceRefresh: true)
        await drain()

        let runNames = runCalls(in: stub).map(\.name)
        XCTAssertEqual(
            runNames,
            ["旧开", "旧关", "新开"],
            "转场收敛：旧关至多一次，新开失败后不再重复转场"
        )
        XCTAssertEqual(bridge.appliedNames, .init(on: "新开", off: "新关"))
        // 新开的失败是 .failed（list 显示两条都在）而非缺失：不熔断、
        // 不弹缺失提醒，收敛靠停止重试逻辑本身。
        XCTAssertFalse(bridge.isMissing)
        XCTAssertFalse(manager.hasShownFocusLinkageWarning)
    }

    /// ② 关闭指令缺失的 disengage：applied 保持 true（系统大概率
    /// 仍开着），重建后 onMissingCleared 驱动补关。
    @MainActor
    func testDisengageMissingKeepsAppliedTrueUntilRebuilt() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub(responses: [
            (0, ""),                       // 开启成功
            (1, "找不到快捷指令"),           // 关闭指令被删，off 失败
            (0, ""),                       // 定性 list：missing
            (0, "Restly 专注开启\nRestly 专注关闭\n"),  // 重建后检测 ready
            (0, ""),                       // 重建后的补关
        ])
        let bridge = makeBridge(runner: stub.runner)
        let manager = makeManager(defaults: defaults, bridge: bridge)
        bridge.onMissingCleared = { manager.syncFocusLinkage() }
        await drain()

        manager.startFocus()
        await drain()
        XCTAssertTrue(manager.isFocusLinkApplied)
        XCTAssertFalse(bridge.isMissing)

        manager.pause()
        await drain()
        XCTAssertTrue(bridge.isMissing)
        XCTAssertTrue(
            manager.isFocusLinkApplied,
            "关闭失败（missing）时账本要诚实：系统大概率仍开着"
        )

        // 用户重建指令：检测就绪 → 熔断复位 → 补关。
        // 用户重建指令：检测就绪 → 熔断复位 → 补关。
        let rebuildExistence = await bridge.checkShortcutsExist(forceRefresh: true)
        XCTAssertEqual(rebuildExistence, .ready)
        await drain()

        XCTAssertEqual(
            runCalls(in: stub).map(\.name),
            ["Restly 专注开启", "Restly 专注关闭", "Restly 专注关闭"],
            "重建后要补执行一次关闭"
        )
        XCTAssertFalse(manager.isFocusLinkApplied, "补关落定后账本归位")
    }

    // MARK: - 改名结算门控与占用挂起（codex 十轮 ①②）

    /// ① 逐字段改名的中间态检查得 .missing：转场一个字都不动 ——
    /// 零旧关、appliedNames 不变、无回调。对不完整的新对发关闭会
    /// 掐断进行中的专注。
    @MainActor
    func testMidTypingMissingCheckDoesNotTriggerTransition() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub(responses: [
            (0, ""),                       // 旧对开启成功
            (0, ""),                       // 打字中间态检查：list 空 → missing
            (0, "新开\n新关\n"),            // 补全后的检查：ready
        ])
        var names = FocusModeBridge.ShortcutNames(on: "旧开", off: "旧关")
        var transitionCount = 0
        let bridge = FocusModeBridge(
            runner: stub.runner,
            namesProvider: { names },
            focusTargetProvider: { nil }
        )
        let manager = makeManager(defaults: defaults, bridge: bridge)
        bridge.onAppliedNamesChanged = { oldNames in
            transitionCount += 1
            manager.handleAppliedNamesTransition(from: oldNames)
        }
        await drain()

        manager.startFocus()
        await drain()
        XCTAssertEqual(bridge.appliedNames, .init(on: "旧开", off: "旧关"))

        // 用户逐字段改名字：中间态（两条都不存在）→ missing。
        names = .init(on: "打字中A", off: "打字中B")
        let midExistence = await bridge.checkShortcutsExist(forceRefresh: true)
        XCTAssertEqual(midExistence, .missing)
        await drain()

        XCTAssertEqual(transitionCount, 0, "missing 不得触发转场")
        XCTAssertEqual(bridge.appliedNames, .init(on: "旧开", off: "旧关"), "appliedNames 不变")
        XCTAssertEqual(runCalls(in: stub).map(\.name), ["旧开"], "零旧关：不许对中间态发关闭")

        // 防矫枉过正：补全成已就绪的新对后，转场照常发生。
        names = .init(on: "新开", off: "新关")
        let readyExistence = await bridge.checkShortcutsExist(forceRefresh: true)
        XCTAssertEqual(readyExistence, .ready)
        await drain()
        XCTAssertEqual(transitionCount, 1, ".ready 时转场照常发生")
        for _ in 0..<5 { await drain() }   // 旧关/新开各是异步 Task，多让几轮
        XCTAssertEqual(
            runCalls(in: stub).map(\.name),
            ["旧开", "旧关", "新开"]
        )
        XCTAssertEqual(bridge.appliedNames, .init(on: "新开", off: "新关"))
    }

    // MARK: - 名字转场（codex 六轮 ③）

    /// 应用中（旧对已开启）→ 改指认成已就绪的新对：先跑旧关闭、
    /// 再跑新开启 —— 不转场的话，暂停/退出会拿新对执行关闭，
    /// 旧对的目标模式被留在开启状态。
    @MainActor
    func testAppliedNamesTransitionRunsOldOffThenNewOn() async {
        let (defaults, suiteName) = makeDefaults(enablingLinkage: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stub = RunnerStub(responses: [
            (0, ""),                     // 旧对开启
            (0, "新开\n新关\n"),          // 改名后的检测 ready
            (0, ""),                     // 旧对关闭（转场）
            (0, ""),                     // 新对开启（重结算）
        ])
        var names = FocusModeBridge.ShortcutNames(on: "旧开", off: "旧关")
        let bridge = FocusModeBridge(
            runner: stub.runner,
            namesProvider: { names },
            focusTargetProvider: { nil }
        )
        let manager = makeManager(defaults: defaults, bridge: bridge)
        bridge.onAppliedNamesChanged = { oldNames in
            manager.handleAppliedNamesTransition(from: oldNames)
        }
        await drain()

        manager.startFocus()
        await drain()
        XCTAssertEqual(bridge.appliedNames, .init(on: "旧开", off: "旧关"))

        // 用户把指认改成已就绪的新对，随后任意一条结算路径重检。
        names = .init(on: "新开", off: "新关")
        _ = await bridge.checkShortcutsExist(forceRefresh: true)
        await drain()

        XCTAssertEqual(
            runCalls(in: stub).map(\.name),
            ["旧开", "旧关", "新开"],
            "转场顺序：旧关闭在前，新开启在后"
        )
        XCTAssertEqual(bridge.appliedNames, .init(on: "新开", off: "新关"))
    }

    // MARK: - sheet 转场契约（codex 六轮 ②）

    /// sheet→sheet 转场契约：两次延迟呈现按序执行（失败 sheet 的
    /// 「看手动教程」就靠这个不被 macOS 丢弃）。
    @MainActor
    func testDeferredPresentationSupportsSequentialTransitions() async {
        var sequence: [String] = []
        let first = SettingsView.presentAfterDialogDismissal(delay: .milliseconds(10)) {
            sequence.append("failure-out")
        }
        await first.value
        let second = SettingsView.presentAfterDialogDismissal(delay: .milliseconds(10)) {
            sequence.append("tutorial-in")
        }
        await second.value
        XCTAssertEqual(sequence, ["failure-out", "tutorial-in"])
    }

    // MARK: - 占用挂起与记账时机（codex 十轮 ②）

    /// 占用决策契约：已有检查在飞时新请求不丢弃（挂起补跑）。
    func testLinkageRefreshQueuesWhenBusy() {
        XCTAssertTrue(SettingsView.linkageRefreshQueuesWhenBusy(isChecking: true))
        XCTAssertFalse(SettingsView.linkageRefreshQueuesWhenBusy(isChecking: false))
    }

    /// 记账时机契约：检查被接受（立即发起或挂起补跑）才记 lastSettled；
    /// 被拒不记 —— 否则改名刷新被吞后，去重会让新名字永远不再结算。
    func testSettleBookkeepingRequiresAcceptedCheck() {
        let bookkeeping = SettingsView.settleBookkeeping(willCheck: true, settled: (on: "A", off: "B"))
        XCTAssertEqual(bookkeeping?.on, "A")
        XCTAssertEqual(bookkeeping?.off, "B")
        XCTAssertNil(SettingsView.settleBookkeeping(willCheck: false, settled: (on: "A", off: "B")))
    }

    /// 名字结算去重：值未变（submit 后紧跟的 blur、重复 blur）零副作用；
    /// 值变了或从未结算才需要结算。
    func testShortcutNameSettleNeededDeduplicates() {
        XCTAssertFalse(SettingsView.shortcutNameSettleNeeded(
            current: (on: "设定专注模式", off: "关闭专注模式"),
            lastSettled: (on: "设定专注模式", off: "关闭专注模式")
        ), "值未变（submit+blur 连击）不得重复结算")
        XCTAssertTrue(SettingsView.shortcutNameSettleNeeded(
            current: (on: "设定专注模式", off: "关闭专注模式"),
            lastSettled: nil
        ), "从未结算过要结算")
        XCTAssertTrue(SettingsView.shortcutNameSettleNeeded(
            current: (on: "C", off: "D"),
            lastSettled: (on: "A", off: "B")
        ), "值变了要结算")
    }

    /// ① 本地化映射未覆盖（nl 等）不得误伤自定义模式：名字是用户
    /// 起的、不需要本地化映射，Work Hours 应正常选中。
    func testUnmappedLanguageStillSelectsCustomModes() throws {
        let fixture = """
        {"data": [{"modeConfigurations": {
            "com.apple.donotdisturb.mode.default": {"mode": {"name": "Do Not Disturb", "modeIdentifier": "com.apple.donotdisturb.mode.default"}},
            "com.apple.sleep.sleep-mode": {"mode": {"name": "Sleep", "modeIdentifier": "com.apple.sleep.sleep-mode"}},
            "com.apple.focus.workhours": {"mode": {"name": "Work Hours", "modeIdentifier": "com.apple.focus.workhours"}}
        }}]}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-nl-\(UUID().uuidString).json")
        try fixture.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try XCTUnwrap(
            FocusModeBridge.readFocusTarget(at: url, preferredLanguages: ["nl-NL"])
        )
        XCTAssertEqual(target.identifier, "com.apple.focus.workhours")
        XCTAssertEqual(target.displayName, "Work Hours")

        // 只剩核心模式时才放弃（勿扰本地化名无解）。
        let coreOnly = """
        {"data": [{"modeConfigurations": {
            "com.apple.donotdisturb.mode.default": {"mode": {"name": "Do Not Disturb", "modeIdentifier": "com.apple.donotdisturb.mode.default"}}
        }}]}
        """
        let coreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-nl-core-\(UUID().uuidString).json")
        try coreOnly.data(using: .utf8)!.write(to: coreURL)
        defer { try? FileManager.default.removeItem(at: coreURL) }
        XCTAssertNil(
            FocusModeBridge.readFocusTarget(at: coreURL, preferredLanguages: ["nl-NL"]),
            "勿扰本地化名无解就放弃生成，走教程路线"
        )
    }

    /// ③+④ 默认执行器的回调顺序契约：onProcessExit（子进程退出/
    /// 启动失败）必须先于 completion —— 退出的 inFlightRuns.leave 挂在
    /// onProcessExit 上，顺序颠倒会让退出保序等待落空。测试同时钉住
    /// 成功与启动抛错两条路径（stub 无法覆盖生产时序，这里用真进程）。
    func testDefaultRunnerSignalsExitBeforeCompletionInBothPaths() async {
        let workQueue = DispatchQueue(label: "FocusModeLinkageTests.runner")
        let runner = FocusModeBridge.defaultRunner(workQueue: workQueue)
        final class OrderBox: @unchecked Sendable {
            var events: [String] = []
            var status: Int32?
        }
        let successBox = OrderBox()
        let successExpectation = XCTestExpectation(description: "成功路径")
        runner(["/bin/sh", "-c", "echo hi"], { successBox.events.append("exit") }) { _, output in
            successBox.events.append("completion(\(output.trimmingCharacters(in: .whitespacesAndNewlines)))")
            successExpectation.fulfill()
        }
        await fulfillment(of: [successExpectation], timeout: 30)
        XCTAssertEqual(successBox.events, ["exit", "completion(hi)"])

        let failureBox = OrderBox()
        let failureExpectation = XCTestExpectation(description: "启动抛错路径")
        runner(["/nonexistent-restly-probe-\(UUID().uuidString)"], { failureBox.events.append("exit") }) { status, output in
            failureBox.events.append("completion")
            failureBox.status = status
            failureExpectation.fulfill()
        }
        await fulfillment(of: [failureExpectation], timeout: 30)
        XCTAssertEqual(failureBox.events, ["exit", "completion"], "抛错路径同样先 exit 后 completion")
        XCTAssertEqual(failureBox.status, -1)
    }

    /// 配置文件读不到/解析失败/为空都不得让一键创建死掉：
    /// 静态勿扰兜底（identifier 全系统恒定）+ 黑匣子记下原因。
    /// 实测同一构建终端启动读得到、open 启动被拒（打包身份漂移），
    /// 这条兜底是最后一颗钉子。
    func testReadFocusTargetFallsBackToStaticDNDWhenConfigurationUnavailable() throws {
        let originalLog = DebugEventLog.shared
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyLogTest-\(UUID().uuidString).log")
        DebugEventLog.shared = DebugEventLog(url: logURL)
        defer {
            DebugEventLog.shared = originalLog
            try? FileManager.default.removeItem(at: logURL)
        }

        let expected = FocusModeBridge.FocusTarget(
            identifier: "com.apple.donotdisturb.mode.default",
            displayName: "勿扰模式"
        )
        let expectedEnglish = FocusModeBridge.FocusTarget(
            identifier: "com.apple.donotdisturb.mode.default",
            displayName: "Do Not Disturb"
        )

        // 文件不存在。
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-missing-\(UUID().uuidString).json")
        XCTAssertEqual(
            FocusModeBridge.readFocusTarget(at: missingURL, preferredLanguages: ["zh-Hans-CN"]),
            expected
        )

        // 解析失败。
        let garbageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-garbage-\(UUID().uuidString).json")
        try "not json".data(using: .utf8)!.write(to: garbageURL)
        defer { try? FileManager.default.removeItem(at: garbageURL) }
        XCTAssertEqual(
            FocusModeBridge.readFocusTarget(at: garbageURL, preferredLanguages: ["en-US"]),
            expectedEnglish
        )

        // 模式列表为空。
        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestlyFocusTest-empty-\(UUID().uuidString).json")
        try "{\"data\": [{}]}".data(using: .utf8)!.write(to: emptyURL)
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        XCTAssertEqual(
            FocusModeBridge.readFocusTarget(at: emptyURL, preferredLanguages: ["zh-Hans-CN"]),
            expected
        )

        // 黑匣子要能分清三种原因，别让「为什么 nil」再成悬案。
        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains("配置文件不存在"), content)
        XCTAssertTrue(content.contains("解析失败"), content)
        XCTAssertTrue(content.contains("没有任何模式"), content)
    }

    func testLocalizedDoNotDisturbCoversMajorLanguages() {
        XCTAssertEqual(FocusModeBridge.localizedDoNotDisturbName(preferredLanguages: ["zh-Hans-CN"]), "勿扰模式")
        XCTAssertEqual(FocusModeBridge.localizedDoNotDisturbName(preferredLanguages: ["zh-Hant-TW"]), "勿擾模式")
        XCTAssertEqual(FocusModeBridge.localizedDoNotDisturbName(preferredLanguages: ["ja-JP"]), "おやすみモード")
        XCTAssertEqual(FocusModeBridge.localizedDoNotDisturbName(preferredLanguages: ["en-US"]), "Do Not Disturb")
        XCTAssertNil(FocusModeBridge.localizedDoNotDisturbName(preferredLanguages: ["xx-YY", "zz-ZZ"]))
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
        // 解析失败不再返回 nil（那会让一键创建死在最后一步），
        // 而是落静态勿扰兜底，原因进黑匣子 —— 见专项测试。
        let fallback = try XCTUnwrap(FocusModeBridge.readFocusTarget(at: garbage))
        XCTAssertEqual(fallback.identifier, "com.apple.donotdisturb.mode.default")
    }
}
