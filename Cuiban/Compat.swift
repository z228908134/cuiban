import SwiftUI

// MARK: - iOS 15 兼容层（只为「单独出 iOS 15 包」而存在）
//
// 正常版的 deployment target 是 16.0，这个文件平时**不在** develop 分支上；
// 只有临时把最低版本降到 15.0 出包时才会加进来，并把下面这几处调用点改成走兼容写法。
// 原则：iOS 16+ 上走系统原生分支，行为与原来完全一致；iOS 15 上退化成最接近的效果。
//
// 为什么不能只写 `if #available` 就地包：调用点散在 View 的链式修饰符里，
// 就地包会打断链（拿不到 `some View` 的类型推断），收成方法最省事。

extension View {

    /// ≈ iOS 16 的 `scrollContentBackground(.hidden)`。
    /// iOS 15 上这个开关不存在，退化为原样 —— 列表背景走系统默认色。
    @ViewBuilder
    func compatHideListBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// ≈ iOS 16 的 `presentationDetents([.height(h)])`。
    /// iOS 15 上没有半屏 sheet，退化为系统默认的整屏 sheet。
    @ViewBuilder
    func compatSheetHeight(_ height: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.height(height)])
        } else {
            self
        }
    }
}

/// ≈ iOS 16 的多行输入框：`TextField(..., axis: .vertical) + lineLimit(1...4)`。
/// iOS 15 上退化为单行输入框（内容照样能存，只是不会自动长高）。
///
/// 写成**全局函数**而不是 View 的扩展方法：调用点是表单里直接摆一个输入框，
/// 前面没有接收者，扩展方法写不出来（`x.compatMultilineField()` 才行）。
@ViewBuilder
func compatMultilineField(_ title: String, text: Binding<String>) -> some View {
    if #available(iOS 16.0, *) {
        TextField(title, text: text, axis: .vertical)
            .lineLimit(1...4)
    } else {
        TextField(title, text: text)
    }
}

extension Text {

    /// 按需套上 斜体 / 下划线 / 删除线：**必须在 `Text` 上逐个调无参重载**。
    ///
    /// 带 `Bool` 的 `.italic(_:)` / `.underline(_:)` / `.strikethrough(_:)` 只有
    /// iOS 16 的 **View** 版本；`Text` 这边只有无参的（iOS 13+）。
    /// 直接照原样写（`.italic(italic)`）在 iOS 15 上会编译失败 ——
    /// Text 没有这个重载，落到 View 版又被 #available 挡住。
    func traitStyled(italic: Bool, underline: Bool, strike: Bool) -> Text {
        var t = self
        if italic { t = t.italic() }
        if underline { t = t.underline() }
        if strike { t = t.strikethrough() }
        return t
    }
}
