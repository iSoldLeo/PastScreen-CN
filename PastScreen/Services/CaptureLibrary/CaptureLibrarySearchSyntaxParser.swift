//
//  CaptureLibrarySearchSyntaxParser.swift
//  PastScreen
//

import Foundation

struct CaptureLibrarySearchSyntaxParser {
    struct Context {
        var appGroups: [CaptureLibraryAppGroup]
        var tagGroups: [CaptureLibraryTagGroup]
        var now: Date
        var calendar: Calendar
    }

    static func apply(_ raw: String, to query: inout CaptureLibraryQuery, context: Context) -> String? {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }
            .filter { !$0.isEmpty }

        var remaining: [String] = []
        remaining.reserveCapacity(tokens.count)

        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if isPinnedToken(trimmed) {
                query.pinnedOnly = true
                continue
            }

            if let range = parsePeriodKeyword(trimmed, calendar: context.calendar, now: context.now) {
                query.createdAfter = range.start
                query.createdBefore = range.end
                continue
            }

            if let relative = parseRelativeTimeToken(trimmed, calendar: context.calendar, now: context.now) {
                query.createdAfter = relative
                query.createdBefore = nil
                continue
            }

            if let days = parseRelativeDaysToken(trimmed) {
                query.createdAfter = context.now.addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
                query.createdBefore = nil
                continue
            }

            if let dayRange = parseDayKeyword(trimmed, calendar: context.calendar, now: context.now) {
                query.createdAfter = dayRange.start
                query.createdBefore = dayRange.end
                continue
            }

