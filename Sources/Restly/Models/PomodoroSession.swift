import Foundation

/// 番茄钟会话。
///
/// 计时按墙钟：running 只记结束时刻，暂停只记剩余秒 —— 与 `ReminderSchedule`
/// 同理，不做递减累加，就不会因为系统节流悄悄丢时间。
/// 模型只负责状态怎么变；定时器、Toast、持久化由 `PomodoroManager` 响应
/// 各个方法返回的编排指令去做。
struct PomodoroSession: Equatable, Sendable {
    /// 一段的种类。长短休息是两种段而不是「休息 + 时长」——
    /// 长休息出现的时机由循环内专注数决定，和段的身份绑在一起更直观。
    enum Phase: String, Equatable, Sendable {
        case focus
        case shortBreak
        case longBreak

        var isBreak: Bool {
            switch self {
            case .focus: false
            case .shortBreak, .longBreak: true
            }
        }

        var title: String {
            switch self {
            case .focus: "专注"
            case .shortBreak: "短休息"
            case .longBreak: "长休息"
            }
        }

        /// "tomato" 要 SF Symbols 5（macOS 14），目标系统是 macOS 13。
        var systemImage: String {
            switch self {
            case .focus: "timer"
            case .shortBreak, .longBreak: "cup.and.saucer.fill"
            }
        }
    }

    /// 这一段处于哪种进行状态。
    enum Status: Equatable, Sendable {
        /// 计时中，到 `endsAt` 自然结束。
        case running(endsAt: Date)
        /// 暂停中，只记冻结那一刻的剩余时长。
        case paused(remaining: TimeInterval)
        /// 就绪，等用户按下开始。
        case awaitingStart
    }

    /// 一次流转的编排指令：状态已经变完，manager 照此起定时器、弹 Toast。
    enum Outcome: Equatable, Sendable {
        /// 已自动开始下一段。
        case started(Phase)
        /// 停在就绪态，等用户开始下一段。
        case awaiting(Phase)
        /// 回到空闲（无事发生或用户主动停止）。
        case becameIdle
    }

    /// 一轮循环需要的全部时长。manager 每次转段时从设置现读 ——
    /// 进行中的段不受改设置影响，新时长只对下一段生效。
    struct Cycle: Equatable, Sendable {
        var focus: TimeInterval
        var shortBreak: TimeInterval
        var longBreak: TimeInterval
        /// 每完成几个专注安排一次长休息。
        var longBreakEvery: Int

        func duration(for phase: Phase) -> TimeInterval {
            switch phase {
            case .focus: focus
            case .shortBreak: shortBreak
            case .longBreak: longBreak
            }
        }
    }

    /// 持久化用的完整快照，重启时由 manager 从 UserDefaults 重建。
    struct Snapshot: Equatable, Sendable {
        var phase: Phase?
        var status: Status?
        var focusSecondsToday: Int = 0
        var dayAnchor: Date
        var focusCountInCycle: Int = 0
        /// 计时中段的标称时长（秒）。完成时按它计入今日总时长。
        var phaseDuration: Int?
    }

    /// 当前段。nil 表示空闲（没有进行中的循环）。
    private(set) var phase: Phase?
    private(set) var status: Status?
    /// 今日累计的专注时长（秒），只统计完整走完的专注，跳过不计。
    /// 跨天清零，`dayAnchor` 记住它属于哪一天。
    private(set) var focusSecondsToday: Int
    private(set) var dayAnchor: Date
    /// 本循环内已完成的专注数。跳过不增加；长休息按它取模，循环跨天连续。
    private(set) var focusCountInCycle: Int
    /// 当前计时中段的标称时长。非 running 状态下为 nil。
    private(set) var phaseDuration: Int?

    /// 从零开始的一天。`now` 决定「今天」是哪天。
    init(now: Date, calendar: Calendar = .current) {
        phase = nil
        status = nil
        focusSecondsToday = 0
        dayAnchor = calendar.startOfDay(for: now)
        focusCountInCycle = 0
        phaseDuration = nil
    }

    init(snapshot: Snapshot) {
        phase = snapshot.phase
        status = snapshot.status
        focusSecondsToday = snapshot.focusSecondsToday
        dayAnchor = snapshot.dayAnchor
        focusCountInCycle = snapshot.focusCountInCycle
        phaseDuration = snapshot.phaseDuration
    }

    var snapshot: Snapshot {
        Snapshot(
            phase: phase,
            status: status,
            focusSecondsToday: focusSecondsToday,
            dayAnchor: dayAnchor,
            focusCountInCycle: focusCountInCycle,
            phaseDuration: phaseDuration
        )
    }

    var isIdle: Bool { phase == nil }

    // MARK: - 查询

    func remaining(at now: Date) -> TimeInterval? {
        switch status {
        case .running(let endsAt):
            max(0, endsAt.timeIntervalSince(now))
        case .paused(let remaining):
            remaining
        case .awaitingStart, nil:
            nil
        }
    }

    func isDue(at now: Date) -> Bool {
        guard case .running(let endsAt) = status else { return false }
        return endsAt <= now
    }

