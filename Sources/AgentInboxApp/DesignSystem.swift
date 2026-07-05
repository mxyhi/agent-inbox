import AppKit
import SwiftUI

/// V4 设计系统 —— 单文件集中定义色彩/字体/间距/动画
/// 设计语言:系统原生材质 + 单色 vibrancy 文本,彩色只出现在状态光点与完成按钮上;
/// 状态不用文字标签,由光点动效表达(运行=呼吸、待办=涟漪)。
enum DS {
    // MARK: - 色彩

    enum Colors {
        /// 运行中 —— 系统蓝(跟随明暗模式)
        static let running = Color.blue
        /// 待办 —— 系统橙
        static let todo = Color.orange
        /// 完成 —— 系统绿
        static let done = Color.green
        /// 空闲点 —— 弱化的次要色
        static let idle = Color.secondary.opacity(0.45)
        /// 行 hover 高亮(极淡的前景色填充)
        static let rowHover = Color.primary.opacity(0.06)
        /// 完成按钮默认底色
        static let buttonIdle = Color.primary.opacity(0.08)
        /// 面板发丝描边(系统分隔线色,明暗自适应)
        static let hairline = Color(nsColor: .separatorColor)
    }

    // MARK: - 字体

    enum Fonts {
        /// 行标题(项目名)—— 13pt Semibold
        static let rowTitle = Font.system(size: 13, weight: .semibold)
        /// 消息摘要 —— 12pt Regular
        static let message = Font.system(size: 12)
        /// 时间/时长等元信息 —— 11pt,等宽数字防抖动
        static let meta = Font.system(size: 11).monospacedDigit()
        /// 空态胶囊文字 —— 12pt Medium
        static let capsule = Font.system(size: 12, weight: .medium)
        /// 折叠提示(还有 N 个)—— 11pt
        static let overflow = Font.system(size: 11)
    }

    // MARK: - 间距与圆角

    enum Metrics {
        /// 面板内容宽度(列表态固定宽,空态胶囊自适应)
        static let listWidth: CGFloat = 300
        /// 面板外圆角
        static let panelRadius: CGFloat = 16
        /// 行圆角(hover 高亮)
        static let rowRadius: CGFloat = 7
        /// 面板内边距
        static let panelPadding: CGFloat = 8
        /// 行内边距
        static let rowPaddingV: CGFloat = 6
        static let rowPaddingH: CGFloat = 8
        /// 行内元素间距
        static let rowSpacing: CGFloat = 8
        /// 状态光点直径
        static let orbSize: CGFloat = 8
        /// 光点占位框(容纳涟漪扩散)
        static let orbFrame: CGFloat = 14
        /// 完成按钮直径
        static let completeButtonSize: CGFloat = 22
        /// 屏幕边缘默认留白
        static let screenMargin: CGFloat = 16
    }

    // MARK: - 动画

    enum Anim {
        /// 快照/布局变化 —— 弹簧,胶囊⇄列表收放的主动画
        static let state = Animation.spring(response: 0.35, dampingFraction: 0.8)
        /// hover 反馈
        static let hover = Animation.easeOut(duration: 0.12)
        /// 运行光点单相呼吸时长(完整周期 = 2 倍)
        static let breathPhase: TimeInterval = 0.9
        /// 待办涟漪:扩散时长 + 静止间歇
        static let rippleExpand: TimeInterval = 1.1
        static let rippleRest: TimeInterval = 1.4
    }
}