            if let date = parseDateToken(trimmed, calendar: context.calendar, now: context.now) {
                let start = context.calendar.startOfDay(for: date)
                let end = context.calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001)
                query.createdAfter = start
                query.createdBefore = end
                continue
            }

            if trimmed.hasPrefix("#") || trimmed.hasPrefix("＃") {
                let value = String(trimmed.dropFirst())
                if let tag = resolveTagName(from: value, tagGroups: context.tagGroups, requireExisting: false), !tag.isEmpty {
                    query.tag = tag
                    continue
                }
            }

            if let (key, value) = parseKeyValue(trimmed) {
                switch key.lowercased() {
                case "app", "应用":
                    if let resolved = resolveAppBundleID(from: value, appGroups: context.appGroups) {
                        query.appBundleID = resolved
                        continue
                    }
                case "tag", "标签":
                    if let resolved = resolveTagName(from: value, tagGroups: context.tagGroups, requireExisting: false), !resolved.isEmpty {
                        query.tag = resolved
                        continue
                    }
                case "type", "类型":
                    if let resolved = captureType(from: value) {
                        query.captureType = resolved
                        continue
                    }
                default:
                    break
                }
            }

            if query.appBundleID == nil, let bundleID = resolveAppBundleID(from: trimmed, appGroups: context.appGroups) {
                query.appBundleID = bundleID
                continue
            }

            if query.tag == nil, let tag = resolveTagName(from: trimmed, tagGroups: context.tagGroups, requireExisting: true), !tag.isEmpty {
                query.tag = tag
                continue
            }

            remaining.append(trimmed)
        }

        let cleaned = remaining.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func parseKeyValue(_ token: String) -> (key: String, value: String)? {
        let separators: [Character] = [":", "："]
        guard let separator = separators.first(where: { token.contains($0) }) else { return nil }
        let parts = token.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = stripQuotes(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty, !value.isEmpty else { return nil }
        guard isSupportedQueryKey(key) else { return nil }
        return (key, value)
    }

    private static func isSupportedQueryKey(_ key: String) -> Bool {
        let lowered = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "app" || lowered == "tag" || lowered == "type" { return true }
        if key == "应用" || key == "标签" || key == "类型" { return true }
        return false
    }

    private static func stripQuotes(_ value: String) -> String {
        var text = value
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func resolveAppBundleID(from value: String, appGroups: [CaptureLibraryAppGroup]) -> String? {
        let trimmed = stripQuotes(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(".") {
            return trimmed
        }

        let lowered = trimmed.lowercased()
        if let match = appGroups.first(where: { group in
            let name = group.appName.lowercased()
            return name == lowered || name.contains(lowered) || lowered.contains(name)
        }) {
            return match.bundleID
        }

        return nil
    }

    private static func resolveTagName(from value: String, tagGroups: [CaptureLibraryTagGroup], requireExisting: Bool) -> String? {
        let trimmed = stripQuotes(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if let match = tagGroups.first(where: { group in
            let name = group.name.lowercased()
            return name == lowered
        }) {
            return match.name
        }

        return requireExisting ? nil : trimmed
    }

    private static func captureType(from value: String) -> CaptureItemCaptureType? {
        let trimmed = stripQuotes(value.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
        switch trimmed {
        case "area", "selection", "region", "选区":
            return .area
        case "window", "窗口":
            return .window
        case "fullscreen", "full", "screen", "全屏":
            return .fullscreen
        default:
            return nil
        }
    }

    private static func isPinnedToken(_ token: String) -> Bool {
        let lowered = token.lowercased()
        return lowered == "pinned" || lowered == "pin" || lowered == "置顶"
    }

    private static func parseDayKeyword(_ token: String, calendar: Calendar, now: Date) -> (start: Date, end: Date)? {
        let lowered = token.lowercased()
        if lowered == "today" || lowered == "今天" {
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001) ?? now
            return (start, end)
        }

        if lowered == "yesterday" || lowered == "昨天" {
            guard let day = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            let start = calendar.startOfDay(for: day)
            let end = calendar.startOfDay(for: now).addingTimeInterval(-0.001)
            return (start, end)
        }

        return nil
    }

    private static func parsePeriodKeyword(_ token: String, calendar: Calendar, now: Date) -> (start: Date, end: Date)? {
        let lowered = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func clampedInterval(_ interval: DateInterval?) -> (start: Date, end: Date)? {
            guard let interval else { return nil }
            let start = interval.start
            let end = interval.end.addingTimeInterval(-0.001)
            return (start, end)
        }

        if lowered == "本周" || lowered == "这周" || lowered == "本星期" || lowered == "这星期" || lowered == "thisweek" {
            return clampedInterval(calendar.dateInterval(of: .weekOfYear, for: now))
        }
        if lowered == "上周" || lowered == "上星期" || lowered == "lastweek" {
            guard let date = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
            return clampedInterval(calendar.dateInterval(of: .weekOfYear, for: date))
        }

        if lowered == "本月" || lowered == "这个月" || lowered == "thismonth" {
            return clampedInterval(calendar.dateInterval(of: .month, for: now))
        }
        if lowered == "上月" || lowered == "上个月" || lowered == "lastmonth" {
            guard let date = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return clampedInterval(calendar.dateInterval(of: .month, for: date))
        }

        if lowered == "今年" || lowered == "本年" || lowered == "thisyear" {
            return clampedInterval(calendar.dateInterval(of: .year, for: now))
        }
        if lowered == "去年" || lowered == "lastyear" {
            guard let date = calendar.date(byAdding: .year, value: -1, to: now) else { return nil }
            return clampedInterval(calendar.dateInterval(of: .year, for: date))
        }

        return nil
    }

    private static func parseRelativeTimeToken(_ token: String, calendar: Calendar, now: Date) -> Date? {
        var lowered = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }

        let prefixes = ["最近", "近", "过去", "过去的", "past", "last"]
        for prefix in prefixes where lowered.hasPrefix(prefix) {
            lowered = String(lowered.dropFirst(prefix.count))
            break
        }

        enum Unit { case day, week, month }

        let unit: Unit
        let numberText: String

        if lowered.hasSuffix("天") {
            unit = .day
            numberText = String(lowered.dropLast(1))
        } else if lowered.hasSuffix("日") {
            unit = .day
            numberText = String(lowered.dropLast(1))
        } else if lowered.hasSuffix("d") {
            unit = .day
            numberText = String(lowered.dropLast(1))
        } else if lowered.hasSuffix("周") {
            unit = .week
            numberText = String(lowered.dropLast(1))
        } else if lowered.hasSuffix("星期") {
            unit = .week
            numberText = String(lowered.dropLast(2))
        } else if lowered.hasSuffix("w") {
            unit = .week
            numberText = String(lowered.dropLast(1))
        } else if lowered.hasSuffix("个月") {
            unit = .month
            numberText = String(lowered.dropLast(2))
        } else if lowered.hasSuffix("月") {
            unit = .month
            numberText = String(lowered.dropLast(1))
        } else if lowered.hasSuffix("m") {
            unit = .month
            numberText = String(lowered.dropLast(1))
        } else {
            return nil
        }

        let trimmed = numberText.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = parseLooseInt(trimmed) ?? (trimmed.isEmpty ? 1 : nil)
        guard let count, count > 0 else { return nil }

        switch unit {
        case .day:
            return now.addingTimeInterval(TimeInterval(-count * 24 * 60 * 60))
        case .week:
            return now.addingTimeInterval(TimeInterval(-count * 7 * 24 * 60 * 60))
        case .month:
            return calendar.date(byAdding: .month, value: -count, to: now)
        }
    }

    private static func parseLooseInt(_ text: String) -> Int? {
        if let value = Int(text) { return value }

        let mapping: [String: Int] = [
            "一": 1, "二": 2, "两": 2, "俩": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ]
        return mapping[text]
    }

    private static func parseRelativeDaysToken(_ token: String) -> Int? {
        let lowered = token.lowercased()

        if lowered.hasPrefix("最近"), lowered.hasSuffix("天") {
            let number = lowered.dropFirst(2).dropLast()
            return Int(number)
        }

        if lowered.hasPrefix("近"), lowered.hasSuffix("天") {
            let number = lowered.dropFirst(1).dropLast()
            return Int(number)
        }

        if lowered.hasSuffix("d") {
            return Int(lowered.dropLast())
        }

        if lowered.hasSuffix("天") {
            return Int(lowered.dropLast())
        }

        return nil
    }

    private static func parseDateToken(_ token: String, calendar: Calendar, now: Date) -> Date? {
        var cleaned = token
        cleaned = cleaned.replacingOccurrences(of: "年", with: "-")
        cleaned = cleaned.replacingOccurrences(of: "月", with: "-")
        cleaned = cleaned.replacingOccurrences(of: "日", with: "")

        let separators = CharacterSet(charactersIn: "/-.")
        let parts = cleaned
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count == 2 || parts.count == 3 else { return nil }

        let year: Int
        let month: Int
        let day: Int

        if parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
            year = y
            month = m
            day = d
        } else if parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]) {
            year = calendar.component(.year, from: now)
            month = m
            day = d
        } else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }
}