    /// mm:ss。番茄钟最长两小时，超过 99 分钟就让分钟位数自然变长。
    static func countdownText(for remaining: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(remaining)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 今日专注总时长的展示文案。只统计完整走完的专注。
    static func focusSummaryText(secondsToday: Int) -> String {
        let minutes = secondsToday / 60
        switch minutes {
        case ..<1:
            return "今天还没有完整的专注"
        case ..<60:
            return "今日已专注 \(minutes) 分钟"
        default:
            return "今日已专注 \(minutes / 60) 小时 \(minutes % 60) 分"
        }
    }

    /// 完成第 `afterFocusCount` 个专注之后该休息哪种。
    /// 一个都还没完成过（比如刚跳过第一个专注）时给短休息 —— 0 % n == 0
    /// 会误判成长休息，白送的 15 分钟不属于还没开始的循环。
    static func breakKind(afterFocusCount: Int, longBreakEvery: Int) -> Phase {
        guard afterFocusCount > 0 else { return .shortBreak }
        let every = max(1, longBreakEvery)
        return afterFocusCount % every == 0 ? .longBreak : .shortBreak
    }

    // MARK: - 操作

    mutating func start(_ phase: Phase, at now: Date, cycle: Cycle) {
        self.phase = phase
        let duration = max(1, cycle.duration(for: phase))
        status = .running(endsAt: now.addingTimeInterval(duration))
        phaseDuration = Int(duration)
    }

    mutating func pause(at now: Date) {
        guard case .running(let endsAt) = status else { return }
        status = .paused(remaining: max(0, endsAt.timeIntervalSince(now)))
    }

    mutating func resume(at now: Date) {
        guard case .paused(let remaining) = status else { return }
        status = .running(endsAt: now.addingTimeInterval(remaining))
    }

    /// 跳过当前段：不计入任何完成数，落到下一段的就绪态。
    /// 专注没做完就跳过，下一段照常按循环位置给休息 —— 要不要休由用户自己决定。
    /// 就绪态里跳过的则是「下一段」本身：跳过休息直接回到专注，跳过专注等于停止。
    mutating func skip(cycle: Cycle) -> Outcome {
        guard let current = phase else { return .becameIdle }

        if case .awaitingStart = status {
            switch current {
            case .focus:
                stop()
                return .becameIdle
            case .shortBreak, .longBreak:
                phase = .focus
                status = .awaitingStart
                phaseDuration = nil
                return .awaiting(.focus)
            }
        }

        let next: Phase = current.isBreak
            ? .focus
            : Self.breakKind(afterFocusCount: focusCountInCycle, longBreakEvery: cycle.longBreakEvery)
        phase = next
        status = .awaitingStart
        phaseDuration = nil
        return .awaiting(next)
    }

    /// 停止整个循环。今日累计时长保留（那是已经发生的事实），循环计数清零 ——
    /// 下次开始是一轮新循环，长休息的节奏从头数起。
    mutating func stop() {
        phase = nil
        status = nil
        focusCountInCycle = 0
        phaseDuration = nil
    }

    /// 当前段走满自然结束。`autoStartNext` 由 manager 按设置传入：
    /// 专注结束看「自动开始休息」，休息结束看「自动开始专注」。
    mutating func completePhase(at now: Date, cycle: Cycle, autoStartNext: Bool) -> Outcome {
        guard let current = phase, isDue(at: now) else { return .becameIdle }

        let next: Phase
        if current == .focus {
            rollDayIfNeeded(at: now)
            // 只有完整走完的专注才计入今日总时长；跳过的不算。
            focusSecondsToday += phaseDuration ?? 0
            focusCountInCycle += 1
            next = Self.breakKind(afterFocusCount: focusCountInCycle, longBreakEvery: cycle.longBreakEvery)
        } else {
            next = .focus
        }

        phase = next
        if autoStartNext {
            let duration = max(1, cycle.duration(for: next))
            status = .running(endsAt: now.addingTimeInterval(duration))
            phaseDuration = Int(duration)
            return .started(next)
        }
        status = .awaitingStart
        phaseDuration = nil
        return .awaiting(next)
    }

    /// 跨天时清零今日累计时长。循环计数不清 —— 长休息的节奏不该因为睡一觉重排。
    mutating func rollDayIfNeeded(at now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard today > dayAnchor else { return }
        dayAnchor = today
        focusSecondsToday = 0
    }

    // MARK: - 重启恢复

    enum RestorationOutcome: Equatable, Sendable {
        /// 存档仍是有效的计时中状态，原样继续。
        case running
        /// 存档是暂停态。重启后统一按手动暂停处理 —— 锁屏上下文已经丢失。
        case paused
        /// 存档在就绪态，等用户开始。
        case awaiting
        /// 计时中的存档在重启期间走完了：专注按已完成计，休息直接作废，都落在空闲。
        /// 不自动衔接下一段 —— 那是几小时前的事了，自动开始只会错时。
        case expired
        /// 本来就没有进行中的循环，只是把「今天」翻到存档日之后。
        case idle
    }

    mutating func resolveAfterRestoration(at now: Date, calendar: Calendar = .current) -> RestorationOutcome {
        rollDayIfNeeded(at: now, calendar: calendar)
        guard let restoredPhase = phase else { return .idle }

        switch status {
        case .running(let endsAt) where endsAt > now:
            return .running
        case .running:
            // 重启耗时超过了剩余时间。用户既然设了时长，人不在也算这颗番茄熟了。
            if restoredPhase == .focus {
                focusSecondsToday += phaseDuration ?? 0
                focusCountInCycle += 1
            }
            phase = nil
            status = nil
            phaseDuration = nil
            return .expired
        case .paused:
            return .paused
        case .awaitingStart:
            return .awaiting
        case nil:
            return .idle
        }
    }
}
