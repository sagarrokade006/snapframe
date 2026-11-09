import Foundation

/// Turns a user-editable pattern such as `Snapframe {date} at {time}` into a safe file name.
public struct NameTemplate: Equatable, Sendable {
    public static let defaultPattern = "Snapframe {date} at {time}"
    public static let tokens = ["date", "time", "year", "month", "day", "hour", "minute", "second", "mode"]

    public var pattern: String

    public init(pattern: String) {
        self.pattern = pattern
    }

    public func render(date: Date, mode: String, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let day = String(format: "%02d", parts.day ?? 0)
        let hour = String(format: "%02d", parts.hour ?? 0)
        let minute = String(format: "%02d", parts.minute ?? 0)
        let second = String(format: "%02d", parts.second ?? 0)

        let values = [
            "date": "\(year)-\(month)-\(day)",
            "time": "\(hour).\(minute).\(second)",
            "year": year, "month": month, "day": day,
            "hour": hour, "minute": minute, "second": second,
            "mode": mode,
        ]

        var output = pattern
        for (token, value) in values {
            output = output.replacingOccurrences(of: "{\(token)}", with: value)
        }
        return Self.sanitize(output)
    }

    /// Removes characters that are unsafe in file names and guarantees a non-empty result.
    public static func sanitize(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                return "-"
            }
            return Character(scalar)
        }
        var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = String(cleaned.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Snapframe" : cleaned
    }

    /// Picks `name.ext`, or `name 2.ext` and so on when earlier names are taken.
    public static func uniqueURL(
        directory: URL,
        baseName: String,
        fileExtension: String,
        exists: (URL) -> Bool
    ) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }
}
