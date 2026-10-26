import SwiftUI
import UIKit

/// 可下拉唤出的搜索条。
///
/// 为什么不用系统的 `.searchable`：iOS 16 的 drawer 式搜索框在列表顶部是**默认可见**的
/// （只有往下滚过一屏才会收起来），内容不满一屏时更是常驻。用户要的是「平时看不见，
/// 下拉才出来」，系统这套做不到，只能自己做：
///   · 用 KVO 读底层 UIScrollView 的 contentOffset（只读，不抢手势，不影响滑动和左滑菜单）；
///   · 下拉超过阈值 → 把搜索条插到列表上方；内容往上滚过一截 → 收回。
final class PullReveal: ObservableObject {
    /// 搜索条是否展开
    @Published private(set) var shown = false
    /// 输入中锁住：边打字边滚结果时不要把它收走
    var locked = false

    private var obs: NSKeyValueObservation?
    private weak var scroll: UIScrollView?

    /// 由行内的 ScrollProbe 调用，绑定所在列表的滚动视图
    func attach(_ s: UIScrollView) {
        guard scroll !== s else { return }
        scroll = s
        // 内容不满一屏时列表默认拉不动，就没有「下拉」这个动作可用。
        // 这里直接打开回弹（iOS 16.0 也支持，不依赖 16.4 的 scrollBounceBehavior）。
        if !s.alwaysBounceVertical { s.alwaysBounceVertical = true }
        // 不用 .initial：attach 发生在 cell 装配里，那时同步改状态会撞上视图更新。
        // 静止时本来就没什么要做的，等真滚动起来再看即可。
        obs = s.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
            self?.handle(sv)
        }
    }

    private func handle(_ sv: UIScrollView) {
        // KVO 的 contentOffset 回调在滚动时只在主线程触发
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handle(sv) }
            return
        }
        // y == 0：正好停在顶部
        // y < 0 ：手指往下拉出去的距离
        // y > 0 ：内容已经往上滚过的距离
        let y = sv.contentOffset.y + sv.adjustedContentInset.top

        if !shown {
            if y < -24 { set(true) }
        } else if !locked, y > 40, sv.isDragging || sv.isDecelerating {
            // 只认「用户真的在滚」——搜索条插进来时列表变矮，系统偶尔会顺手调一下
            // contentOffset，那种被动变化不能当成用户在滚，否则会来回抽搐。
            set(false)
        }
    }

    func hide() {
        locked = false
        set(false)
    }

    private func set(_ v: Bool) {
        guard shown != v else { return }
        // 列表尺寸变化后 SwiftUI 可能把回弹设置改回去，这里顺手补一次
        if let s = scroll, !s.alwaysBounceVertical { s.alwaysBounceVertical = true }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { shown = v }
    }
}

/// 塞在列表行背景里的探针：顺着 superview 找到所在列表的 UIScrollView，交给 PullReveal。
/// 只读 offset，不加手势，所以不会和列表滑动、左滑菜单打架。
struct ScrollProbe: UIViewRepresentable {
    let reveal: PullReveal

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.reveal = reveal
        return v
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.reveal = reveal
        uiView.reassertBounce()
    }

    final class ProbeView: UIView {
        weak var reveal: PullReveal?
        private weak var attached: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            if !tryAttach() {
                // 极少数情况下装配顺序还没到 cell 那一层，下一帧再试一次
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    _ = self?.tryAttach()
                }
            }
        }

        @discardableResult
        func tryAttach() -> Bool {
            var v: UIView? = superview
            while let cur = v {
                if let s = cur as? UIScrollView {
                    if attached !== s {
                        attached = s
                        reveal?.attach(s)
                    }
                    reassertBounce()
                    return true
                }
                v = cur.superview
            }
            return false
        }

        /// 内容不满一屏也要能下拉，否则「下拉出搜索框」没有行程
        func reassertBounce() {
            if let s = attached, !s.alwaysBounceVertical {
                s.alwaysBounceVertical = true
            }
        }
    }
}

/// 下拉才出现的搜索条。视觉上照着系统 drawer 做：圆角灰底输入框 + 右侧「取消」。
struct PullSearchBar: View {
    @Binding var query: String
    var prompt: String
    var onFocusChange: (Bool) -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.app(14))
                    .foregroundColor(.secondary)

                TextField(prompt, text: $query)
                    .font(.app(16))
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.app(15))
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(UIColor.tertiarySystemFill))
            )

            Button("取消") {
                focused = false
                query = ""
                onCancel()
            }
            .font(.app(16))
            .foregroundColor(Palette.actionBlue)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color(UIColor.systemGroupedBackground))
        .onChange(of: focused) { f in
            onFocusChange(f)
        }
    }
}
