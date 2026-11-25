import Foundation

/// Parses a duration such as `90`, `90s`, `10m`, `2h` or `1.5h` into seconds.
/// A bare number means seconds. Returns `nil` unless the result is a positive,
/// finite number.
public func parseDuration(_ text: String) -> TimeInterval? {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard let last = trimmed.last else { return nil }
    let multipliers: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600]
    let (number, multiplier): (Substring, TimeInterval) =
        multipliers[last].map { (trimmed.dropLast(), $0) } ?? (Substring(trimmed), 1)
    // Accept digits with at most one decimal point; reject signs, exponents, "nan", "inf".
    guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
          number.filter({ $0 == "." }).count <= 1,
          let value = Double(number)
    else { return nil }
    let seconds = value * multiplier
    return seconds > 0 && seconds.isFinite ? seconds : nil
}

/// Formats a number of seconds compactly: `45s`, `12m`, `1h05m`.
func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m" }
    let minutes = (total % 3600) / 60
    return "\(total / 3600)h" + (minutes > 0 ? String(format: "%02dm", minutes) : "")
}
