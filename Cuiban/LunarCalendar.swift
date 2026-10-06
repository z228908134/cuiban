import SwiftUI

// MARK: - 农历 / 节气 / 节日 / 法定节假日
//
// - 农历：系统自带的中国历（Calendar.chinese），无需第三方库
// - 节气：寿星通用公式（21 世纪），个别年份可能有 ±1 天误差
// - 休/班：内置 2025、2026 年国务院办公厅官方放假安排；
//   2027 年及以后未公布，等官方通知后往表里加即可

enum LunarCalendar {

    // MARK: 对外接口

    /// 日历格子第二行显示的内容
    static func subtitle(for date: Date) -> (text: String, color: Color) {
        if let f = festival(for: date) {
            return (f.name, festivalColor)
        }
        if let t = solarTerm(for: date) {
            return (t, termColor)
        }
        if Calendar.current.component(.weekday, from: date) == 1 {
            return ("\(weekOfYear(of: date))周", termColor)
        }
        let lunar = lunarDayInfo(for: date)
        let text = lunar.dayName == "初一"
            ? ((lunar.isLeap ? "闰" : "") + lunar.monthName)
            : lunar.dayName
        return (text, lunarColor)
    }

    /// "休" / "班" / nil
    static func holidayBadge(for date: Date) -> String? {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let key = y * 10000 + cal.component(.month, from: date) * 100 + cal.component(.day, from: date)
        // 优先用联网更新到的新安排；该年还没数据时退回内置表
        return HolidayService.shared.badge(for: key, year: y)
    }

    /// 这天是不是休息日（含法定调休），供展示用
    static func festival(for date: Date) -> (name: String, isLunar: Bool)? {
        let cal = Calendar.current
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        if let name = solarFestivals[m * 100 + d] {
            return (name, false)
        }
        let lunar = lunarDayInfo(for: date)
        if lunar.dayName == "初一", lunar.monthName == "正月", !lunar.isLeap {
            return ("春节", true)
        }
        if let name = lunarFestivals[lunar.monthIndex * 100 + lunar.dayIndex], !lunar.isLeap {
            return (name, true)
        }
        if isLunarNewYearsEve(date) {
            return ("除夕", true)
        }
        return nil
    }

    // MARK: 颜色

    static let festivalColor = Color(red: 0.95, green: 0.45, blue: 0.15)
    static let termColor = Color(red: 0.20, green: 0.65, blue: 0.35)
    static let lunarColor = Color.secondary
    static let restColor = Color(red: 0.15, green: 0.68, blue: 0.35)
    static let workColor = Color(red: 0.95, green: 0.45, blue: 0.15)

    // MARK: 农历

    private static let lunarCal = Calendar(identifier: .chinese)

    private struct LunarDay {
        var monthIndex: Int   // 1...12
        var dayIndex: Int     // 1...30
        var monthName: String
        var dayName: String
        var isLeap: Bool
    }

    private static func lunarDayInfo(for date: Date) -> LunarDay {
        let comps = lunarCal.dateComponents([.era, .year, .month, .day], from: date)
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        let monthNames = ["正月", "二月", "三月", "四月", "五月", "六月",
                          "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let dayNames = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
        return LunarDay(
            monthIndex: (1...12).contains(m) ? m : 1,
            dayIndex: (1...30).contains(d) ? d : 1,
            monthName: (1...12).contains(m) ? monthNames[m - 1] : "",
            dayName: (1...30).contains(d) ? dayNames[d - 1] : "",
            isLeap: comps.isLeapMonth ?? false
        )
    }

    private static func isLunarNewYearsEve(_ date: Date) -> Bool {
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return false }
        let comps = lunarCal.dateComponents([.month, .day], from: next)
        return comps.month == 1 && comps.day == 1 && !(comps.isLeapMonth ?? false)
    }

    // MARK: 节气（寿星公式，21 世纪）

