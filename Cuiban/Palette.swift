import SwiftUI

/// 全局共享色板：以前散落在清单 / 日历 / 笔记 / 卡片各页面的硬编码
/// Color(red:...) 收到这里，改主题色只动这一个文件。
/// 需要区分深浅色的（如笔记卡片底色）仍留在各自页面，用 dyn(light, dark)。
enum Palette {
    /// 左滑删除红（清单 / 日历 / 笔记 / 卡片通用）
    static let deleteRed = Color(red: 0.90, green: 0.23, blue: 0.22)
    /// 左滑编辑 / 主操作蓝
    static let actionBlue = Color(red: 0.19, green: 0.47, blue: 0.96)
    /// 链接蓝（充值卡明细、跳转文字）
    static let linkBlue = Color(red: 0.0, green: 0.48, blue: 1.0)
    /// 已抢到青绿：既不刺眼又能一眼看出「这条已经拿下了」
    static let hitGreen = Color(red: 0.05, green: 0.43, blue: 0.34)
    /// 左滑「抢到」按钮的青绿：比 hitGreen 略亮，在滑块底色上更醒目
    static let grabGreen = Color(red: 0.05, green: 0.53, blue: 0.42)
    /// 左滑延后橙
    static let snoozeOrange = Color(red: 0.98, green: 0.58, blue: 0.00)
    /// 左滑「撤销」灰（把已抢到退回去）
    static let undoGray = Color(red: 0.42, green: 0.44, blue: 0.47)
    /// 利润 / 亏损红（优惠券、充值卡共用）
    static let profitRed = Color(red: 0.85, green: 0.20, blue: 0.16)
}
