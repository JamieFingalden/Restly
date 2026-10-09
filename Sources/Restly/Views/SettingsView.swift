import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var manager: ReminderManager
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    /// bridge 是执行侧与设置页共用的事实来源（@Published 存在性结论）：
    /// 执行层发现指令没了，footer 不能还绿着。
    @ObservedObject var focusModeBridge: FocusModeBridge
    @State private var selectedSection = SettingsSection.reminders

    // MARK: 专注模式联动的界面状态
    // 是否就位的结论由 bridge @Published 发布（执行侧检测也会更新它），
    // 视图只持有「正在检测」这个本地过程态与安装 sheet 的阶段性状态。
    @State private var isCheckingLinkage = false
    @State private var showCreationChoice = false
    @State private var installSheet: FocusLinkageInstallSheetState?
    /// 等待页的「推迟一拍再呈现」任务。必须随取消/新流程一起取消，
    /// 否则用户关掉等待页 400ms 后它又把 sheet 拉回来 —— 残留状态的
    /// 活教材，正是本轮要抓的那类回归。
    @State private var installSheetPresentationTask: Task<Void, Never>?
    @State private var tutorialPresentationTask: Task<Void, Never>?
    @State private var showTutorial = false
    @State private var installTask: Task<Void, Never>?
    /// 「从已有快捷指令中选择」的选项名单，一次 list 缓存着用。
    @State private var availableShortcutNames: [String]?
    @State private var isLoadingShortcutNames = false
    /// 名字结算的防抖任务与「上次已结算值」（submit+blur 连击去重）。
    @State private var nameSettleTask: Task<Void, Never>?
    @State private var lastSettledNames: (on: String, off: String)?
    /// 名字结算的防抖窗口：连续击键只在停顿后结算一次。
    static let nameSettleDebounce: Duration = .milliseconds(400)

    var body: some View {
        ZStack {
            SettingsBackdrop()

            VStack(spacing: 0) {
                header
                sectionPicker
                Divider().opacity(0.5)
                selectedContent
            }
        }
        .frame(width: 600, height: 590)
        .onAppear {
            DebugEventLog.shared.log("设置页：出现，强制重检联动状态")
            launchAtLoginManager.refresh()
            // 设置窗口每次出现都强制重检：窗口可能开着跨越用户删指令，
            // 旧结论哪怕一分钟前刚查过也会撒谎。设置页不是常驻界面，
            // 每次出现多跑一次 list 可以接受。
            refreshLinkageStatusIfEnabled(force: true)
        }
        .confirmationDialog(
            "快捷指令还没就绪",
            isPresented: $showCreationChoice,
            titleVisibility: .visible
        ) {
            Button("一键创建") {
                DebugEventLog.shared.log("设置页：用户选择一键创建")
                runAutomaticInstall()
            }
            Button("手动创建") {
                DebugEventLog.shared.log("设置页：用户选择手动创建")
                // 与等待页同一招：退场动画期间 present 会被静默丢弃，
                // 看起来像点了没反应。
                tutorialPresentationTask = Self.presentAfterDialogDismissal {
                    showTutorial = true
                }
            }
            Button("取消并关闭联动", role: .destructive) {
                // 取消是唯一把开关拨回去的路径：联动开着而指令不存在，
                // 只会让每个专注流转都白跑进程。
                DebugEventLog.shared.log("设置页：用户取消创建引导，联动关闭")
                settings.pomodoroLinksFocusMode = false
            }
        } message: {
            Text("可以把已有的快捷指令指认给 Restly（下方改名字即可），也可以现在创建。取消将关闭联动。")
        }
        .sheet(
            isPresented: Binding(
                get: { installSheet != nil },
                set: { if !$0 { cancelInstallFlow() } }
            )
        ) {
            FocusLinkageInstallingView(
                state: installSheet ?? .waiting(remainingSeconds: 0),
                onName: settings.resolvedFocusLinkOnName,
                offName: settings.resolvedFocusLinkOffName
            ) { state in
                installSheet = state
            } onCancel: {
                cancelInstallFlow()
            } onRetry: {
                installSheet = .waiting(remainingSeconds: Self.installTotalSeconds)
                runAutomaticInstall()
            } onShowTutorial: {
                // sheet→sheet 转场也要推迟一拍：第一个 sheet 还在退场
                // 时 present 第二个会被 macOS 静默丢弃。
                installSheet = nil
                tutorialPresentationTask = Self.presentAfterDialogDismissal {
                    showTutorial = true
                }
            }
        }
        .sheet(isPresented: $showTutorial) {
            FocusLinkageTutorialView(
                onName: settings.resolvedFocusLinkOnName,
                offName: settings.resolvedFocusLinkOffName,
                check: { await focusModeBridge.checkShortcutsExist(forceRefresh: true) },
                missingNames: { await focusModeBridge.missingShortcutNames() },
                onFinished: {
                    showTutorial = false
                    Task { await refreshLinkageStatus(force: true) }
                }
            )
        }
    }

    // MARK: - 专注模式联动

    /// 拨 ON 一律先置位（乐观开启）：开关立即生效，是否就绪交给
    /// footer 的状态展示。以前「检测通过才写 true」曾让开关当场弹回，
    /// 用户只当是功能坏了。创建引导只是引导，不是门。
    private var linkageToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.pomodoroLinksFocusMode },
            set: { turnOn in
                DebugEventLog.shared.log("设置页：联动开关翻转 → \(turnOn ? "ON" : "OFF")")
                settings.pomodoroLinksFocusMode = turnOn
                guard turnOn else { return }
                // PomodoroManager 的联动同步已随置位生效；这里只负责
                // 把「就绪没有」查出来摆到台面上，缺指令就顺势引导 ——
                // 引导是门厅不是门禁，用户关掉对话框联动照样开着。
                Task { await refreshLinkageStatus(autoGuideOnMissing: true) }
            }
        )
    }

    /// 开关行常驻的状态副标题：结论直接读 bridge 的发布状态（执行侧
    /// 检测缺失会实时把它打成红色），绝不本地缓存撒谎；底下挂检测
    /// 时间与手动重检 —— 窗口开很久时用户自己决定要不要再问一次。
    @ViewBuilder
    private var linkageStatusFooter: some View {
        if settings.pomodoroLinksFocusMode {
            if isCheckingLinkage {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Label("正在检测快捷指令…", systemImage: "magnifyingglass")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    linkageConclusionLabel
                    linkageFreshnessRow
                }
            }
        } else {
            Label(
                "专注计时中自动开启专注模式，转休息或暂停时关闭。",
                systemImage: "info.circle"
            )
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var linkageConclusionLabel: some View {
        switch focusModeBridge.lastKnownExistence {
        case .ready:
            Label("快捷指令已就绪，专注计时将自动开关专注模式。", systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.green.opacity(0.85))
        case .missing:
            Button {
                showCreationChoice = true
            } label: {
                Label(
                    "未检测到「\(settings.resolvedFocusLinkOnName)」「\(settings.resolvedFocusLinkOffName)」，点击重新走创建流程。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        case .unknown, nil:
            Button {
                Task { await refreshLinkageStatus(force: true) }
            } label: {
                Label("尚未确认快捷指令状态，点击立即检测。", systemImage: "questionmark.circle")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var linkageFreshnessRow: some View {
        HStack(spacing: 6) {
            if let date = focusModeBridge.lastExistenceCheckDate {
                Text("上次检测 \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await refreshLinkageStatus(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("重新检测")
            Spacer()
        }
    }

    /// 名字指认区：允许手输，也能从一次 `shortcuts list` 的结果里选。
    /// 只有开关开着（或正要引导创建）才值得花这一个进程去拿名单。
    @ViewBuilder
    private var linkageNameRows: some View {
        if settings.pomodoroLinksFocusMode {
            VStack(alignment: .leading, spacing: 6) {
                shortcutNameRow(
                    title: "开启指令",
                    placeholder: "默认：\(FocusModeBridge.defaultOnShortcutName)",
                    binding: Binding(
                        get: { settings.focusLinkOnShortcutName },
                        set: { settings.focusLinkOnShortcutName = $0 }
                    )
                )
                shortcutNameRow(
                    title: "关闭指令",
                    placeholder: "默认：\(FocusModeBridge.defaultOffShortcutName)",
                    binding: Binding(
                        get: { settings.focusLinkOffShortcutName },
                        set: { settings.focusLinkOffShortcutName = $0 }
                    )
                )
                HStack(spacing: 6) {
                    Button("从已有快捷指令中选择") { loadAvailableShortcutNames(force: false) }
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    if isLoadingShortcutNames {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    Text("名字需与快捷指令 App 中完全一致")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 名字指认变化（下拉选择、手输提交或失焦）后的统一结算：强制
    /// 重检就绪状态 —— 检测给出 .ready 时 bridge 复位熔断并触发
    /// onMissingCleared，manager 随即补执行当前段的联动，不用等用户
    /// 另行刷新或重启。
    ///
    /// 防抖与去重：连续击键只在停顿后结算一次；「submit 后紧跟的
    /// blur」与「值没变的重复 blur」靠 shortcutNameSettleNeeded 的
    /// 值比对跳过，零副作用。
    private func settleAfterShortcutNameChange() {
        let current = (
            on: settings.resolvedFocusLinkOnName,
            off: settings.resolvedFocusLinkOffName
        )
        guard Self.shortcutNameSettleNeeded(current: current, lastSettled: lastSettledNames) else { return }
        nameSettleTask?.cancel()
        nameSettleTask = Task { @MainActor in
            try? await Task.sleep(for: Self.nameSettleDebounce)
            guard !Task.isCancelled else { return }
            let settled = (
                on: settings.resolvedFocusLinkOnName,
                off: settings.resolvedFocusLinkOffName
            )
            guard Self.shortcutNameSettleNeeded(current: settled, lastSettled: lastSettledNames) else { return }
            lastSettledNames = settled
            await refreshLinkageStatus(force: true)
        }
    }

    /// 结算去重契约：与上次已结算值相同 → 跳过；值变了（或从未结算）
    /// → 结算。
    static func shortcutNameSettleNeeded(
        current: (on: String, off: String),
        lastSettled: (on: String, off: String)?
    ) -> Bool {
        guard let lastSettled else { return true }
        return current != lastSettled
    }

    private func shortcutNameRow(
        title: String,
        placeholder: String,
        binding: Binding<String>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 60, alignment: .leading)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
            Menu {
                if let availableShortcutNames {
                    ForEach(availableShortcutNames, id: \.self) { name in
                        Button(name) {
                        binding.wrappedValue = name
                        settleAfterShortcutNameChange()
                    }
                    }
                } else {
                    Button("先加载列表") { loadAvailableShortcutNames(force: false) }
                }
                Divider()
                Button("刷新列表") { loadAvailableShortcutNames(force: true) }
            } label: {
                // 下拉选中走与手输提交完全相同的结算路径。
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 12.5, design: .rounded))
        // 失焦/编辑结束：macOS 13 没有 onFocusChange，用编辑值变化 +
        // 防抖兜住「不按回车直接点别处」的未结算编辑；值未变由
        // settle 的去重跳过。
        .onChange(of: binding.wrappedValue) { _ in settleAfterShortcutNameChange() }
        .onSubmit { settleAfterShortcutNameChange() }
    }

    private func loadAvailableShortcutNames(force: Bool) {
        guard !isLoadingShortcutNames else { return }
        if !force, availableShortcutNames != nil { return }
        isLoadingShortcutNames = true
        Task {
            availableShortcutNames = await focusModeBridge.listShortcutNames()
            isLoadingShortcutNames = false
        }
    }

    private func refreshLinkageStatus(force: Bool = false, autoGuideOnMissing: Bool = false) async {
        guard settings.pomodoroLinksFocusMode else { return }
        guard !isCheckingLinkage else { return }
        isCheckingLinkage = true
        let existence = await focusModeBridge.checkShortcutsExist(forceRefresh: force)
        isCheckingLinkage = false
        // await 期间用户可能已把开关关掉：以关后的设置为准收尾 ——
        // 不给已关闭的功能弹引导（呈现决策见 shouldShowCreationGuide）。
        if Self.shouldShowCreationGuide(
            isLinkageEnabled: settings.pomodoroLinksFocusMode,
            existence: existence,
            autoGuide: autoGuideOnMissing
        ) {
            showCreationChoice = true
        }
    }

    /// 检查返回后的呈现决策（纯函数钉契约）：联动开着、没就绪、且
    /// 本次刷新来自用户主动动作（autoGuide）才弹创建引导 —— onAppear、
    /// 教程关闭后的例行刷新（autoGuide=false）不弹，否则刚关掉教程
    /// 又立刻被弹；await 期间被关掉（isLinkageEnabled=false）一律收尾。
    static func shouldShowCreationGuide(
        isLinkageEnabled: Bool,
        existence: FocusModeBridge.Existence,
        autoGuide: Bool
    ) -> Bool {
        isLinkageEnabled && autoGuide && existence != .ready
    }

    private func refreshLinkageStatusIfEnabled(force: Bool = false) {
        Task { await refreshLinkageStatus(force: force) }
    }

    /// 安装确认轮询的总量与节奏（15 次 × 2 秒 = 30 秒），超时即止。
    private static let installTotalSeconds = 30
    private static let installPollInterval: TimeInterval = 2

    /// 对话框退场动画的时长上界：动画期间设置呈现状态会被 macOS
    /// 静默丢弃，所有对话框动作触发的 sheet 都统一推迟这一拍。
    static let dialogDismissalDelay: Duration = .milliseconds(400)

    /// 对话框动作触发的 sheet 统一走这里推迟呈现（等待页与「手动
    /// 创建」教程共用 —— 各抄一遍魔法数字迟早改岔）。
    static func presentAfterDialogDismissal(
        delay: Duration = dialogDismissalDelay,
        _ present: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            // sleep 吞掉 CancellationError 也要拦住已取消的呈现：
            // 否则 400ms 内生成的失败终态会被改回 .waiting，重启流程
            // 时取消的未决呈现也会把旧 sheet 拉回来。
            guard !Task.isCancelled else { return }
            present()
        }
    }

    /// 呈现任务到点时该把 sheet 置成什么：流程已有结局就让位（nil，
    /// 结局任务会写自己的终态），仍未定才上等待页。调用点与结局写入
    /// 全部在主线程串行执行，配合取消标志不存在交错。
    static func installSheetPresentationState(hasOutcome: Bool) -> FocusLinkageInstallSheetState? {
        hasOutcome ? nil : .waiting(remainingSeconds: installTotalSeconds)
    }

    /// 关闭等待页的所有入口（取消按钮、Esc、点外部）都走这里：
    /// 只清 sheet 不停任务的话，下一轮轮询会把 sheet 再弹回来，
    /// 用户根本关不掉 —— 实测复现过的 bug。
    private func cancelInstallFlow() {
        DebugEventLog.shared.log("一键创建：用户关闭等待页，轮询终止")
        installTask?.cancel()
        installTask = nil
        installSheetPresentationTask?.cancel()
        installSheetPresentationTask = nil
        installSheet = nil
    }

    /// 轮询写等待页前过这道闸：任务已被用户取消就不得再呈现。
    static func waitingSheetUpdate(isCancelled: Bool, remainingSeconds: Int) -> FocusLinkageInstallSheetState? {
        isCancelled ? nil : .waiting(remainingSeconds: remainingSeconds)
    }

    /// 一键创建：生成文件并交给快捷指令 App，随后有界轮询等用户
    /// 点完「添加快捷指令」。生成/打开失败带原因进 sheet，绝不静默。
    private func runAutomaticInstall() {
        DebugEventLog.shared.log("一键创建：流程启动")
        installTask?.cancel()
        installSheetPresentationTask?.cancel()
        installSheetPresentationTask = Self.presentAfterDialogDismissal {
            installSheet = Self.installSheetPresentationState(hasOutcome: false)
        }
        installTask = Task {
            let outcome = await focusModeBridge.installShortcuts()
            DebugEventLog.shared.log("一键创建：installShortcuts 返回 \(outcome)")
            if Task.isCancelled { return }
            // 结局先到（生成/打开在 400ms 内就失败过）：取消呈现任务，
            // 否则它到点把状态改回 .waiting，sheet 卡在等待态没有重试
            // 入口。取消与写入都在主线程串行，不会交错。
            installSheetPresentationTask?.cancel()
            switch outcome {
            case .opened:
                break
            case .cancelled:
                // cancelInstallFlow 已把 sheet 收掉、状态归位，这里不再动。
                return
            case .generationFailed(let reason):
                installSheet = .generationFailed(reason)
                return
            case .openFailed(let reason):
                installSheet = .openFailed(reason)
                return
            }

            var elapsed = 0
            while elapsed < Self.installTotalSeconds {
                if Task.isCancelled { return }
                let remaining = max(0, Self.installTotalSeconds - elapsed)
                if let update = Self.waitingSheetUpdate(isCancelled: Task.isCancelled, remainingSeconds: remaining) {
                    installSheet = update
                }
                try? await Task.sleep(for: .seconds(Self.installPollInterval))
                if Task.isCancelled { return }
                elapsed += Int(Self.installPollInterval)
                if await focusModeBridge.confirmInstalled() {
                    DebugEventLog.shared.log("一键创建：轮询 \(elapsed) 秒时确认已就绪")
                    installSheet = nil
                    return
                }
                DebugEventLog.shared.log("一键创建：轮询 \(elapsed)/\(Self.installTotalSeconds) 秒，尚未就绪")
            }
            DebugEventLog.shared.log("一键创建：轮询超时，降级为未检测到")
            installSheet = .timedOut
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            RestlyBrandMark(size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Restly 设置")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text("按照你的节奏，安排健康休息")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("v\(appVersion)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .restlyGlassSurface(cornerRadius: 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    private var sectionPicker: some View {
        Picker("设置分类", selection: $selectedSection) {
            ForEach(SettingsSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .reminders:
            reminderSettings
        case .pomodoro:
            pomodoroSettings
        case .general:
            generalSettings
        }
    }

    private var reminderSettings: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(
                    title: "喝水",
                    subtitle: "用轻量浮窗提醒补充水分",
                    systemImage: "drop.fill",
                    tint: .blue
                ) {
                    Toggle("开启喝水提醒", isOn: $settings.waterEnabled)
                    SettingsDivider()
                    NumberSettingRow(
                        title: "提醒间隔",
                        value: $settings.waterIntervalMinutes,
                        range: 1...180,
                        step: 1,
                        unit: "分钟"
                    )
                    .disabled(!settings.waterEnabled)
                }

                SettingsCard(
                    title: "眼睛休息",
                    subtitle: "全屏休息，帮助视线离开屏幕",
                    systemImage: "eye.fill",
                    tint: .indigo
                ) {
                    Toggle("开启护眼提醒", isOn: $settings.eyeEnabled)
                    SettingsDivider()
                    Group {
                        NumberSettingRow(
                            title: "提醒间隔",
                            value: $settings.eyeIntervalMinutes,
                            range: 5...120,
                            step: 5,
                            unit: "分钟"
                        )
                        NumberSettingRow(
                            title: "休息时长",
                            value: $settings.eyeRestDurationSeconds,
                            range: 10...120,
                            step: 5,
                            unit: "秒"
                        )
                    }
                    .disabled(!settings.eyeEnabled)
                }

                SettingsCard(
                    title: "站立活动",
                    subtitle: "只累计真实电脑使用时间",
                    systemImage: "figure.stand",
                    tint: .green
                ) {
                    Toggle("开启站立提醒", isOn: $settings.standEnabled)
                    SettingsDivider()
                    Group {
                        NumberSettingRow(
                            title: "连续使用",
                            value: $settings.standIntervalMinutes,
                            range: 1...180,
                            step: 1,
                            unit: "分钟"
                        )
                        SettingsDivider()
                        Toggle(
                            "点击「我起来了」后锁定电脑",
                            isOn: $settings.lockScreenAfterStanding
                        )
                        Label(
                            "锁定前会显示 2 秒倒计时，可以取消。",
                            systemImage: "lock.fill"
                        )
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                    .disabled(!settings.standEnabled)
                }

                SettingsCard(
                    title: "浮窗提醒",
                    subtitle: "喝水与站立提醒共用",
                    systemImage: "rectangle.topthird.inset.filled",
                    tint: .teal
                ) {
                    Toggle(
                        "5 秒后自动消失",
                        isOn: $settings.autoDismissHealthToasts
                    )
                    SettingsDivider()
                    Label(
                        settings.autoDismissHealthToasts
                            ? "未操作时，浮窗会在 5 秒后收起。"
                            : "浮窗会一直保留，直到你点击完成或稍后提醒。",
                        systemImage: "info.circle"
                    )
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                SettingsCard(
                    title: "离开重置",
                    subtitle: "锁屏、息屏或合盖多久算一次真正的休息",
                    systemImage: "arrow.counterclockwise",
                    tint: .orange
                ) {
                    NumberSettingRow(
                        title: "离开超过",
                        value: $settings.lockResetThresholdMinutes,
                        range: 1...30,
                        step: 1,
                        unit: "分钟"
                    )
                    SettingsDivider()
                    Label(
                        "离开超过 \(settings.lockResetThresholdMinutes) 分钟，护眼和站立计时从零开始 —— 眼睛已经离开屏幕，人也站起来过了。喝水不重置，离开不代表喝了水。",
                        systemImage: "info.circle"
                    )
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private var pomodoroSettings: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(
                    title: "番茄钟",
                    subtitle: "专注与休息的循环",
                    systemImage: "timer",
                    tint: Color(red: 0.85, green: 0.32, blue: 0.26)
                ) {
                    Group {
                        NumberSettingRow(
                            title: "专注时长",
                            value: $settings.pomodoroFocusMinutes,
                            range: 5...120,
                            step: 5,
                            unit: "分钟"
                        )
                        NumberSettingRow(
                            title: "短休息",
                            value: $settings.pomodoroShortBreakMinutes,
                            range: 1...30,
                            step: 1,
                            unit: "分钟"
                        )
                        NumberSettingRow(
                            title: "长休息",
                            value: $settings.pomodoroLongBreakMinutes,
                            range: 5...60,
                            step: 5,
                            unit: "分钟"
                        )
                        NumberSettingRow(
                            title: "长休息间隔",
                            value: $settings.pomodoroLongBreakEvery,
                            range: 2...8,
                            step: 1,
                            unit: "个番茄"
                        )
                    }
                    SettingsDivider()
                    Label(
                        "修改时长只影响下一段开始的计时，进行中的阶段不受影响。",
                        systemImage: "info.circle"
                    )
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                SettingsCard(
                    title: "阶段流转",
                    subtitle: "一段结束后下一段怎么开始",
                    systemImage: "arrow.2.circlepath",
                    tint: .orange
                ) {
                    Toggle("专注结束后自动开始休息", isOn: $settings.pomodoroAutoStartBreak)
                    SettingsDivider()
                    Toggle("休息结束后自动开始下一个专注", isOn: $settings.pomodoroAutoStartFocus)
                    SettingsDivider()
                    Toggle("在菜单栏显示倒计时", isOn: $settings.pomodoroShowsInMenuBar)
                    SettingsDivider()
                    Toggle("与 macOS 专注模式联动", isOn: linkageToggleBinding)
                    linkageStatusFooter
                    linkageNameRows
                    SettingsDivider()
                    Label(
                        settings.pomodoroAutoStartBreak
                            ? "专注一结束就进入休息，转段时浮窗通知。"
                            : "专注结束后浮窗询问，点「开始休息」才计时。",
                        systemImage: "info.circle"
                    )
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private var generalSettings: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(
                    title: "登录启动",
                    subtitle: "登录 Mac 后在菜单栏自动运行",
                    systemImage: "power",
                    tint: .teal
                ) {
                    Toggle(
                        "登录时自动启动 Restly",
                        isOn: Binding(
                            get: { launchAtLoginManager.isEnabled },
                            set: { launchAtLoginManager.setEnabled($0) }
                        )
                    )
                    if let statusMessage = launchAtLoginManager.statusMessage {
                        SettingsDivider()
                        Label(statusMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                }

                if manager.runtimeConfiguration.isDevelopmentMode {
                    SettingsCard(
                        title: "开发模式",
                        subtitle: "短间隔验证，不会修改正式设置",
                        systemImage: "hammer.fill",
                        tint: .purple
                    ) {
                        Text("护眼 30 秒、喝水 60 秒、站立 90 秒；番茄钟 30/10/20 秒")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                        Button("立即测试全屏护眼") {
                            manager.triggerEyeRestForTesting()
                        }
                    }
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private var appVersion: String {
        AppVersionText.displayText(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

}

/// 设置页标着「0.2.0 (23)」才分得清手里跑的是哪次构建 ——
/// 短版本号在多次构建之间经常不变。从 Bundle 读，两端都可能缺
/// （swift run 开发态没有 Info.plist），各自兜底。
enum AppVersionText {
    static func displayText(shortVersion: String?, buildVersion: String?) -> String {
        switch (shortVersion, buildVersion) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return "开发版 (\(build))"
        default: return "开发版"
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case reminders
    case pomodoro
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminders: "提醒"
        case .pomodoro: "番茄钟"
        case .general: "通用"
        }
    }

    var systemImage: String {
        switch self {
        case .reminders: "bell.fill"
        case .pomodoro: "timer"
        case .general: "gearshape.fill"
        }
    }
}

private struct SettingsBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.teal.opacity(0.1), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color.blue.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            content
                .font(.system(size: 13, design: .rounded))
        }
        .padding(16)
        .restlyGlassSurface(cornerRadius: 17)
    }
}

private struct NumberSettingRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            TextField("", value: clampedValue, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Stepper("", value: clampedValue, in: range, step: step)
                .labelsHidden()
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
    }

    private var clampedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().opacity(0.55)
    }
}

/// 一键创建 sheet 的几种面貌：等待（带剩余秒数）、超时点名、
/// 生成失败、打开失败。每种失败都带原因与出路，不再静默跳教程。
enum FocusLinkageInstallSheetState: Equatable {
    case waiting(remainingSeconds: Int)
    case timedOut
    case generationFailed(String)
    case openFailed(String)
}

/// 一键创建页。等待阶段只做一件事：说清楚接下来要去快捷指令 App
/// 点什么；任何失败都把原因和出路摆在同一屏里。
private struct FocusLinkageInstallingView: View {
    let state: FocusLinkageInstallSheetState
    let onName: String
    let offName: String
    let onStateChange: (FocusLinkageInstallSheetState) -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onShowTutorial: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            switch state {
            case .waiting(let remainingSeconds):
                waitingContent(remainingSeconds: remainingSeconds)
            case .timedOut:
                failedContent(
                    icon: "hourglass",
                    title: "没有等到快捷指令确认",
                    detail: "未检测到名字完全为「\(onName)」「\(offName)」的快捷指令。\n请确认已在快捷指令 App 中各点过「添加快捷指令」，或核对名字是否一致。"
                )
            case .generationFailed(let reason):
                failedContent(
                    icon: "xmark.octagon",
                    title: "生成快捷指令文件失败",
                    detail: reason
                )
            case .openFailed(let reason):
                failedContent(
                    icon: "xmark.octagon",
                    title: "无法交给快捷指令 App",
                    detail: reason
                )
            }
        }
        .padding(28)
        .frame(width: 400)
    }

    @ViewBuilder
    private func waitingContent(remainingSeconds: Int) -> some View {
        ProgressView()
            .controlSize(.large)

        VStack(spacing: 6) {
            Text("正在等待快捷指令确认（约 \(remainingSeconds) 秒）")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("请在快捷指令 App 中，为「\(onName)」「\(offName)」各点一次「添加快捷指令」。")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320)

        Button("取消") { onCancel() }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
    }

    @ViewBuilder
    private func failedContent(icon: String, title: String, detail: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.orange)

        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320)

        HStack(spacing: 10) {
            Button("重试") { onRetry() }
                .buttonStyle(.borderedProminent)
            Button("看手动教程") { onShowTutorial() }
            Button("完成") { onCancel() }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .controlSize(.regular)
    }
}

/// 手动创建教程。名字是 Restly 调用快捷指令的唯一凭据，
/// 所以期望名字给成可复制的文本，创建完当场复核并回显结论。
private struct FocusLinkageTutorialView: View {
    let onName: String
    let offName: String
    let check: () async -> FocusModeBridge.Existence
    let missingNames: () async -> [String]
    let onFinished: () -> Void

    private enum CheckResult: Equatable {
        case checking
        case ready
        case missing([String])
        case unknown
    }

    @State private var result: CheckResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("手动创建快捷指令")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("一共两条，名字必须与下面一字不差 —— Restly 按名字调用它们。")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                tutorialStep(
                    index: 1,
                    title: "新建快捷指令",
                    detail: "打开快捷指令 App，点「+」新建。"
                )
                tutorialStep(
                    index: 2,
                    title: "添加「设置专注模式」动作，选「打开」",
                    detail: "然后把快捷指令命名为下方第一条名字。"
                )
                tutorialStep(
                    index: 3,
                    title: "再新建一条，动作选「关闭」",
                    detail: "命名为下方第二条名字。"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                copyableNameRow(label: "开启指令", name: onName)
                copyableNameRow(label: "关闭指令", name: offName)
            }

            Label(
                "导入后请点开动作确认目标专注模式已选中（系统内置模式按本地化名字匹配，可能有出入）；也可以换成任何你想要的模式，名字保持不变即可。",
                systemImage: "info.circle"
            )
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            checkResultFooter

            HStack {
                Button("打开快捷指令.app") {
                    let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
                    if !NSWorkspace.shared.open(url) {
                        NSLog("Restly 无法打开快捷指令 App。")
                    }
                }
                Spacer()
                Button("我已创建完成") { Task { await verifyCreation() } }
                Button("完成") { onFinished() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    /// 期望名字做成可复制：手输名字错一个字就永远检测不到。
    private func copyableNameRow(label: String, name: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(name)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(name, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("复制名字")
        }
    }

    @ViewBuilder
    private var checkResultFooter: some View {
        switch result {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在检测…")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("已检测到两条快捷指令，联动就绪。", systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.green.opacity(0.9))
        case .missing(let names):
            Label(
                "仍未检测到「\(names.joined(separator: "」「"))」。请核对名字，或在设置里改用「从已有快捷指令中选择」指认你现有的指令。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            Label("暂时无法读取快捷指令列表，请稍后再试。", systemImage: "questionmark.circle")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private func verifyCreation() async {
        result = .checking
        let existence = await check()
        switch existence {
        case .ready:
            result = .ready
        case .missing:
            result = .missing(await missingNames())
        case .unknown:
            result = .unknown
        }
    }

    private func tutorialStep(index: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(detail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
