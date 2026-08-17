import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ReminderSettings
    @ObservedObject var manager: ReminderManager
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    @State private var selectedSection = SettingsSection.reminders

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
        case .activity:
            activitySettings
        case .general:
            generalSettings
        }
    }

    private var reminderSettings: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(
                    title: "喝水",
                    subtitle: "用轻量系统通知提醒补充水分",
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
                    NumberSettingRow(
                        title: "连续使用",
                        value: $settings.standIntervalMinutes,
                        range: 1...180,
                        step: 1,
                        unit: "分钟"
                    )
                    .disabled(!settings.standEnabled)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private var activitySettings: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(
                    title: "活动检测",
                    subtitle: "根据键盘、鼠标和触控板输入判断是否计时",
                    systemImage: "cursorarrow.motionlines",
                    tint: .orange
                ) {
                    NumberSettingRow(
                        title: "无操作后暂停",
                        value: $settings.idleThresholdMinutes,
                        range: 1...15,
                        step: 1,
                        unit: "分钟"
                    )
                    SettingsDivider()
                    Label(
                        "连续 \(settings.awayThresholdMinutes) 分钟未检测到输入后，护眼与久坐计时会重新开始。",
                        systemImage: "info.circle"
                    )
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                SettingsCard(
                    title: "当前状态",
                    subtitle: manager.activityState.description,
                    systemImage: activitySystemImage,
                    tint: activityTint
                ) {
                    HStack {
                        Text("最近一次输入")
                        Spacer()
                        Text(idleDescription)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.system(size: 13, weight: .medium, design: .rounded))
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
                        Text("护眼 30 秒、喝水 60 秒、站立 90 秒")
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

    private var idleDescription: String {
        let seconds = Int(manager.idleSeconds)
        if seconds < 60 { return "\(seconds) 秒前" }
        return "\(seconds / 60) 分钟前"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.3"
    }

    private var activitySystemImage: String {
        switch manager.activityState {
        case .active: "bolt.fill"
        case .idle: "pause.fill"
        case .away: "arrow.counterclockwise"
        case .sleeping: "moon.zzz.fill"
        }
    }

    private var activityTint: Color {
        switch manager.activityState {
        case .active: .green
        case .idle: .orange
        case .away, .sleeping: .secondary
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case reminders
    case activity
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminders: "提醒"
        case .activity: "活动检测"
        case .general: "通用"
        }
    }

    var systemImage: String {
        switch self {
        case .reminders: "bell.fill"
        case .activity: "waveform.path.ecg"
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
                .onSubmit {
                    value = min(max(value, range.lowerBound), range.upperBound)
                }
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
