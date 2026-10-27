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
}
