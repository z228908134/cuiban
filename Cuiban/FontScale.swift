import SwiftUI
import UIKit

// MARK: - 全局字号

/// 全局字体大小调节。
/// 全项目所有字体都走 `.font(.app(13))` / `UIFont.app(16)`，乘上这里的系数，
/// 所以设置里改一次，整个 App（清单、日历、笔记、卡片、编辑器）立刻跟着变大变小。
///
/// 为什么不用系统的动态字体：动态字体只对 `.body` 这类语义字体生效，
/// 而本 App 为了对齐滴答清单的样式大量用了固定字号，那些地方动态字体管不到。
final class FontScale: ObservableObject {
    static let shared = FontScale()
    /// 变化通知：根视图收到后强制重建整棵视图树，保证所有页面立刻生效
    static let didChange = Notification.Name("cuiban.fontScaleDidChange")
    /// 字号调整结束（「外观与字体」页退出了）：根视图收到后把推迟的那次重建补上
    static let editEnded = Notification.Name("cuiban.fontScaleEditEnded")

    /// 正在调字号的页面数（「外观与字体」页存在时 > 0）。
    ///
    /// 为什么要有这个「暂停期」：根视图是靠换 `TabView` 的身份（`.id(fontRev)`）
    /// 来让全 App 重算字体的，而换身份会把整棵视图树（含每个页面的 NavigationView）
    /// 一起重建 —— 此时正推在栈上的「外观与字体」页会被弹回设置首页，
    /// 用户看到的就是「调完字号自己闪回上一页」。
    /// 所以调整期间只记下「待重建」，等退出这一页再补上。这一页自己会实时刷新
    /// （它 @ObservedObject 了 FontScale），预览照样看得见。
    private(set) var editingDepth = 0

    func beginEditing() { editingDepth += 1 }

    func endEditing() {
        guard editingDepth > 0 else { return }
        editingDepth -= 1
        guard editingDepth == 0 else { return }
        NotificationCenter.default.post(name: FontScale.editEnded, object: nil)
    }

    /// 可选范围 80% ~ 160%
    static let range: ClosedRange<Double> = 0.8...1.6
    /// 预设档位
    static let presets: [(label: String, value: Double)] = [
        ("小", 0.88),
        ("标准", 1.0),
        ("大", 1.15),
        ("特大", 1.32)
    ]

    private static let defaultsKey = "cuiban.fontScale"

    /// 当前系数。字体构造时直接读这个静态值（不需要 Environment）。
    /// 必须兜底 1.0：UserDefaults 里第一次没有这个键时 double() 返回 0，
    /// 一旦漏出去，所有字号都会变成 0（界面全空、方框附件成 0×0 空图）。
    static var current: CGFloat {
        let v = UserDefaults.standard.double(forKey: defaultsKey)
        return CGFloat(v == 0 ? 1.0 : v)
    }

    @Published var value: Double {
        didSet {
            let v = min(max(value, FontScale.range.lowerBound), FontScale.range.upperBound)
            if v != value {
                value = v
                return
            }
            UserDefaults.standard.set(v, forKey: FontScale.defaultsKey)
            NotificationCenter.default.post(name: FontScale.didChange, object: nil)
        }
    }

    private init() {
        let v = UserDefaults.standard.double(forKey: FontScale.defaultsKey)
        let start = v == 0 ? 1.0 : v
        value = start
        // init 里的赋值不会触发 didSet，这里手动落盘，保证下次启动读得到
        UserDefaults.standard.set(start, forKey: FontScale.defaultsKey)
    }

    /// 当前落在哪一档（用于设置页高亮）
    var currentPresetLabel: String {
        let best = FontScale.presets.min { abs($0.value - value) < abs($1.value - value) }
        return best?.label ?? "自定义"
    }

    var percentText: String {
        "\(Int((value * 100).rounded()))%"
    }
}

// MARK: - 整树重建的调度

/// 字号变化 → 全 App 重建的调度器（根视图订阅它，拿 `rev` 当 TabView 的 id）。
///
/// 放在类里而不是根视图的 `@State`，是为了能在延迟回调里安全改状态，
/// 也把「什么时候该重建」的判断收在一处。
/// 延迟的原因见 `FontScale.editingDepth`：字号只能在「外观与字体」二级页里改，
/// 而重建会重置导航栈 —— 立刻重建就等于把这一页弹回设置首页。
final class FontRebuilder: ObservableObject {
    static let shared = FontRebuilder()

    /// 重建计数：一变，根视图的 TabView 就换身份 → 所有页面（含 UIKit 编辑器）重算字体
    @Published private(set) var rev = 0

    /// 有「待补的重建」还没做
    private var pending = false
    /// 已排队一次延迟重建，别重复排
    private var scheduled = false

    private init() {}

    /// 字号刚变
    func fontChanged() {
        if FontScale.shared.editingDepth > 0 {
            pending = true
        } else {
            rev &+= 1
        }
    }

    /// 「外观与字体」页退出了：把推迟的重建补上
    func editingEnded() {
        guard pending, !scheduled else { return }
        scheduled = true
        // 等返回动画走完再重建：半路换掉整棵树会把返回动画打断，看着很跳
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self else { return }
            self.scheduled = false
            // 这半秒里又点回了「外观与字体」：继续挂着，等下次退出再补
            guard FontScale.shared.editingDepth == 0 else { return }
            self.pending = false
            self.rev &+= 1
        }
    }
}

// MARK: - 字体扩展

extension Font {
    /// 跟随全局字号：.app(15) 等价于 .system(size: 15)，但会乘上用户的字号系数
    static func app(_ size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> Font {
        .system(size: size * FontScale.current, weight: weight, design: design)
    }
}

extension UIFont {
    /// UIKit 侧（UITextView 编辑器等）跟随全局字号
    static func app(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size * FontScale.current, weight: weight)
    }
}
