import SwiftUI

// MARK: - iOS 15 兼容层
//
// 本文件只服务于「最低系统版本 = 15.0」的构建：
// 项目里有两处 iOS 16 才有的修饰符，包成同一个调用点后，
// 在 iOS 15 上退化成「不生效」（不写一行 if #available 到业务代码里）。
//
// 注意：iOS 16 构建里这些包法也是合法的、行为完全不变，
// 只是 iOS 16 上走的是系统原生分支。

extension View {
    /// iOS 16 的 `scrollContentBackground(.hidden)`。
    /// iOS 15 上列表没有这个开关，退化为原样返回（列表背景沿用系统默认）。
    @ViewBuilder
    func compatHideListBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// iOS 16 的 `presentationDetents([.height(h)])`。
    /// iOS 15 上退化为系统默认的整屏 sheet。
    @ViewBuilder
    func compatSheetHeight(_ height: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.height(height)])
        } else {
            self
        }
    }
}
