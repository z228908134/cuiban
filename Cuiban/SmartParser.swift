import Foundation
import UIKit
import Vision

// MARK: - 识别结果

struct SmartParseResult {
    /// 识别出的提醒时间
    var dueDate: Date? = nil
    /// 识别出的重复规则
    var repeatMode: RepeatMode? = nil
    /// 每周几（Calendar 口径：1=周日 ... 7=周六）
    var weekdays: [Int] = []
    /// 每月几号
    var monthDay: Int? = nil
    /// 给用户的提示（例如规则做了近似处理）
    var tips: [String] = []
    /// OCR 原文 / 用户输入的原文
    var rawLines: [String] = []
    /// 建议的标题
    var titleSuggestion: String? = nil
    /// 出错信息
    var errorText: String? = nil
    /// 结果来源，用于写进备注
    var sourceLabel: String = "图片"

    var foundTimeOrRule: Bool {
        if dueDate != nil { return true }
        if let m = repeatMode, m != .none { return true }
        return false
    }

    /// 界面上的一行摘要
    func summaryText(now: Date = Date()) -> String {
        if let e = errorText { return e }
        if !foundTimeOrRule { return "没识别到时间或重复规则，已把原文写进备注" }
        var parts: [String] = []
        if let d = dueDate {
            parts.append("\(fmt(d, "M月d日 EEE HH:mm"))（\(relativeLabel(d, now: now))）")
        } else {
            parts.append("时间未识别到")
        }
        if let m = repeatMode, m != .none {
            parts.append(repeatLabel(m, weekdays: weekdays))
        }
        return "识别到：" + parts.joined(separator: " · ")
    }

    /// 写进备注的文本块
    func noteBlock(now: Date = Date()) -> String {
        var out: [String] = []
        out.append("【识别结果 · \(sourceLabel) · \(fmt(now, "MM-dd HH:mm"))】")
        if let d = dueDate {
            out.append("时间：\(fmt(d, "M月d日 EEE HH:mm"))（\(relativeLabel(d, now: now))）")
        } else {
            out.append("时间：没识别到，请手动确认")
        }
        if let m = repeatMode, m != .none {
            out.append("重复：\(repeatLabel(m, weekdays: weekdays))")
        } else {
            out.append("重复：无")
        }
        for t in tips { out.append("提示：" + t) }
        if !rawLines.isEmpty {
            out.append("原文：" + rawLines.prefix(8).joined(separator: " ／ "))
        }
        return out.joined(separator: "\n")
    }
}

/// 备注里识别块的起始标记，重新识别时用它把旧块替换掉
let parseBlockMarker = "【识别结果"

// MARK: - 解析引擎

enum SmartParser {

    private struct Match {
        let groups: [String]
        let range: NSRange
    }

    // MARK: OCR

    /// 单张图（保留旧入口）
    static func recognize(image: UIImage, completion: @escaping (SmartParseResult) -> Void) {
        recognize(images: [image], completion: completion)
    }

