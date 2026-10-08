import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var manager: ReminderManager
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    let focusModeBridge: FocusModeBridge
    @State private var selectedSection = SettingsSection.reminders

    // MARK: 专注模式联动的界面状态
    // 安装是否完成、快捷指令是否就位都只有系统能回答，视图只存结论。
    @State private var linkageStatus = FocusModeBridge.Existence.unknown
    @State private var showCreationChoice = false
    @State private var isInstalling = false
    @State private var installTimedOut = false
    @State private var showTutorial = false
    @State private var installTask: Task<Void, Never>?

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
            launchAtLoginManager.refresh()
            refreshLinkageStatusIfEnabled()
        }
        .confirmationDialog(
            "是否一键创建快捷指令？",
            isPresented: $showCreationChoice,
            titleVisibility: .visible
        ) {
            Button("一键创建") { runAutomaticInstall() }
            Button("手动创建") { showTutorial = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Restly 将生成「Restly 专注开启」「Restly 专注关闭」两条快捷指令，请在快捷指令 App 中各点一次「添加快捷指令」。")
        }
        .sheet(isPresented: $isInstalling) {
            FocusLinkageInstallingView(onCancel: cancelInstall)
        }
        .sheet(isPresented: $showTutorial) {
            FocusLinkageTutorialView(
                onFinished: {
                    showTutorial = false
                    refreshLinkageStatusIfEnabled(force: true)
                }
            )
        }
    }

    // MARK: - 专注模式联动

    private var linkageToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.pomodoroLinksFocusMode },
            set: { turnOn in
                guard turnOn else {
                    // 直接关：PomodoroManager 的联动同步会立刻执行关闭指令
                    // 恢复原状（若此刻专注模式还开着）。
                    settings.pomodoroLinksFocusMode = false
                    return
                }
                // 先静默确认：两条快捷指令都在就直接开启，不打扰。
                Task {
                    let existence = await focusModeBridge.checkShortcutsExist()
                    if existence == .ready {
                        linkageStatus = .ready
                        settings.pomodoroLinksFocusMode = true
                    } else {
                        linkageStatus = existence
                        showCreationChoice = true
                    }
                }
            }
        )
    }

    /// 开关行常驻的状态副标题：就绪给确认，缺失给可点的重建入口。
    @ViewBuilder
    private var linkageStatusFooter: some View {
        if settings.pomodoroLinksFocusMode {
            switch linkageStatus {
            case .ready:
                Label("快捷指令已就绪，专注计时将自动开关专注模式。", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.green.opacity(0.85))
            case .missing, .unknown:
                Button {
                    showCreationChoice = true
                } label: {
                    Label("未检测到快捷指令，点击重新走创建流程。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
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

    private func refreshLinkageStatusIfEnabled(force: Bool = false) {
        guard settings.pomodoroLinksFocusMode else { return }
        Task {
            linkageStatus = await focusModeBridge.checkShortcutsExist(forceRefresh: force)
        }
    }

    /// 一键创建：生成文件并交给快捷指令 App，随后有界轮询等用户
    /// 点完「添加快捷指令」。检测到就绪即停；超时不重试、不循环，
    /// 降级成「未检测到」并给出手动教程。
    private func runAutomaticInstall() {
        installTimedOut = false
        isInstalling = true
        installTask = Task {
            let opened = await focusModeBridge.installShortcuts()
            guard opened else {
                isInstalling = false
                showTutorial = true
                return
            }
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                if await focusModeBridge.confirmInstalled() {
                    linkageStatus = .ready
                    isInstalling = false
                    settings.pomodoroLinksFocusMode = true
                    return
                }
            }
            linkageStatus = .missing
            installTimedOut = true
            isInstalling = false
        }
    }

    private func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        isInstalling = false
        linkageStatus = .missing
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
                    if installTimedOut && !settings.pomodoroLinksFocusMode {
                        Button("一键创建没有等到确认，改用手动创建教程") {
                            showTutorial = true
                        }
                        .font(.system(size: 12, design: .rounded))
                    }
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
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

/// 一键创建的等待页。生成的文件已经交给快捷指令 App，剩下的只有
/// 用户点「添加快捷指令」—— 这里只负责把这件事说清楚，轮询由
/// SettingsView 有界进行，等不到就降级，不无限等。
private struct FocusLinkageInstallingView: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text("正在等待快捷指令确认")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("请在快捷指令 App 中，为「Restly 专注开启」「Restly 专注关闭」各点一次「添加快捷指令」。")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 300)

            Button("取消") { onCancel() }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .padding(28)
        .frame(width: 380)
    }
}

/// 手动创建教程。名字是 Restly 调用快捷指令的唯一凭据，
/// 所以这里反复强调一字不差。
private struct FocusLinkageTutorialView: View {
    let onFinished: () -> Void

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
                    detail: "然后把快捷指令命名为「Restly 专注开启」。"
                )
                tutorialStep(
                    index: 3,
                    title: "再新建一条，动作选「关闭」",
                    detail: "命名为「Restly 专注关闭」。"
                )
            }

            Label(
                "导入或创建后，可以把动作里的专注模式改成任何你想要的模式，名字保持不变即可。",
                systemImage: "info.circle"
            )
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("打开快捷指令.app") {
                    let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
                    if !NSWorkspace.shared.open(url) {
                        NSLog("Restly 无法打开快捷指令 App。")
                    }
                }
                Spacer()
                Button("完成") { onFinished() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
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
