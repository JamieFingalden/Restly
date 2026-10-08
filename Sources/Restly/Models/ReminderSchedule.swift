import Foundation

/// 一个提醒的下次触发时刻。
///
/// 计时按墙钟算：只记录「这一轮从什么时候开始」和「间隔多长」，不做递减累加。
/// 因此不需要定时轮询，也不会因为进程被系统节流而悄悄丢时间。
struct ReminderSchedule: Equatable {
    /// 本轮计时的起点。
    private(set) var startDate: Date
    /// 本轮的间隔长度。
    private(set) var interval: TimeInterval

    init(startDate: Date, interval: TimeInterval) {
        self.startDate = startDate
        self.interval = max(1, interval)
    }

    /// 下次该提醒的时刻。
    var fireDate: Date {
        startDate.addingTimeInterval(interval)
    }

    func isDue(at date: Date) -> Bool {
        fireDate <= date
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, fireDate.timeIntervalSince(date))
    }

    /// 从头开始新的一轮。
    mutating func restart(at date: Date, interval: TimeInterval? = nil) {
        startDate = date
        if let interval {
            self.interval = max(1, interval)
        }
    }

    /// 只换间隔，保留这一轮已经走过的时间。
    /// 用户改设置时走这条路：把间隔从 45 改到 60，不该把已经攒的 40 分钟扔掉。
    mutating func changeInterval(to interval: TimeInterval) {
        self.interval = max(1, interval)
    }

    /// 把整轮往后推 `duration` 秒，相当于这段时间没有发生过。
    /// 锁屏时间短到不构成一次休息时，用它把冻结的那段补回来。
    mutating func postpone(by duration: TimeInterval) {
        guard duration > 0 else { return }
        startDate = startDate.addingTimeInterval(duration)
    }
}

/// 解锁之后该怎么处理三个计时。
///
/// 规则来自三件事各自问的问题不一样：
/// - 护眼问「连续盯屏多久」，站立问「连续坐了多久」—— 离开一趟这两件事都发生了，该清零。
/// - 喝水问「距离上次喝水多久」—— 离开不代表喝了水，而且身体不管你在不在电脑前，
///   所以它永远不因为锁屏重置，只认「已喝」按钮。
struct LockRecovery: Equatable {
    /// 需要从零开始的提醒。
    let resetTypes: [ReminderType]
    /// 需要补回的冻结时长（不算一次休息时，等于这段时间没发生过）。
    let postpone: TimeInterval

    static func plan(lockedDuration: TimeInterval, threshold: TimeInterval) -> LockRecovery {
        guard lockedDuration >= threshold else {
            // 太短，当作误触或者随手锁一下：什么都不重置，把冻结的时间补回去。
            return LockRecovery(resetTypes: [], postpone: max(0, lockedDuration))
        }
        return LockRecovery(resetTypes: [.eyeRest, .stand], postpone: 0)
    }
}