    private static let termConstants: [(month: Int, name: String, c: Double)] = [
        (1, "小寒", 5.4055), (1, "大寒", 20.12),
        (2, "立春", 3.87), (2, "雨水", 18.73),
        (3, "惊蛰", 5.63), (3, "春分", 20.646),
        (4, "清明", 4.81), (4, "谷雨", 20.1),
        (5, "立夏", 5.52), (5, "小满", 21.04),
        (6, "芒种", 5.678), (6, "夏至", 21.37),
        (7, "小暑", 7.108), (7, "大暑", 22.83),
        (8, "立秋", 7.5), (8, "处暑", 23.13),
        (9, "白露", 7.646), (9, "秋分", 23.042),
        (10, "寒露", 8.318), (10, "霜降", 23.438),
        (11, "立冬", 7.438), (11, "小雪", 22.36),
        (12, "大雪", 7.18), (12, "冬至", 21.94)
    ]

    static func solarTerm(for date: Date) -> String? {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        guard (2001...2099).contains(y) else { return nil }
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        let yy = Double(y % 100)
        let leapCount = (y % 100) / 4
        for t in termConstants where t.month == m {
            let day = Int(yy * 0.2422 + t.c) - leapCount
            if d == day { return t.name }
        }
        return nil
    }

    // MARK: 节日

    private static let solarFestivals: [Int: String] = [
        101: "元旦", 214: "情人节", 308: "妇女节", 312: "植树节",
        501: "劳动节", 504: "青年节", 601: "儿童节", 701: "建党节",
        801: "建军节", 910: "教师节", 1001: "国庆节", 1031: "万圣夜",
        1224: "平安夜", 1225: "圣诞节"
    ]

    private static let lunarFestivals: [Int: String] = [
        115: "元宵节", 202: "龙抬头", 505: "端午节", 707: "七夕",
        715: "中元节", 815: "中秋节", 909: "重阳节", 1208: "腊八节"
    ]

    private static func weekOfYear(of date: Date) -> Int {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2
        return cal.component(.weekOfYear, from: date)
    }

    // MARK: 法定节假日（国务院办公厅官方安排）

    /// (年, 起月, 起日, 止月, 止日) —— 放假
    private static let holidayRanges: [(Int, Int, Int, Int, Int)] = [
        // 2025 年
        (2025, 1, 1, 1, 1),        // 元旦
        (2025, 1, 28, 2, 4),       // 春节
        (2025, 4, 4, 4, 6),        // 清明
        (2025, 5, 1, 5, 5),        // 劳动节
        (2025, 5, 31, 6, 2),       // 端午
        (2025, 10, 1, 10, 8),      // 国庆·中秋
        // 2026 年（国办发明电〔2025〕7号）
        (2026, 1, 1, 1, 3),        // 元旦
        (2026, 2, 15, 2, 23),      // 春节
        (2026, 4, 4, 4, 6),        // 清明
        (2026, 5, 1, 5, 5),        // 劳动节
        (2026, 6, 19, 6, 21),      // 端午
        (2026, 9, 25, 9, 27),      // 中秋
        (2026, 10, 1, 10, 7)       // 国庆
    ]

    /// 调休上班的周末
    private static let workdayRanges: [(Int, Int, Int, Int, Int)] = [
        (2025, 1, 26, 1, 26),
        (2025, 2, 8, 2, 8),
        (2025, 4, 27, 4, 27),
        (2025, 9, 28, 9, 28),
        (2025, 10, 11, 10, 11),
        (2026, 1, 4, 1, 4),
        (2026, 2, 14, 2, 14),
        (2026, 2, 28, 2, 28),
        (2026, 5, 9, 5, 9),
        (2026, 9, 20, 9, 20),
        (2026, 10, 10, 10, 10)
    ]

    private static let restSet: Set<Int> = expand(holidayRanges)
    private static let workSet: Set<Int> = expand(workdayRanges)

