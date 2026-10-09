import Foundation

/// Jellyfin's timestamps ("2026-10-09T14:03:21.1234567Z"), read without a formatter.
/// ISO8601DateFormatter plus the string clean-up cost ~57 µs a date, and sorting 8.000 songs
/// or 1.000 albums by date does thousands of them; this reads the digits directly (<1 µs).
enum JellyfinDate {
    /// nil when the text isn't a date. UTC when it has no zone, as Jellyfin always sends it.
    static func parse(_ raw: String) -> Date? {
        if let fast = parseFast(raw) { return fast }
        return parseSlow(raw)
    }

    /// `yyyy-MM-ddTHH:mm:ss`, an optional fraction (any number of digits, dropped), then
    /// nothing, `Z` or `±HH:mm`. Anything else is left to the formatter.
    static func parseFast(_ raw: String) -> Date? {
        var text = raw
        return text.withUTF8 { bytes -> Date? in
            guard bytes.count >= 19 else { return nil }

            func digits(_ start: Int, _ count: Int) -> Int? {
                var value = 0
                for index in start..<start + count {
                    let digit = Int(bytes[index]) - 48
                    guard (0...9).contains(digit) else { return nil }
                    value = value * 10 + digit
                }
                return value
            }

            guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58,
                  let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
                  let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
                  (1...12).contains(month), (1...daysIn(month, year: year)).contains(day),
                  hour < 24, minute < 60, second < 60 else { return nil }

            var index = 19
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            }

            var offset = 0
            if index < bytes.count {
                switch bytes[index] {
                case 90 where index == bytes.count - 1: // Z
                    break
                case 43 where bytes.count - index == 6, 45 where bytes.count - index == 6: // ±HH:mm
                    guard bytes[index + 3] == 58, let offsetHours = digits(index + 1, 2),
                          let offsetMinutes = digits(index + 4, 2), offsetHours < 24, offsetMinutes < 60 else { return nil }
                    offset = (offsetHours * 3600 + offsetMinutes * 60) * (bytes[index] == 45 ? -1 : 1)
                default:
                    return nil
                }
            }

            let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
                + hour * 3600 + minute * 60 + second - offset
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func daysIn(_ month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Odd strings only. The fraction (Jellyfin sends 7 digits) is dropped, as the
    /// formatter wants 3 or none, and a missing zone counts as UTC.
    static func parseSlow(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            let rest = text[dot...].drop(while: { $0 == "." || $0.isNumber })
            text = String(text[..<dot]) + rest
        }
        if !text.hasSuffix("Z"), !text.contains("+") { text += "Z" }
        return slowParser.date(from: text)
    }

    private static let slowParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension Sequence {
    /// Newest first by a date read once per element, not at every comparison. A missing
    /// date goes last; ties keep their order (Swift's sort alone is not stable).
    func sortedNewestFirst(by date: (Element) -> Date?) -> [Element] {
        let decorated = enumerated().map { (offset: $0.offset, element: $0.element, date: date($0.element) ?? .distantPast) }
        return decorated.sorted { a, b in
            a.date != b.date ? a.date > b.date : a.offset < b.offset
        }.map(\.element)
    }
}
