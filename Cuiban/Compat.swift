import SwiftUI
import UIKit

// MARK: - iOS 15 兼容层
//
// 这个 App 原来最低 iOS 16，为了照顾还停在 iOS 15 的设备（也为了能在只跑 15 的
// 越狱机上装），把用到的 iOS 16 API 全部收到这一处：能用新 API 就用新 API，
// 没有就退到 iOS 15 能做到的等价实现。
//
// 为什么不直接把调用点改成老写法：iOS 16/17 上那些新 API 的观感更好
// （比如 `presentationDetents` 的半高 sheet、`TextField(axis:)` 的自动长高），
// 留一层 `if #available` 两边都不吃亏。

enum Compat {
    /// 只存在于 SF Symbols 4（iOS 16）里的图标，在 iOS 15 上会渲染成**空白**，
    /// 这里降级成同样含义的旧图标。
    static func symbol(_ name: String, fallback: String) -> String {
        if #available(iOS 16.0, *) { return name }
        return fallback
    }
}

// MARK: - 列表背景

extension View {
    /// 隐藏 List / Form 自带的滚动背景，等价于 iOS 16 的 `scrollContentBackground(.hidden)`。
    ///
    /// iOS 15 没有这个修饰符，退化成把底下的 `UITableView` 背景刷成透明。
    /// 只处理当前这棵视图所在的那一张表，**不动全局外观**
    /// （`UITableView.appearance()` 是进程级设置，会把别处依赖默认背景的列表一起改掉）。
    @ViewBuilder
    func hideScrollContentBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self.background(ListBackdropCleaner())
        }
    }

    /// 半高 sheet，等价于 iOS 16 的 `presentationDetents([.height(...)])`。
    ///
    /// iOS 15 没有 detents：保持系统默认的整页 sheet —— 功能一样，只是要占满屏。
    @ViewBuilder
    func sheetHeight(_ height: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.height(height)])
        } else {
            self
        }
    }
}

/// 把所在 List 的 `UITableView` 背景刷透明。只在 iOS 15 分支挂载。
private struct ListBackdropCleaner: UIViewRepresentable {
    func makeUIView(context: Context) -> CleanerView { CleanerView() }

    func updateUIView(_ uiView: CleanerView, context: Context) {
        uiView.clean()
    }

    final class CleanerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            clean()
            // 装配顺序不一定：列表本体可能下一帧才挂好，补一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.clean()
            }
        }

        /// 从自己往上爬几层，找装着 UITableView 的那层容器。
        /// 限深度是防止误伤页面上别的列表（比如同一屏里的第二个 List）。
        func clean() {
            var node: UIView? = superview
            for _ in 0..<6 {
                guard let cur = node else { return }
                if let tv = cur as? UITableView {
                    tv.backgroundColor = .clear
                    tv.backgroundView = nil
                    return
                }
                if let tv = cur.firstTableView(within: 3) {
                    tv.backgroundColor = .clear
                    tv.backgroundView = nil
                    return
                }
                node = cur.superview
            }
        }
    }
}

private extension UIView {
    func firstTableView(within depth: Int) -> UITableView? {
        guard depth > 0 else { return nil }
        for sub in subviews {
            if let tv = sub as? UITableView { return tv }
            if let tv = sub.firstTableView(within: depth - 1) { return tv }
        }
        return nil
    }
}

// MARK: - 多行输入

/// 多行输入框。
///
/// iOS 16 用 `TextField(axis: .vertical)`：会自动长高，最多 `maxLines` 行。
/// iOS 15 没有这个重载，退回 `TextEditor` —— 高度写死成 `maxLines` 行，前面叠一个占位符。
struct MultilineTextField: View {
    let placeholder: String
    @Binding var text: String
    var minLines: Int = 1
    var maxLines: Int = 4

    var body: some View {
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(minLines...maxLines)
        } else {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    // TextEditor 自己没有 placeholder，拿一个不接手势的 Text 顶上
                    Text(placeholder)
                        .font(.app(17))
                        .foregroundColor(Color(UIColor.placeholderText))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.app(17))
                    .frame(height: 22 * CGFloat(maxLines) + 8)
            }
        }
    }
}
