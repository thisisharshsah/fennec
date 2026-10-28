import Foundation

enum Formatting {
    static func number(_ value: Double?, digits: Int) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    static func compassPoint(_ heading: Double?) -> String {
        guard let heading else { return "" }
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((heading / 45).rounded()) % points.count
        return "° \(points[index])"
    }

    /// "45 s", "12 min", "2 h 5 min": how long someone has been here.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let minutes = (s % 3600) / 60
        return minutes == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(minutes) min"
    }
}
