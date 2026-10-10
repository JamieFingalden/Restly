import AppKit
import Foundation

/// 番茄钟的编排层。`PomodoroSession` 管状态怎么变，这里管定时器、
/// Toast、持久化、锁屏和专注模式联动 —— 模型保持纯净，副作用全部收在这里。
///
/// 与健康提醒刻意互不干扰：全局暂停提醒不影响番茄钟（番茄钟由用户
/// 显式驱动），锁屏冻结也各自独立处理。番茄钟的暂停/跳过/停止只在
/// 本 manager 里生效。
///
/// 专注模式联动是纯边沿触发：所有状态流转最后都汇到
/// `syncFocusLinkage()`，按「设置开 && 专注段计时中」现算应当联动的
/// 值，与上次比较，变了才让 `FocusModeBridge` 跑快捷指令 —— 没有那
/// 条 diff 线，每个流转点都得各自记得开或关，迟早漏一个。
@MainActor
final class PomodoroManager: ObservableObject {
    /// 只在阶段或状态变化时发布；倒计时文本由视图层 TimelineView 每秒现算，
    /// manager 不做每秒 publish（与 ReminderManager 同一约定）。
    @Published private(set) var session: PomodoroSession

    /// 菜单栏 label 专用的倒计时状态。label 里不能用 TimelineView ——
    /// 在 macOS 27 上它会让状态栏按钮每次内容变化都重新栅格化出一张
    /// 新图片、再触发下一轮失效更新，形成无限更新循环（主线程卡死、
    /// 内存狂飙）。文本只在这里由秒级 Timer 驱动，label 纯展示。
    @Published private(set) var menuBarStatus: MenuBarStatus?

    enum MenuBarStatus: Equatable {
        case running(String)
        case paused(String)
    }

    private let settings: ReminderSettings
    private let toastManager: ToastManager
    private let runtimeConfiguration: RuntimeConfiguration
    private let defaults: UserDefaults
    private let focusModeBridge: FocusModeBridge

    /// 「重新创建」按钮要打开设置页，manager 不持有窗口层，
    /// 由组合根塞一个跳转闭包进来。
    var onRequestOpenSettings: (() -> Void)?

    /// 期望联动态：上一轮结算按「设置开 && 专注段计时中」算出的值。
    /// 期望联动态：上一轮结算按「设置开 && 专注段计时中」算出的值。
    private(set) var isFocusLinkDesired = false
    /// 已成功应用的联动态：只有 setFocusEngaged 真正成功才推进。
    /// 失败（缺失熔断等）时保持原值，让 diff 持续看到「想要但没办到」，
    /// 熔断复位钩子（bridge.onMissingCleared → syncFocusLinkage）或
    /// 下一次流转会把这笔账补上 —— 用户在专注中途装好指令的场景
    /// 就靠它把本段专注补进联动，否则要拖到下一段。
    /// 已应用联动态。开启乐观置位（指令发起即记账，失败按代数回滚）；
    /// 关闭不乐观置 false —— 改记 pendingOffCount，见 syncFocusLinkage。
    private(set) var isFocusLinkApplied = false
    /// 已提交但尚未确认子进程退出的关闭指令数。> 0 时退出必须补发
    /// 同步关闭（排队的 off 会随进程消亡，先前的开启却已生效）。
    private(set) var pendingOffCount = 0
    /// 联动操作代数：每次提交先取号；回调恢复时与最新代数比对，
    /// 过期回调只记黑匣子、无权写账本（慢失败回滚踩掉新成功状态、
    /// 旧关闭回滚盖掉新开启，都是没这道闸才可能）。
    private(set) var linkGeneration = 0
    /// 缺失提醒每次启动最多一条：连打几颗番茄都失败时，第 2 条起就是噪音。
    private(set) var hasShownFocusLinkageWarning = false

    /// 只有一个一次性定时器，直接定到当前段的结束时刻。
    private var timer: Timer?

    /// 菜单栏倒计时的秒级 Timer。只在计时中存在，暂停/空闲即停。
    /// （菜单换成了原生 NSMenu，不再需要“菜单开着就挂起”的机制。）
    private var displayTimer: Timer?

    /// 锁屏冻结中。与用户手动暂停的区分只存在于内存里 ——
    /// 进程若死在锁屏期间，恢复出来统一按手动暂停处理，用户自己按恢复。
    private var isFrozenByScreenLock = false
    /// 冻结前是计时中（而非用户已手动暂停）。解锁时只自动恢复这一类。
    private var frozeRunningSession = false

