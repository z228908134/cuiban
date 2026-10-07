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

    /// 当前系数。字体构造时直接读这个静态值（不需要 Environment）
    static var current: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: defaultsKey))
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
        value = v == 0 ? 1.0 : v
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
