import SwiftUI

// MARK: - 相对时间(待办行)

/// 相对时间文本 —— "刚刚 / N 分钟前 / N 小时前 / N 天前 / 具体日期"
/// TimelineView 每 60s 重算一次,由 SwiftUI 管理生命周期,无手动 Timer。
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.format(date, now: context.date))
                .font(DS.Fonts.meta)
                .foregroundStyle(.secondary)
        }
    }

    /// 格式化相对时间(now 由 TimelineView 注入,保证刷新一致)
    static func format(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)

        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        if interval < 604800 { return "\(Int(interval / 86400)) 天前" }

        // 超过 7 天显示具体日期
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
}

// MARK: - 运行时长(运行行)

/// 运行时长文本 —— "m:ss" 秒级实时跳动,超 1 小时切 "h:mm:ss"
/// 秒跳让「正在运行」有活着的感觉,等宽数字避免宽度抖动。
struct ElapsedTimeText: View {
    /// 计时起点(会话启动时间)
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(since: since, now: context.date))
                .font(DS.Fonts.meta)
                .foregroundStyle(.secondary)
        }
    }

    /// 格式化时长
    static func format(since: Date, now: Date = Date()) -> String {
        let total = max(0, Int(now.timeIntervalSince(since)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preview

#Preview("时间文本") {
    VStack(alignment: .leading, spacing: 12) {
        RelativeTimeText(date: Date().addingTimeInterval(-30))
        RelativeTimeText(date: Date().addingTimeInterval(-300))
        RelativeTimeText(date: Date().addingTimeInterval(-7200))
        ElapsedTimeText(since: Date().addingTimeInterval(-154))
        ElapsedTimeText(since: Date().addingTimeInterval(-4000))
    }
    .padding()
}