    /// 多张图：把每张的文字合起来一起解析，信息越全越准
    static func recognize(images: [UIImage], completion: @escaping (SmartParseResult) -> Void) {
        guard !images.isEmpty else {
            var r = SmartParseResult()
            r.sourceLabel = "图片"
            r.errorText = "还没有选图片"
            DispatchQueue.main.async { completion(r) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var failure: String? = nil

            for img in images {
                let one = ocrLines(img)
                lines.append(contentsOf: one.lines)
                if let e = one.error, failure == nil { failure = e }
            }

            var out = parse(lines: lines)
            out.sourceLabel = "图片"
            if let f = failure {
                out.errorText = f
            } else if out.rawLines.isEmpty {
                out.errorText = "图片里没找到文字，换一张清晰点的试试"
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    private static func ocrLines(_ image: UIImage) -> (lines: [String], error: String?) {
        guard let cg = image.cgImage else {
            return ([], "有张图片读取不了，换一张试试")
        }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        if #available(iOS 16.0, *) { req.automaticallyDetectsLanguage = true }

        do {
            try VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:]).perform([req])
            return ((req.results ?? []).compactMap { $0.topCandidates(1).first?.string }, nil)
        } catch {
            // 兜底：不指定识别语言再试一次
            let retry = VNRecognizeTextRequest()
            retry.recognitionLevel = .accurate
            retry.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:]).perform([retry])
                return ((retry.results ?? []).compactMap { $0.topCandidates(1).first?.string }, nil)
            } catch {
                return ([], "识别失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 文字识别（不联网，纯本机）

    static func recognize(text: String, now: Date = Date(),
                          completion: @escaping (SmartParseResult) -> Void) {
        let lines = text
            .components(separatedBy: CharacterSet.newlines)
            .flatMap { $0.components(separatedBy: "。") }
        var r = parse(lines: lines, now: now)
        r.sourceLabel = "文字"
        if r.rawLines.isEmpty {
            r.errorText = "这里没读到内容"
        } else if r.dueDate == nil, (r.repeatMode ?? RepeatMode.none) == RepeatMode.none {
            r.tips.append("这句话里没找到时间或重复的说法，可以写「明天下午 3 点」这种")
        }
        DispatchQueue.main.async { completion(r) }
    }

    // MARK: 文本解析

    static func parse(lines: [String], now: Date = Date()) -> SmartParseResult {
        var r = SmartParseResult()
        r.rawLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !r.rawLines.isEmpty else { return r }

        // 去掉空白，让被 OCR 断行的句子能连起来
        let flat = r.rawLines.joined().replacingOccurrences(of: "\u{3000}", with: "")

        let cal = Calendar.current
        let today0 = cal.startOfDay(for: now)

        // ---------- 1. 重复规则 ----------
        var mode: RepeatMode = .none
        var weekdays: [Int] = []

        if firstMatch("工作日|周[一二三四五]\\s*(?:至|到|~|-)\\s*周?[一二三四五]|每(?:周|星期|礼拜)[一二三四五]\\s*(?:至|到|~)\\s*[一二三四五]", in: flat) != nil {
            mode = .weekday
        } else if let m = firstMatch("每(?:个)?月(?:(\\d{1,2})\\s*[号日])?", in: flat) {
            mode = .monthly
            if m.groups.count > 1, let d = Int(m.groups[1]) { r.monthDay = d }
        } else if let m = firstMatch("每(?:周|星期|礼拜)([一二三四五六日天](?:[、,，和及/\\+]*(?:周|星期|礼拜)?[一二三四五六日天])*)", in: flat) {
            mode = .weekly
            for ch in m.groups[1] {
                if let w = weekdayNumber(String(ch)), !weekdays.contains(w) { weekdays.append(w) }
            }
        } else if firstMatch("每(?:周|星期|礼拜)", in: flat) != nil {
            mode = .weekly
        } else if let m = firstMatch("每隔\\s*(\\d{1,2})\\s*天", in: flat) {
            mode = .daily
            r.tips.append("原文是「每隔\(m.groups[1])天」，本 App 目前只能按「每天」重复，已按每天处理")
        } else if firstMatch("每天|每日|天天|每一天|每晚|每早|每日一次|一天一次|每早一次", in: flat) != nil {
            mode = .daily
        }

        // ---------- 2. 日期 ----------
        var dayStart: Date? = nil

        if let m = firstMatch("(\\d{4})\\s*年\\s*(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*[日号]?", in: flat),
           let y = Int(m.groups[1]), let mo = Int(m.groups[2]), let da = Int(m.groups[3]),
           let d = makeDate(y, mo, da, cal) {
            dayStart = cal.startOfDay(for: d)
        } else if let m = firstMatch("(\\d{4})[-/.]\\s*(\\d{1,2})[-/.]\\s*(\\d{1,2})", in: flat),
                  let y = Int(m.groups[1]), let mo = Int(m.groups[2]), let da = Int(m.groups[3]),
                  let d = makeDate(y, mo, da, cal) {
            dayStart = cal.startOfDay(for: d)
        } else if let m = firstMatch("(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*[日号]", in: flat),
                  let mo = Int(m.groups[1]), let da = Int(m.groups[2]),
                  let d = makeDate(cal.component(.year, from: now), mo, da, cal) {
            // 今年已经过了就顺延到明年
            if cal.startOfDay(for: d) < today0,
               let d2 = makeDate(cal.component(.year, from: now) + 1, mo, da, cal) {
                dayStart = cal.startOfDay(for: d2)
            } else {
                dayStart = cal.startOfDay(for: d)
            }
        } else if let m = firstMatch("(?<![\\d:：])(\\d{1,2})[/-](\\d{1,2})(?![\\d:：])", in: flat),
                  let mo = Int(m.groups[1]), let da = Int(m.groups[2]),
                  let d = makeDate(cal.component(.year, from: now), mo, da, cal) {
            dayStart = cal.startOfDay(for: d < today0 ? (makeDate(cal.component(.year, from: now) + 1, mo, da, cal) ?? d) : d)
        }

        // 每月 N 号
        if dayStart == nil, mode == .monthly, let md = r.monthDay, (1...31).contains(md) {
            var c = DateComponents()
            c.day = md
            if let d = cal.nextDate(after: now, matching: c, matchingPolicy: .nextTime) {
                dayStart = cal.startOfDay(for: d)
            }
        }

        // 相对日
        if dayStart == nil {
            let rel: [(String, Int)] = [("大后天", 3), ("后天", 2), ("明晚", 1), ("明早", 1),
                                        ("明天", 1), ("明日", 1), ("今晚", 0), ("今早", 0),
                                        ("今天", 0), ("今日", 0)]
            for (w, off) in rel where flat.contains(w) {
                dayStart = cal.date(byAdding: .day, value: off, to: today0)
                break
            }
        }

        // 周几
        if dayStart == nil, mode != .weekday,
           let m = firstMatch("(下下|下|本|这)?\\s*(?:周|星期|礼拜)\\s*([一二三四五六日天])", in: flat),
           let wd = weekdayNumber(m.groups[2]) {
            let curMon = (cal.component(.weekday, from: today0) + 5) % 7
            let tgtMon = (wd + 5) % 7
            var delta = tgtMon - curMon
            switch m.groups[1] {
            case "下": delta += 7
            case "下下": delta += 14
            default: if delta < 0 { delta += 7 }
            }
            dayStart = cal.date(byAdding: .day, value: delta, to: today0)
        }

        // ---------- 3. 时间 ----------
        var hour: Int? = nil
        var minute = 0
        var matchAt = NSNotFound

        if let m = firstMatch("([01]?\\d|2[0-3])\\s*[:：]\\s*([0-5]\\d)", in: flat) {
            hour = Int(m.groups[1])
            minute = Int(m.groups[2]) ?? 0
            matchAt = m.range.location
        } else if let m = firstMatch("(\\d{1,2})\\s*[点时]\\s*(半|(\\d{1,2})\\s*分?)?", in: flat) {
            hour = Int(m.groups[1])
            if m.groups[2] == "半" {
                minute = 30
            } else if m.groups.count > 3, !m.groups[3].isEmpty {
                minute = Int(m.groups[3]) ?? 0
            }
            matchAt = m.range.location
        }

        // 时段词修正（下午 3 点 → 15:00）
        if var h = hour, matchAt != NSNotFound {
            let ns = flat as NSString
            let from = max(0, matchAt - 8)
            let pre = ns.substring(with: NSRange(location: from, length: matchAt - from))
            if let w = periodWords.first(where: { pre.contains($0) }) {
                h = adjustHour(h, period: w)
                hour = h
            }
        }

        // 只有时段词没有具体点数时给个默认值
        if hour == nil, mode != .none {
            if let w = periodWords.first(where: { flat.contains($0) }) {
                hour = defaultHour(period: w)
                minute = 0
                r.tips.append("原文只写了「\(w)」，时间默认按 \(String(format: "%02d:00", hour ?? 0))")
            }
        }

        // ---------- 4. 组装 ----------
        if let h = hour {
            let baseDay = dayStart ?? today0
            var comps = cal.dateComponents([.year, .month, .day], from: baseDay)
            comps.hour = h
            comps.minute = minute
            comps.second = 0
            var d = cal.date(from: comps) ?? now
            if d <= now {
                if mode != .none {
                    d = rollForward(d, mode: mode, weekdays: weekdays, cal: cal, now: now)
                } else {
                    d = now.addingTimeInterval(30 * 60)
                    r.tips.append("原文的时间已经过去了，先按 30 分钟后处理")
                }
            }
            r.dueDate = d
        } else if let day = dayStart {
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = 9
            comps.minute = 0
            comps.second = 0
            var d = cal.date(from: comps) ?? now
            if d <= now, mode != .none {
                d = rollForward(d, mode: mode, weekdays: weekdays, cal: cal, now: now)
            }
            if d <= now { d = now.addingTimeInterval(60 * 60) }
            r.dueDate = d
            r.tips.append("原文只给了日期没给时间，默认按 09:00")
        }

        r.repeatMode = mode
        r.weekdays = weekdays.sorted { (($0 + 5) % 7) < (($1 + 5) % 7) }
        r.titleSuggestion = suggestTitle(flat: flat, rawLines: r.rawLines)
        return r
    }

    // MARK: 猜标题

    /// 把第一句里跟时间、重复有关的词剥掉，剩下的当标题
    private static func suggestTitle(flat: String, rawLines: [String]) -> String? {
        let candidate = rawLines.first { $0.count >= 2 && $0.count <= 60 } ?? flat
        guard !candidate.isEmpty else { return nil }

        let noise = [
            "\\d{4}\\s*年\\s*\\d{1,2}\\s*月\\s*\\d{1,2}\\s*[日号]?",
            "\\d{4}[-/.]\\d{1,2}[-/.]\\d{1,2}",
            "\\d{1,2}\\s*月\\s*\\d{1,2}\\s*[日号]",
            "(?<![\\d:：])\\d{1,2}[/-]\\d{1,2}(?![\\d:：])",
            "大后天|后天|明晚|明早|明天|明日|今晚|今早|今天|今日",
            "(?:下下|下|本|这)?\\s*(?:周|星期|礼拜)\\s*[一二三四五六日天]",
            "每(?:个)?月(?:\\d{1,2}\\s*[号日])?",
            "每(?:周|星期|礼拜)[一二三四五六日天、,，和及/\\+]*",
            "每(?:周|星期|礼拜)",
            "每隔\\s*\\d{1,2}\\s*天",
            "每天|每日|天天|每一天|每晚|每早",
            "工作日",
            "([01]?\\d|2[0-3])\\s*[:：]\\s*[0-5]\\d",
            "\\d{1,2}\\s*[点时]\\s*(?:半|\\d{1,2}\\s*分?)?",
            "凌晨|清晨|早上|早晨|上午|中午|午后|下午|傍晚|晚上|晚间|夜里|夜间|深夜",
            "(?:记得|提醒我|提醒一下|提醒|别忘|不要忘|要|该|帮我|请|麻烦)"
        ]

        var s = candidate
        for p in noise {
            s = s.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,，,。.、;；:：!！?？-—~·*+()（）【】[]「」\"'“”"))
        if s.count < 2 {
            // 剥完没剩下什么，就用原句（截断）
            let raw = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.count >= 2 ? String(raw.prefix(24)) : nil
        }
        return String(s.prefix(24))
    }

    // MARK: 按重复规则往后推

    private static func rollForward(_ date: Date, mode: RepeatMode, weekdays: [Int],
                                    cal: Calendar, now: Date) -> Date {
        var d = date
        var guardCount = 0
        while d <= now && guardCount < 400 {
            guardCount += 1
            switch mode {
            case .none:
                return now.addingTimeInterval(30 * 60)
            case .daily:
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            case .weekday:
                repeat {
                    d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
                } while cal.isDateInWeekend(d)
            case .weekly:
                if weekdays.isEmpty {
                    d = cal.date(byAdding: .weekOfYear, value: 1, to: d) ?? d.addingTimeInterval(604800)
                } else {
                    let set = Set(weekdays)
                    repeat {
                        d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
                    } while !set.contains(cal.component(.weekday, from: d))
                }
            case .monthly:
                d = cal.date(byAdding: .month, value: 1, to: d) ?? d.addingTimeInterval(2592000)
            }
        }
        return d
    }

    // MARK: 正则

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let rr = m.range(at: i)
            groups.append(rr.location == NSNotFound ? "" : ns.substring(with: rr))
        }
        return Match(groups: groups, range: m.range)
    }

