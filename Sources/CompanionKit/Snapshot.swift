import Foundation

public enum CompanionConfiguration {
    public static let container = "iCloud.com.erichermanson.usagemeter"
    public static let appGroup = "group.com.erichermanson.usagemeter"
    public static let zone = "Companion"
    public static let recordType = "UsageSnapshot"
}

/// A deliberately narrow export. Credentials, paths, session logs and raw errors
/// have no representation here. Publication time never replaces observation time.
public struct CompanionSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { sourceID }
    public let schemaVersion: Int
    public let sourceID: UUID
    public let sourceName: String
    public let revision: Int64
    public let publishedAt: Date
    public let providers: [CompanionProvider]
    public let activity: CompanionActivity?

    public init(
        sourceID: UUID, sourceName: String, revision: Int64, publishedAt: Date,
        providers: [CompanionProvider], activity: CompanionActivity? = nil
    ) {
        self.schemaVersion = 1
        self.sourceID = sourceID
        self.sourceName = String(sourceName.prefix(80))
        self.revision = revision
        self.publishedAt = publishedAt
        self.providers = providers
        self.activity = activity
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else { throw CompanionError.unsupportedVersion }
        guard revision >= 0, providers.count <= 16,
            Set(providers.map(\.id)).count == providers.count,
            providers.allSatisfy({ provider in
                (provider.resetCredits.map { $0.available >= 0 && $0.available <= 1_000_000 }
                    ?? true)
                    && provider.windows.count <= 64
                    && Set(provider.windows.map(\.id)).count == provider.windows.count
                    && provider.windows.allSatisfy { $0.usedPercent.isFinite }
            })
        else { throw CompanionError.invalidSnapshot }
        try activity?.validated()
        return self
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 512_000 else { throw CompanionError.invalidSnapshot }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
}

public enum CompanionProviderStatus: String, Codable, Sendable {
    case available, temporarilyUnavailable, needsSetup
}

public struct CompanionProvider: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let plan: String?
    public let capturedAt: Date?
    public let status: CompanionProviderStatus
    public let windows: [CompanionWindow]
    public let resetCredits: CompanionResetCredits?

    public init(
        name: String, plan: String?, capturedAt: Date?,
        status: CompanionProviderStatus, windows: [CompanionWindow],
        resetCredits: CompanionResetCredits? = nil
    ) {
        self.name = name
        self.plan = plan
        self.capturedAt = capturedAt
        self.status = status
        self.windows = windows
        self.resetCredits = resetCredits
    }

    /// A configured provider with usable limits, including a carried-forward reading.
    public var hasConnectedLimits: Bool { status != .needsSetup && !windows.isEmpty }

    public func isStale(at now: Date) -> Bool {
        guard let capturedAt else { return true }
        return now.timeIntervalSince(capturedAt) >= 600 || capturedAt > now.addingTimeInterval(300)
    }

    public func isExpired(at now: Date) -> Bool {
        guard let capturedAt else { return true }
        return now.timeIntervalSince(capturedAt) >= 86_400
    }
}

public struct CompanionResetCredits: Codable, Equatable, Sendable {
    public let available: Int
    public let earliestExpiry: Date?
    public init(available: Int, earliestExpiry: Date?) {
        self.available = available; self.earliestExpiry = earliestExpiry
    }
}

public struct CompanionWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let pool: String?
    public let label: String
    public let usedPercent: Double
    public let resetAt: Date?
    public let duration: TimeInterval?
    public var fraction: Double { max(0, min(1, usedPercent / 100)) }

    public init(
        id: String, pool: String?, label: String, usedPercent: Double,
        resetAt: Date?, duration: TimeInterval?
    ) {
        self.id = id
        self.pool = pool
        self.label = label
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.duration = duration
    }

    public func needsNewReading(at now: Date) -> Bool {
        resetAt.map { $0 <= now } ?? false
    }
}

/// Selection, not authorization. The iCloud account is the access boundary.
public enum CompanionLink {
    public static func url(sourceID: UUID) -> URL {
        URL(string: "usagemeter://connect?v=1&source=\(sourceID.uuidString)")!
    }

    public static func sourceID(from url: URL) throws -> UUID {
        guard url.scheme?.lowercased() == "usagemeter", url.host == "connect",
            url.path.isEmpty, url.user == nil, url.password == nil, url.port == nil,
            url.fragment == nil,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = parts.queryItems, items.count == 2,
            items.filter({ $0.name == "v" }).count == 1,
            items.first(where: { $0.name == "v" })?.value == "1",
            items.filter({ $0.name == "source" }).count == 1,
            let value = items.first(where: { $0.name == "source" })?.value,
            let id = UUID(uuidString: value)
        else { throw CompanionError.invalidLink }
        return id
    }
}

public enum CompanionError: LocalizedError {
    case unsupportedVersion, invalidSnapshot, invalidLink, noAccount, sourceNotFound, notConfigured

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Update Usage Meter to read this Mac's data."
        case .invalidSnapshot: "The usage snapshot could not be read."
        case .invalidLink: "This isn't a supported Usage Meter connection code."
        case .noAccount: "Sign in to iCloud and use the same Apple Account on your Mac and iPhone."
        case .sourceNotFound:
            "This Mac hasn't uploaded a snapshot. Check iCloud sync on the Mac and use the same Apple Account."
        case .notConfigured:
            "This Mac build isn't configured for iCloud. Use a build signed with the CloudKit provisioning profile."
        }
    }
}