    init(
        settings: ReminderSettings,
        toastManager: ToastManager,
        runtimeConfiguration: RuntimeConfiguration = .current,
        defaults: UserDefaults = .standard,
        focusModeBridge: FocusModeBridge = FocusModeBridge(),
        now: Date = Date()
    ) {
        self.settings = settings
        self.toastManager = toastManager
        self.runtimeConfiguration = runtimeConfiguration
        self.defaults = defaults
        self.focusModeBridge = focusModeBridge

        var restored = PomodoroSession(
            snapshot: Self.readSnapshot(from: defaults, now: now)
        )
        _ = restored.resolveAfterRestoration(at: now)
        session = restored
        // 恢复决策立刻落盘：过期专注的计数、跨天的清零都要写回去。
        persistSession()
        rescheduleTimer(now: now)
        updateMenuBarDisplay()

        // 联动开关在设置里翻转时，这里要立刻跟着执行开启/关闭 ——
        // 中途关掉而联动正开着，必须马上恢复原状，不能等下一次流转。
        settings.onLinksFocusModeChange = { [weak self] in
            self?.syncFocusLinkage()
        }
        // 重启恢复出计时中的专注也算一次流转：重启前联动开着，
        // 新进程从「未联动」起步，这里自然补上开启指令。
        syncFocusLinkage()

        // 退出时把专注模式恢复原状：session 本就跨重启续跑，
        // 下次启动恢复成 running focus 后会重新联动。
        terminateObserverBox.token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAppWillTerminate() }
        }
    }

    /// 观察者令牌装进 Sendable 盒子，deinit 才能从非隔离上下文取到它
    /// 去反注册（盒子只在 init 写一次，之后只读）。
    private final class TerminateObserverBox: @unchecked Sendable {
        var token: NSObjectProtocol?
    }

    private let terminateObserverBox = TerminateObserverBox()

    deinit {
        if let token = terminateObserverBox.token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - 对外查询

    var isIdle: Bool { session.isIdle }

    /// 菜单栏显示开关由 settings 决定，转发一下免得视图再依赖一个对象。
    var showsInMenuBar: Bool { settings.pomodoroShowsInMenuBar }

    /// 今日专注总时长的展示文案，给菜单卡用。
    var focusSummaryText: String {
        PomodoroSession.focusSummaryText(secondsToday: session.focusSecondsToday)
    }

    /// mm:ss 倒计时文本。计时与暂停给文本，就绪与空闲给 nil。
    func countdownText(at now: Date) -> String? {
        session.remaining(at: now).map(PomodoroSession.countdownText(for:))
    }

    // MARK: - 用户操作

    func startFocus() {
        // 空闲，或就绪待专注时可以直接开始；就绪待休息时开始专注等于跳过休息，也说得通。
        guard session.phase == nil || session.status == .awaitingStart else { return }
        let now = Date()
        session.start(.focus, at: now, cycle: cycleConfiguration())
        finishMutation(at: now)
    }

    /// 开始就绪态里等着的下一段（Toast 或菜单卡上的「开始休息/专注」）。
    func startPendingPhase() {
        guard case .awaitingStart = session.status, let phase = session.phase else { return }
        let now = Date()
        session.start(phase, at: now, cycle: cycleConfiguration())
        finishMutation(at: now)
    }

    func pause() {
        guard !isFrozenByScreenLock else { return }
        session.pause(at: Date())
        persistSession()
        timer?.invalidate()
        timer = nil
        updateMenuBarDisplay()
        syncFocusLinkage()
    }

    func resume() {
        guard !isFrozenByScreenLock else { return }
        session.resume(at: Date())
        persistSession()
        rescheduleTimer()
        updateMenuBarDisplay()
        syncFocusLinkage()
    }

    /// 跳过当前段或就绪态里等着的下一段。不弹 Toast —— 用户刚亲手操作过。
    func skip() {
        guard !isFrozenByScreenLock else { return }
        let now = Date()
        _ = session.skip(cycle: cycleConfiguration())
        toastManager.cancelPomodoroToast()
        finishMutation(at: now)
    }

    func stop() {
        session.stop()
        toastManager.cancelPomodoroToast()
        finishMutation(at: Date())
    }

    /// 菜单打开时调用：补上关闭期间已经到点的转段，顺手翻日历。
    func refresh() {
        let now = Date()
        session.rollDayIfNeeded(at: now)
        if session.isDue(at: now) {
            fireIfDue(now: now)
        } else {
            persistSession()
        }
    }

    // MARK: - 锁屏

    func screenDidBecomeUnavailable() {
        guard !isFrozenByScreenLock else { return }
        isFrozenByScreenLock = true
        toastManager.cancelPomodoroToast()

        guard case .running = session.status else { return }
        // 人不在电脑前就不算专注：把剩余时长冻住，解锁再续。
        // 就绪态没有可冻结的计时，手动暂停保持暂停即可。
        frozeRunningSession = true
        session.pause(at: Date())
        persistSession()
        timer?.invalidate()
        timer = nil
        updateMenuBarDisplay()
        syncFocusLinkage()
    }

    func screenDidBecomeAvailable(after lockedDuration: TimeInterval) {
        guard isFrozenByScreenLock else { return }
        isFrozenByScreenLock = false

        // 手动暂停过的维持暂停：解锁不该替用户按恢复。
        guard frozeRunningSession else { return }
        frozeRunningSession = false

        let now = Date()
        session.resume(at: now)
        if session.isDue(at: now) {
            // 锁屏久到冻结前剩余就走完了 —— 按自然到期处理，计数照常。
            fireIfDue(now: now)
        } else {
            finishMutation(at: now)
        }
    }

    // MARK: - 定时器

    private func rescheduleTimer(now: Date = Date()) {
        timer?.invalidate()
        timer = nil
        guard case .running(let endsAt) = session.status, endsAt > now else { return }

        let delay = max(0.5, endsAt.timeIntervalSince(now))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireIfDue() }
        }
        // 到点要转段，容差收紧到秒级 —— 健康提醒那种 30 秒容差
        // 会让人对着 0:00 等半天。
        timer.tolerance = min(1, delay * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// internal 只为测试：自动转段的联动语义要能从外部指定「现在」。
    func fireIfDue(now: Date = Date()) {
        guard let completedPhase = session.phase, session.isDue(at: now) else {
            // tolerance 允许提前触发，没到点就重新定回去。
            rescheduleTimer(now: now)
            return
        }

        // 流转配置按刚结束的段取：专注结束看「自动开始休息」，休息结束看「自动开始专注」。
        let autoStart = completedPhase == .focus
            ? settings.pomodoroAutoStartBreak
            : settings.pomodoroAutoStartFocus

        let outcome = session.completePhase(
            at: now,
            cycle: cycleConfiguration(),
            autoStartNext: autoStart
        )
        finishMutation(at: now)
        presentToast(for: outcome)
    }

    // MARK: - Toast

    /// 状态转移在 fireIfDue 里已经完成，Toast 只是通知 ——
    /// 被队列挂起或用户没看见也不影响正确性，菜单卡是持久的操作面。
    private func presentToast(for outcome: PomodoroSession.Outcome) {
        let cycle = cycleConfiguration()
        switch outcome {
        case .started(let phase) where phase.isBreak:
            toastManager.showPomodoroToast(PomodoroToastRequest(
                title: "专注完成",
                subtitle: "\(phase.title) \(durationText(cycle.duration(for: phase)))已开始",
                systemImage: phase.systemImage,
                primaryTitle: "跳过\(phase.title)",
                primaryAction: { [weak self] in self?.skip() }
            ))
        case .started:
            toastManager.showPomodoroToast(PomodoroToastRequest(
                title: "休息结束",
                subtitle: "新的专注已开始",
                systemImage: PomodoroSession.Phase.focus.systemImage,
                primaryTitle: "停下来",
                primaryAction: { [weak self] in self?.stop() }
            ))
        case .awaiting(let phase) where phase.isBreak:
            toastManager.showPomodoroToast(PomodoroToastRequest(
                title: "专注完成",
                subtitle: "休息一下，\(phase.title) \(durationText(cycle.duration(for: phase)))",
                systemImage: phase.systemImage,
                primaryTitle: "开始\(phase.title)",
                primaryAction: { [weak self] in self?.startPendingPhase() },
                secondaryTitle: "跳过休息",
                secondaryAction: { [weak self] in self?.skip() }
            ))
        case .awaiting:
            toastManager.showPomodoroToast(PomodoroToastRequest(
                title: "休息结束",
                subtitle: "准备好了就开始下一段专注",
                systemImage: PomodoroSession.Phase.focus.systemImage,
                primaryTitle: "开始专注",
                primaryAction: { [weak self] in self?.startPendingPhase() }
            ))
        case .becameIdle:
            break
        }
    }

    // MARK: - 内部

    /// 正式设置下时长都是分钟级；开发模式的秒级时长别显示成「0 分钟」。
    private func durationText(_ duration: TimeInterval) -> String {
        duration >= 60 ? "\(Int(duration / 60)) 分钟" : "\(Int(duration)) 秒"
    }

    private func finishMutation(at now: Date) {
        persistSession()
        rescheduleTimer(now: now)
        updateMenuBarDisplay()
        syncFocusLinkage()
    }

    // MARK: - 专注模式联动

    /// 边沿触发的联动对齐点。任何状态流转之后调用：现算应当联动
    /// （设置开 + 专注段计时中；暂停、就绪、休息、锁屏冻结都不算），
    /// 期望态或应用态有缺口才发指令 —— 应用失败会留下缺口，
    /// 熔断复位钩子会带这里的重跑把账补上。
    /// internal 是给熔断复位钩子与测试的重跑入口。
    func syncFocusLinkage() {
        let shouldEngage: Bool
        if settings.pomodoroLinksFocusMode, session.phase == .focus,
           case .running = session.status {
            shouldEngage = true
        } else {
            shouldEngage = false
        }
        guard shouldEngage != isFocusLinkDesired || shouldEngage != isFocusLinkApplied else { return }
        isFocusLinkDesired = shouldEngage

        // 代数取号：每次提交一条指令就前进一代。回调恢复时比对，
        // 过期回调只记黑匣子、无权写账本。
        linkGeneration += 1
        let generation = linkGeneration
        let bridge = focusModeBridge
        let engaged = shouldEngage
        if engaged {
            // 开启乐观置位：指令已发起（哪怕结果未回）就按已应用记账
            // ——「刚开专注就退出 app」时 willTerminate 若按「结果回
            // 没回」判定会跳过关闭，enable 却在退出后跑完，专注模式
            // 被留开。失败按代数回滚，下一轮结算自然重试。
            isFocusLinkApplied = true
        } else {
            // 关闭不乐观置 false：off 排在慢 enable 后面时，提前置
            // false 会让退出守卫漏发同步关闭（排队 off 随进程消亡、
            // 先前开启已生效 → 专注留开）。改记 pendingOff，直到回调
            // 确认子进程已退出（过期回调也递减：这是进程生命周期
            // 记账，不是状态写入）。
            pendingOffCount += 1
        }
        Task { @MainActor in
            let result = await bridge.setFocusEngaged(engaged)
            // pendingOff 递减不受代数限制：子进程确实退出过一次。
            if !engaged, pendingOffCount > 0 { pendingOffCount -= 1 }
            guard generation == linkGeneration else {
                // 过期回调：这条指令的结果已经被更新的指令覆盖，
                // 回滚/推进都会把账本写回旧态（系统实际开着、账本记
                // 着关 → 退出清理被跳过）。只记黑匣子。
                DebugEventLog.shared.log(
                    "联动账本：过期回调 gen \(generation)（最新 \(linkGeneration)），不写账"
                )
                return
            }
            switch result {
            case .success(()):
                isFocusLinkApplied = engaged
            case .failure(.missing):
                // missing = 指令根本没跑（熔断短路或名单确认缺失），
                // 无论开还是关，诚实的账本都是「未应用」——若此前真
                // 开着，残留由 isMissing 路由到重建流程收敛。
                isFocusLinkApplied = false
                presentFocusLinkageMissingToast()
            case .failure(.failed), .failure(.noFocusTarget):
                // 指令真的跑了但失败：开失败=没开上（回 false），
                // 关失败=可能还开着（保持 true）。下一轮结算重试。
                isFocusLinkApplied = !engaged
            }
            // 关闭落定后若期望已翻回开启（暂停后立刻恢复）：补一次
            // 结算重开 —— applied 此时已是 false，diff 会重新开。
            if !engaged, isFocusLinkDesired {
                syncFocusLinkage()
            }
        }
    }

    /// 快捷指令被用户删掉时的唯一提醒。只提示一次，主按钮带去设置页
    /// 重走创建流程 —— 不崩、不弹系统错误框，联动悄悄停在关闭态。
    private func presentFocusLinkageMissingToast() {
        guard !hasShownFocusLinkageWarning else { return }
        hasShownFocusLinkageWarning = true
        toastManager.showPomodoroToast(PomodoroToastRequest(
            title: "专注模式联动已停",
            subtitle: "未找到快捷指令，专注时不再自动开关专注模式",
            systemImage: "moon.zzz.fill",
            primaryTitle: "重新创建",
            primaryAction: { [weak self] in self?.onRequestOpenSettings?() },
            secondaryTitle: "忽略",
            secondaryAction: nil
        ))
    }

    /// 退出钩子：联动开着就跑关闭快捷指令恢复原状。
    /// willTerminate 里异步起一个进程没问题 —— 子进程独立存活，
    /// 不等它退出。
    /// 名字转场（检测发现生效对 ≠ 已应用对）：先对旧对执行幂等关闭
    /// （异步即可，不赶时间），再把应用态打回未应用让结算重开新对 ——
    /// 否则暂停/退出会拿新对执行关闭，旧模式被留在开启状态。
    /// Task 提交顺序即子进程队列顺序：旧关先于新开。
    func handleAppliedNamesTransition(from oldNames: FocusModeBridge.ShortcutNames) {
        // 旧对关闭单独取一代：它的回调若晚于后续新对开结算，代数门
        // 会拦下（旧对的失败回滚不得覆盖新对的状态）。
        linkGeneration += 1
        let generation = linkGeneration
        pendingOffCount += 1

        let bridge = focusModeBridge
        Task { @MainActor in
            let result = await bridge.setFocusEngaged(false, with: oldNames)
            if pendingOffCount > 0 { pendingOffCount -= 1 }
            guard generation == linkGeneration else {
                DebugEventLog.shared.log(
                    "联动账本：转场旧关过期回调 gen \(generation)（最新 \(linkGeneration)），不写账"
                )
                return
            }
            if case .failure(let error) = result {
                NSLog("Restly 名字转场关闭旧对失败：\(error)")
            }
            isFocusLinkApplied = false
            syncFocusLinkage()
        }
        // 应用态先归零：sync 的 diff 会看到「期望开着、还没应用」，
        // 计时中就重开新对；未计时则只当旧对收尾。
        isFocusLinkApplied = false
        syncFocusLinkage()
    }

    func handleAppWillTerminate() {
        // 三条件任一为真都补发同步关闭（幂等，宁可多发不可漏发）：
        // desired —— 结算判定要开但指令还没提交；
        // applied —— 开启已确认/乐观记账（含在飞开启）；
        // pendingOffCount —— 有排队的关闭还没确认拉起，随进程消亡
        // 的话先前的开启会把专注留开（round 15 问题 ②）。
        guard isFocusLinkDesired || isFocusLinkApplied || pendingOffCount > 0 else { return }
        isFocusLinkDesired = false
        isFocusLinkApplied = false
        pendingOffCount = 0
        // 退出路径必须同步把子进程拉起来：Task 排队的话，主 actor
        // 回调一返回进程就可能退出，Task 根本没轮到执行，专注模式
        // 被留在开着的状态。Process.run() 只负责拉起（不等待退出），
        // 子进程独立于父进程存活；失败留痕即可 —— 下次启动恢复
        // running focus 后会重新联动，不会卡死在错误状态。
        focusModeBridge.launchOffShortcutSynchronously()
    }

    /// 让菜单栏倒计时状态与 session 对齐：计时中挂秒级 Timer，
    /// 暂停给冻结文本，就绪/空闲收掉。
    private func updateMenuBarDisplay() {
        switch session.status {
        case .running:
            startDisplayTimerIfNeeded()
        case .paused(let remaining):
            stopDisplayTimer()
            menuBarStatus = .paused(menuBarText(PomodoroSession.countdownText(for: remaining)))
        case .awaitingStart, nil:
            stopDisplayTimer()
            menuBarStatus = nil
        }
    }

    /// 菜单栏倒计时文本。专注是番茄、休息是咖啡杯 —— 都是计时状态时
    /// 光看数字分不清在专注还是在休息，标记得跟着阶段走。
    private func menuBarText(_ countdown: String) -> String {
        switch session.phase {
        case .shortBreak, .longBreak: "☕ \(countdown)"
        case .focus, nil: "🍅 \(countdown)"
        }
    }

    private func startDisplayTimerIfNeeded() {
        if displayTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickMenuBarDisplay() }
            }
            // 只是显示用，秒级对齐即可。
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            displayTimer = timer
        }
        tickMenuBarDisplay()
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tickMenuBarDisplay() {
        guard case .running = session.status else { return }
        menuBarStatus = .running(menuBarText(countdownText(at: Date()) ?? "0:00"))
    }

    /// 每次转段都现读设置：进行中的段不受改设置影响，新时长只对下一段生效。
    private func cycleConfiguration() -> PomodoroSession.Cycle {
        PomodoroSession.Cycle(
            focus: runtimeConfiguration.pomodoroDuration(for: .focus, settings: settings),
            shortBreak: runtimeConfiguration.pomodoroDuration(for: .shortBreak, settings: settings),
            longBreak: runtimeConfiguration.pomodoroDuration(for: .longBreak, settings: settings),
            longBreakEvery: settings.pomodoroLongBreakEvery
        )
    }

    private func persistSession() {
        let snapshot = session.snapshot
        defaults.set(snapshot.focusSecondsToday, forKey: Keys.focusSecondsToday)
        defaults.set(snapshot.dayAnchor, forKey: Keys.dayAnchor)
        defaults.set(snapshot.focusCountInCycle, forKey: Keys.focusInCycle)

        guard let phase = snapshot.phase else {
            // 统计保留，进行中的段清干净 —— 读回时没有 phase 就是无事在身。
            defaults.removeObject(forKey: Keys.phase)
            defaults.removeObject(forKey: Keys.status)
            defaults.removeObject(forKey: Keys.endsAt)
            defaults.removeObject(forKey: Keys.pausedRemaining)
            defaults.removeObject(forKey: Keys.phaseDuration)
            return
        }

        defaults.set(phase.rawValue, forKey: Keys.phase)
        switch snapshot.status {
        case .running(let endsAt):
            defaults.set(StatusMarks.running, forKey: Keys.status)
            defaults.set(endsAt, forKey: Keys.endsAt)
            defaults.set(snapshot.phaseDuration ?? 0, forKey: Keys.phaseDuration)
            defaults.removeObject(forKey: Keys.pausedRemaining)
        case .paused(let remaining):
            defaults.set(StatusMarks.paused, forKey: Keys.status)
            defaults.set(remaining, forKey: Keys.pausedRemaining)
            defaults.set(snapshot.phaseDuration ?? 0, forKey: Keys.phaseDuration)
            defaults.removeObject(forKey: Keys.endsAt)
        case .awaitingStart, nil:
            defaults.set(StatusMarks.awaiting, forKey: Keys.status)
            defaults.removeObject(forKey: Keys.endsAt)
            defaults.removeObject(forKey: Keys.pausedRemaining)
            defaults.removeObject(forKey: Keys.phaseDuration)
        }
    }

    private static func readSnapshot(from defaults: UserDefaults, now: Date) -> PomodoroSession.Snapshot {
        let phase = defaults.string(forKey: Keys.phase).flatMap(PomodoroSession.Phase.init(rawValue:))
        var status: PomodoroSession.Status?
        switch defaults.string(forKey: Keys.status) {
        case StatusMarks.running:
            // 用宽松的存档守卫：endsAt 缺失或已不可信时按无状态处理，别硬凑。
            if let endsAt = defaults.object(forKey: Keys.endsAt) as? Date {
                status = .running(endsAt: endsAt)
            }
        case StatusMarks.paused:
            status = .paused(remaining: max(0, defaults.double(forKey: Keys.pausedRemaining)))
        case StatusMarks.awaiting:
            status = .awaitingStart
        default:
            break
        }

        return PomodoroSession.Snapshot(
            phase: phase,
            status: status,
            focusSecondsToday: defaults.integer(forKey: Keys.focusSecondsToday),
            dayAnchor: defaults.object(forKey: Keys.dayAnchor) as? Date
                ?? PomodoroSession(now: now).dayAnchor,
            focusCountInCycle: defaults.integer(forKey: Keys.focusInCycle),
            phaseDuration: defaults.object(forKey: Keys.phaseDuration) as? Int
        )
    }

    private enum Keys {
        static let phase = "pomodoroPhase"
        static let status = "pomodoroStatus"
        static let endsAt = "pomodoroEndsAt"
        static let pausedRemaining = "pomodoroPausedRemaining"
        static let focusSecondsToday = "pomodoroFocusSecondsToday"
        static let dayAnchor = "pomodoroDayAnchor"
        static let focusInCycle = "pomodoroFocusInCycle"
        static let phaseDuration = "pomodoroPhaseDuration"
    }

    private enum StatusMarks {
        static let running = "running"
        static let paused = "paused"
        static let awaiting = "awaiting"
    }
}