    private static func makeDate(_ y: Int, _ mo: Int, _ da: Int, _ cal: Calendar) -> Date? {
        guard (1...12).contains(mo), (1...31).contains(da) else { return nil }
        var c = DateComponents()
        c.year = y
        c.month = mo
        c.day = da
        c.hour = 12
        guard let d = cal.date(from: c) else { return nil }
        // 校验没有被 Calendar 自动滚动（例如 2 月 30 日）
        let got = cal.dateComponents([.year, .month, .day], from: d)
        guard got.year == y, got.month == mo, got.day == da else { return nil }
        return d
    }
}

// MARK: - 词表与小工具

private let periodWords = ["凌晨", "清晨", "早上", "早晨", "上午", "中午", "午后", "下午",
                           "傍晚", "晚上", "晚间", "夜里", "夜间", "深夜", "今早", "明早",
                           "今晚", "明晚", "每早", "每晚"]

private func adjustHour(_ h: Int, period: String) -> Int {
    switch period {
    case "凌晨", "清晨", "早上", "早晨", "上午", "今早", "明早", "每早":
        return h == 12 ? 0 : h
    case "中午":
        return h <= 5 ? h + 12 : h
    case "午后", "下午", "傍晚", "晚上", "晚间", "夜里", "夜间", "深夜", "今晚", "明晚", "每晚":
        return h < 12 ? h + 12 : h
    default:
        return h
    }
}

