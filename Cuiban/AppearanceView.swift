import SwiftUI

// MARK: - 外观与字体（二级页）

/// 设置里「外观与字体」的二级页：主题 + 全局字号。
/// 单独拆出来是因为这两项 infrequently 调，放在设置首页会把其它设置挤下去。
struct AppearanceSettingsView: View {
    @EnvironmentObject var store: TaskStore
    @ObservedObject private var fontScale = FontScale.shared

    var body: some View {
        Form {
            // MARK: 主题

            Section(header: Text("外观"),
                    footer: Text("深色模式下所有页面都会跟着变暗；催促页固定红底白字，不受影响。")) {
                Picker("主题", selection: themeBinding) {
                    ForEach(ThemeMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            // MARK: 字号

            Section(header: Text("字体大小"),
                    footer: Text("整个 App 的字都会跟着一起变大变小，包括清单、日历、笔记、卡片和优惠券。")) {
                // 四档预设
                HStack(spacing: 8) {
                    ForEach(FontScale.presets, id: \.value) { p in
                        let active = abs(fontScale.value - p.value) < 0.02
                        Button {
                            setFontScale(p.value)
                        } label: {
                            Text(p.label)
                                .font(.app(14, weight: active ? .semibold : .regular))
                                .foregroundColor(active ? .white : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(active ? brandColor : Color.primary.opacity(0.07))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)

                // 连续调节
                HStack(spacing: 10) {
                    Text("A")
                        .font(.app(12))
                        .foregroundColor(.secondary)
                    Slider(value: Binding(
                        get: { fontScale.value },
                        set: { setFontScale($0) }
                    ),
                           in: FontScale.range,
                           step: 0.02)
                        .tint(brandColor)
                    Text("A")
                        .font(.app(19, weight: .semibold))
                }

                HStack {
                    Text("当前：\(fontScale.currentPresetLabel) · \(fontScale.percentText)")
                        .font(.app(12))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                // 实时预览（清单行 + 待办行）
                VStack(alignment: .leading, spacing: 8) {
                    Text("预览")
                        .font(.app(11))
                        .foregroundColor(.secondary)
                    HStack(spacing: 9) {
                        Image(systemName: "circle")
                            .font(.app(20))
                            .foregroundColor(brandColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("明天下午 3 点开会")
                                .font(.app(16, weight: .semibold))
                            Text("还有 4 小时 · 重复：工作日")
                                .font(.app(12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    HStack(spacing: 9) {
                        // 和笔记里一致：方框字符用大字号
                        Text(TextEditBridge.uncheckedMarkRaw)
                            .font(.app(22))
                        Text("库房盘点")
                            .font(.app(15))
                        Spacer()
                    }
                    HStack(spacing: 9) {
                        Text(TextEditBridge.checkedMarkRaw)
                            .font(.app(24))
                            .foregroundColor(.secondary)
                        Text("买牛奶")
                            .font(.app(15))
                            .strikethrough()
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    HStack(spacing: 9) {
                        Image(systemName: "ticket")
                            .font(.app(18))
                            .foregroundColor(brandColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("星巴克中杯券")
                                .font(.app(15, weight: .semibold))
                            Text("面额 ¥35 · 还剩 3 天过期")
                                .font(.app(12))
                                .foregroundColor(.orange)
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("外观与字体")
        .navigationBarTitleDisplayMode(.inline)
        // 这一页开着的时候，根视图推迟「整树重建」——否则换 TabView 身份会
        // 把正推在栈上的本页弹回设置首页（调完字号自己闪回上一页）。
        // 本页自己 @ObservedObject 了 FontScale，预览是实时变的；退出时再补重建。
        .onAppear { fontScale.beginEditing() }
        .onDisappear { fontScale.endEditing() }
    }

    private func setFontScale(_ v: Double) {
        fontScale.value = v
        var s = store.settings
        s.fontScale = fontScale.value
        store.updateSettingsPublic(s)
    }

    private var themeBinding: Binding<ThemeMode> {
        Binding(
            get: { store.settings.theme },
            set: { v in
                var s = store.settings
                s.theme = v
                store.updateSettingsPublic(s)
            }
        )
    }
}