    private static func expand(_ ranges: [(Int, Int, Int, Int, Int)]) -> Set<Int> {
        let cal = Calendar(identifier: .gregorian)
        var s = Set<Int>()
        for (y, m1, d1, m2, d2) in ranges {
            guard var date = cal.date(from: DateComponents(year: y, month: m1, day: d1)),
                  let end = cal.date(from: DateComponents(year: y, month: m2, day: d2)) else { continue }
            while date <= end {
                let c = cal.dateComponents([.year, .month, .day], from: date)
                if let yy = c.year, let mm = c.month, let dd = c.day {
                    s.insert(yy * 10000 + mm * 100 + dd)
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: date) else { break }
                date = next
            }
        }
        return s
    }
}

// MARK: - 法定节假日自动更新
//
// 内置表只有已公布的年份；以后每年的新安排会由这里自动拉取：
//   - App 启动时检查当年（9 月起再预取下一年）有没有新数据；
//   - 没有就从公共节假日接口拉一份，缓存到本机文档目录；
//   - 拉不到（没网/接口挂了）就继续用内置表，不影响使用。
final class HolidayService: ObservableObject {
    static let shared = HolidayService()

    struct YearData: Codable {
        var rest: [Int]  // 放假日 (yyyyMMdd)
        var work: [Int]  // 调休上班日 (yyyyMMdd)
    }

    /// 远端拉到的数据：年 -> 休/班
    @Published private(set) var remote: [Int: YearData] = [:]

    private init() { loadCaches() }

    /// 查某天的 休/班；该年有远端数据就用远端，否则用内置表
    func badge(for key: Int, year: Int) -> String? {
        if let d = remote[year] {
            if d.work.contains(key) { return "班" }
            if d.rest.contains(key) { return "休" }
            return nil
        }
        if LunarCalendar.workSet.contains(key) { return "班" }
        if LunarCalendar.restSet.contains(key) { return "休" }
        return nil
    }

    /// App 启动时调用
    func refreshIfNeeded() {
        let cal = Calendar.current
        let now = Date()
        let thisYear = cal.component(.year, from: now)
        var years = [thisYear]
        if cal.component(.month, from: now) >= 9 {
            years.append(thisYear + 1)  // 下一年安排通常 10~11 月公布，提前备好
        }
        for y in years where remote[y] == nil {
            fetch(year: y)
        }
    }

    private func fetch(year: Int) {
        guard let url = URL(string: "https://timor.tech/api/holiday/year/\(year)") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self = self,
                  error == nil,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let decoded = try? JSONDecoder().decode(HolidayAPIResponse.self, from: data),
                  decoded.code == 0,
                  let days = decoded.holiday, !days.isEmpty else { return }

            var rest: [Int] = []
            var work: [Int] = []
            for (k, info) in days {
                let parts = k.split(separator: "-")
                guard parts.count == 2,
                      let mm = Int(parts[0]), let dd = Int(parts[1]),
                      (1...12).contains(mm), (1...31).contains(dd) else { continue }
                let key = year * 10000 + mm * 100 + dd
                if info.holiday { rest.append(key) } else { work.append(key) }
            }
            guard !rest.isEmpty || !work.isEmpty else { return }
            let yearData = YearData(rest: rest.sorted(), work: work.sorted())

            DispatchQueue.main.async {
                self.remote[year] = yearData
                self.saveCache(year: year, data: yearData)
            }
        }.resume()
    }

    private struct HolidayAPIResponse: Decodable {
        let code: Int
        let holiday: [String: DayInfo]?
    }
    private struct DayInfo: Decodable {
        let holiday: Bool
    }

    // MARK: 本机缓存

    private var cacheDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func loadCaches() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("holiday_") && f.pathExtension == "json" {
            let name = f.deletingPathExtension().lastPathComponent
            guard let y = Int(name.replacingOccurrences(of: "holiday_", with: "")), y > 2000,
                  let d = try? Data(contentsOf: f),
                  let yd = try? JSONDecoder().decode(YearData.self, from: d) else { continue }
            remote[y] = yd
        }
    }

    private func saveCache(year: Int, data: YearData) {
        if let d = try? JSONEncoder().encode(data) {
            try? d.write(to: cacheDir.appendingPathComponent("holiday_\(year).json"))
        }
    }
}