private func defaultHour(period: String) -> Int {
    switch period {
    case "凌晨", "清晨": return 6
    case "早上", "早晨", "今早", "明早", "每早": return 7
    case "上午": return 9
    case "中午": return 12
    case "午后", "下午": return 14
    case "傍晚": return 18
    default: return 20
    }
}

func weekdayNumber(_ s: String) -> Int? {
    switch s {
    case "一", "1": return 2
    case "二", "2": return 3
    case "三", "3": return 4
    case "四", "4": return 5
    case "五", "5": return 6
    case "六", "6": return 7
    case "日", "天", "7": return 1
    default: return nil
    }
}

private func weekdayName(_ wd: Int) -> String {
    switch wd {
    case 1: return "日"
    case 2: return "一"
    case 3: return "二"
    case 4: return "三"
    case 5: return "四"
    case 6: return "五"
    case 7: return "六"
    default: return ""
    }
}

func repeatLabel(_ m: RepeatMode, weekdays: [Int]) -> String {
    switch m {
    case .none:
        return "无"
    case .daily:
        return "每天"
    case .weekly:
        if weekdays.isEmpty { return "每周" }
        let names = weekdays.sorted { (($0 + 5) % 7) < (($1 + 5) % 7) }.map { weekdayName($0) }
        return "每周" + names.joined(separator: "、")
    case .weekday:
        return "工作日（周一至周五）"
    case .monthly:
        return "每月"
    }
}

func fmt(_ d: Date, _ pattern: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = pattern
    return f.string(from: d)
}

func relativeLabel(_ d: Date, now: Date) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day],
                                  from: cal.startOfDay(for: now),
                                  to: cal.startOfDay(for: d)).day ?? 0
    switch days {
    case 0: return "今天"
    case 1: return "明天"
    case 2: return "后天"
    case 3: return "大后天"
    case -1: return "昨天"
    default: return days > 0 ? "\(days) 天后" : "\(-days) 天前"
    }
}

// MARK: - 图片方向

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
