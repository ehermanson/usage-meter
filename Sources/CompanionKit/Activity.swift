import Foundation

public enum CompanionRange: String, Codable, CaseIterable, Sendable, Identifiable {
    case day, week, month, quarter
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .day: "24h";
        case .week: "7d";
        case .month: "30d";
        case .quarter: "90d"
        }
    }
}

/// Aggregates only: never contains model responses or session identifiers.
public struct CompanionActivity: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let timeZoneIdentifier: String
    public let ranges: [CompanionActivityRange]
    public let pricingUpdatedAt: Date?
    public init(
        capturedAt: Date, timeZoneIdentifier: String, ranges: [CompanionActivityRange],
        pricingUpdatedAt: Date? = nil
    ) {
        self.capturedAt = capturedAt; self.timeZoneIdentifier = timeZoneIdentifier;
        self.ranges = ranges
        self.pricingUpdatedAt = pricingUpdatedAt
    }
    public func validated() throws {
        guard ranges.count <= 4, Set(ranges.map(\.range)).count == ranges.count else {
            throw CompanionError.invalidSnapshot
        }
        for range in ranges {
            guard range.bucketStarts.count <= 100,
                zip(range.bucketStarts, range.bucketStarts.dropFirst()).allSatisfy({ $0 < $1 }),
                range.providers.count <= 16,
                Set(range.providers.map(\.name)).count == range.providers.count,
                range.providers.allSatisfy({ provider in
                    provider.tokens >= 0 && provider.tokens <= 1_000_000_000_000_000
                        && provider.sessions >= 0 && provider.sessions <= 1_000_000_000
                        && provider.unpricedTokens >= 0
                        && provider.unpricedTokens <= provider.tokens
                        && provider.cost.isFinite && provider.cost >= 0
                        && provider.cost <= 1_000_000_000_000_000
                        && provider.bucketTokens.count == range.bucketStarts.count
                        && provider.bucketCost.count == range.bucketStarts.count
                        && provider.bucketTokens.allSatisfy {
                            $0 >= 0 && $0 <= 1_000_000_000_000_000
                        }
                        && provider.bucketCost.allSatisfy {
                            $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000_000_000
                        }
                })
            else { throw CompanionError.invalidSnapshot }
        }
    }
}

public struct CompanionActivityRange: Codable, Equatable, Sendable, Identifiable {
    public var id: CompanionRange { range }
    public let range: CompanionRange
    public let bucketStarts: [Date]
    public let providers: [CompanionProviderActivity]
    public var tokens: Int { providers.reduce(0) { $0 + $1.tokens } }
    public var cost: Double { providers.reduce(0) { $0 + $1.cost } }
    public var sessions: Int { providers.reduce(0) { $0 + $1.sessions } }
    public var unpricedTokens: Int { providers.reduce(0) { $0 + $1.unpricedTokens } }
    public init(range: CompanionRange, bucketStarts: [Date], providers: [CompanionProviderActivity])
    {
        self.range = range; self.bucketStarts = bucketStarts; self.providers = providers
    }
}

public struct CompanionProviderActivity: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let tokens: Int
    public let cost: Double
    public let unpricedTokens: Int
    public let sessions: Int
    public let bucketTokens: [Int]
    public let bucketCost: [Double]
    public init(
        name: String, tokens: Int, cost: Double, unpricedTokens: Int, sessions: Int,
        bucketTokens: [Int], bucketCost: [Double]
    ) {
        self.name = name; self.tokens = tokens; self.cost = cost;
        self.unpricedTokens = unpricedTokens
        self.sessions = sessions; self.bucketTokens = bucketTokens; self.bucketCost = bucketCost
    }
}
