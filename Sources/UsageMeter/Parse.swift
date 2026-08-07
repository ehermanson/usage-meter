import Foundation

/// Tolerant readers for the loosely-typed JSON the provider clients consume.
/// Shared so each client doesn't grow its own copy of the same coercions (and
/// its own pair of the not-cheap ISO8601 formatters).
enum Parse {
    /// A numeric value that may arrive as a JSON number or a numeric string.
    static func num(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// An ISO-8601 timestamp, with or without fractional seconds.
    static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// A plain (no fractional seconds) ISO-8601 rendering, for round-tripping
    /// dates back into stored JSON.
    static func isoString(_ date: Date) -> String {
        isoPlain.string(from: date)
    }

    // Formatters are expensive to build, so they're shared statics. Apple
    // documents ISO8601DateFormatter as thread-safe.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
