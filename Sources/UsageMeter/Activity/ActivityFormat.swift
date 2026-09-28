import Foundation

extension Format {
    /// "0", "950", "12.3K", "145M", "2.90B": exact below a thousand, three
    /// significant digits above. Three digits is as much as a token count can
    /// honestly claim — the figure is an estimate built from logs, not a
    /// meter reading — and always three, so the hero and the rows under it
    /// read at the same precision ("2.90B" over "2.77B" and "145M", not
    /// "2.9B"). Only a fraction that's all zeros goes ("1K", "10K", "2B").
    static func tokens(_ count: Int) -> String {
        guard count.magnitude >= 1000 else { return "\(count)" }
        return (count < 0 ? "-" : "") + compact(Double(count.magnitude), trim: dropZeroFraction)
    }

    /// "$1,257.90" — US dollars (the currency every price is quoted in) to
    /// the cent, laid out for `locale`.
    static func cost(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.currency(code: "USD").locale(locale).precision(.fractionLength(2)))
    }

    /// Chart axis labels, where width is scarce: "0", "500M", "1.5B".
    static func tokensAxis(_ value: Double) -> String {
        guard abs(value) >= 1000 else { return trimmed(String(format: "%.1f", value)) }
        return (value < 0 ? "-" : "") + compact(abs(value))
    }

    /// "$0", "$0.25", "$2.5", "$600", "$1.2K". Below ten cents it takes as
    /// many places as two significant digits need — "$0.0004", "$0.005",
    /// "$0.025" — so a light range's gridlines don't all read "$0", or two
    /// of them "$0.01". Axis ticks are round numbers, which two digits say
    /// exactly.
    static func costAxis(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        guard magnitude >= 1000 else {
            let places =
                magnitude > 0 ? max(2, 1 - Int(log10(magnitude).rounded(.down))) : 2
            return sign + "$" + trimmed(String(format: "%.*f", places, magnitude))
        }
        return sign + "$" + compact(magnitude)
    }

    /// A part of a whole, 0...1, always to one decimal — "95.0%", "89.8%",
    /// "0.2%" — so shares listed together line up. A nonzero share too small
    /// to show reads "<0.1%" rather than rounding to a "0.0%" that would
    /// contradict a row with real activity in it.
    static func share(_ fraction: Double) -> String {
        let percent = fraction * 100
        if percent > 0, percent < 0.05 { return "<0.1%" }
        return String(format: "%.1f", percent) + "%"
    }

    /// "1 session", "124 sessions".
    static func sessions(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    /// Three significant digits with a K/M/B/T suffix, for values ≥ 1000,
    /// with `trim` deciding which trailing zeros go. Rounding can carry into
    /// the next digit or unit (999,950 is "1.00M", not "1000K"), so the width
    /// is decided on the rounded value.
    private static func compact(
        _ value: Double, trim: (String) -> String = trimmed
    ) -> String {
        let units: [(scale: Double, suffix: String)] = [
            (1e3, "K"), (1e6, "M"), (1e9, "B"), (1e12, "T"),
        ]
        for (i, unit) in units.enumerated() {
            let scaled = value / unit.scale
            let isLast = i == units.count - 1
            if scaled >= 1000, !isLast { continue }
            var decimals = scaled < 10 ? 2 : scaled < 100 ? 1 : 0
            var text = String(format: "%.*f", decimals, scaled)
            let rounded = Double(text) ?? scaled
            if rounded >= 1000, !isLast { continue }
            if rounded >= 100, decimals > 0 {
                decimals = 0
            } else if rounded >= 10, decimals > 1 {
                decimals = 1
            }
            text = String(format: "%.*f", decimals, scaled)
            return trim(text) + unit.suffix
        }
        return String(format: "%.0f", value)
    }

    /// "1.50" → "1.50", "10.0" → "10", "2.00" → "2": the fraction goes only
    /// when it says nothing, so a figure keeps its significant digits.
    private static func dropZeroFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        let fraction = text[text.index(after: dot)...]
        return fraction.allSatisfy { $0 == "0" } ? String(text[..<dot]) : text
    }

    /// "1.50" → "1.5", "10.0" → "10", "600.00" → "600". For axis labels,
    /// where width counts for more than matching precision.
    private static func trimmed(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var result = Substring(text)
        while result.hasSuffix("0") { result = result.dropLast() }
        if result.hasSuffix(".") { result = result.dropLast() }
        return result == "-0" ? "0" : String(result)
    }
}
