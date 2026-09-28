import Foundation

/// One model's API prices, in USD per token, as LiteLLM publishes them.
struct ModelPricing: Equatable, Sendable {
    struct Rates: Equatable, Sendable {
        var input: Double? = nil
        var output: Double? = nil
        var cacheRead: Double? = nil
        /// The default (5-minute) cache write.
        var cacheWrite: Double? = nil
        var cacheWrite1h: Double? = nil
    }

    /// Long-context pricing: once a request's prompt exceeds `threshold`
    /// tokens, each rate the tier defines replaces the base one — for the
    /// whole request, not just the part past the threshold.
    struct Tier: Equatable, Sendable {
        let threshold: Int
        let rates: Rates
    }

    var base: Rates
    /// Ascending by threshold.
    var tiers: [Tier]

    init(base: Rates, tiers: [Tier] = []) {
        self.base = base
        self.tiers = tiers.sorted { $0.threshold < $1.threshold }
    }

    /// The API-equivalent cost of one response. `longCacheWrites` is the part
    /// of `tokens.cacheWrite` that went to the 1-hour cache.
    ///
    /// The most specific rate wins: the highest tier the prompt exceeds, then
    /// lower ones, then the base. A rate nobody defines falls back the way
    /// providers bill in practice — a cache read or write at the input rate,
    /// a 1-hour write at the 5-minute one.
    func cost(_ tokens: TokenCounts, longCacheWrites: Int = 0) -> Double {
        let exceeded = tiers.filter { tokens.promptTotal > $0.threshold }
        func rate(_ field: KeyPath<Rates, Double?>) -> Double? {
            for tier in exceeded.reversed() {
                if let value = tier.rates[keyPath: field] { return value }
            }
            return base[keyPath: field]
        }
        let input = rate(\.input) ?? 0
        let output = rate(\.output) ?? 0
        let read = rate(\.cacheRead) ?? input
        let write = rate(\.cacheWrite) ?? input
        let longWrite = rate(\.cacheWrite1h) ?? write
        let long = min(max(0, longCacheWrites), tokens.cacheWrite)
        return Double(tokens.input) * input + Double(tokens.output) * output
            + Double(tokens.cacheRead) * read + Double(tokens.cacheWrite - long) * write
            + Double(long) * longWrite
    }
}

/// Model id → prices, with the lookup rules that let log ids find their
/// entries: logs say "claude-opus-5-5[1m]" or a dated snapshot id where the
/// table has the bare name.
struct PricingTable: Sendable {
    enum Source: Equatable, Sendable {
        case bundled
        /// A LiteLLM download, with when it was fetched.
        case downloaded(Date)
    }

    let models: [String: ModelPricing]
    let source: Source

    init(models: [String: ModelPricing], source: Source = .bundled) {
        self.models = Dictionary(
            models.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.source = source
    }

    static let bundled = PricingTable(models: bundledModels, source: .bundled)

    /// Anthropic's fast mode on these models is billed at exactly twice the
    /// standard rates. Elsewhere the flag is ignored and standard applies.
    static let fastModeMultiplier = 2.0
    static let fastModeModels: Set<String> = ["claude-opus-5", "claude-opus-5-5"]

    /// A downloaded table layered over the bundled one: the download wins
    /// wherever it has an entry, and the bundle still covers anything it
    /// dropped.
    func overlaying(_ newer: PricingTable) -> PricingTable {
        PricingTable(
            models: models.merging(newer.models) { _, new in new }, source: newer.source)
    }

    /// Candidate keys, most specific first: the id as logged, without a
    /// bracketed suffix ("[1m]"), without a date suffix ("-20251001" or
    /// "-2025-10-01"), then each of those under the provider prefixes
    /// LiteLLM files some models under.
    static func lookupKeys(for model: String) -> [String] {
        let exact = model.lowercased().trimmingCharacters(in: .whitespaces)
        let unbracketed = stripBracketSuffix(exact)
        let undated = stripDateSuffix(unbracketed)
        var keys: [String] = []
        for key in [exact, unbracketed, undated] where !keys.contains(key) {
            keys.append(key)
        }
        return keys + ["anthropic/", "openai/"].flatMap { prefix in keys.map { prefix + $0 } }
    }

    /// The id with any suffix a price can't depend on removed. Used to
    /// recognize fast-mode models however the log spells them.
    static func baseModel(_ model: String) -> String {
        stripDateSuffix(stripBracketSuffix(model.lowercased()))
    }

    func pricing(for model: String) -> ModelPricing? {
        for key in Self.lookupKeys(for: model) {
            if let hit = models[key] { return hit }
        }
        return nil
    }

    /// Nil when the model has no known price: the record's tokens still
    /// count, but it can't contribute a cost.
    func cost(of record: UsageRecord) -> Double? {
        guard let pricing = pricing(for: record.model) else { return nil }
        return cost(of: record, with: pricing)
    }

    /// `cost(of:)` with the lookup already done, for callers pricing many
    /// records of the same model.
    func cost(of record: UsageRecord, with pricing: ModelPricing) -> Double {
        let base = pricing.cost(record.tokens, longCacheWrites: record.cacheWrite1h)
        guard record.fast, Self.fastModeModels.contains(Self.baseModel(record.model)) else {
            return base
        }
        return base * Self.fastModeMultiplier
    }

    private static func stripBracketSuffix(_ id: String) -> String {
        guard id.hasSuffix("]"), let open = id.lastIndex(of: "["), open > id.startIndex else {
            return id
        }
        return String(id[..<open])
    }

    private static func stripDateSuffix(_ id: String) -> String {
        let bytes = Array(id.utf8)
        func isDigits(_ range: Range<Int>) -> Bool {
            range.allSatisfy { bytes[$0] >= 48 && bytes[$0] <= 57 }
        }
        let n = bytes.count
        // -YYYYMMDD
        if n > 9, bytes[n - 9] == UInt8(ascii: "-"), isDigits((n - 8)..<n) {
            return String(decoding: bytes[..<(n - 9)], as: UTF8.self)
        }
        // -YYYY-MM-DD
        if n > 11, bytes[n - 11] == UInt8(ascii: "-"), bytes[n - 6] == UInt8(ascii: "-"),
            bytes[n - 3] == UInt8(ascii: "-"), isDigits((n - 10)..<(n - 6)),
            isDigits((n - 5)..<(n - 3)), isDigits((n - 2)..<n)
        {
            return String(decoding: bytes[..<(n - 11)], as: UTF8.self)
        }
        return id
    }
}

extension PricingTable {
    /// Reads LiteLLM's `model_prices_and_context_window.json`, keeping only
    /// what a lookup can reach (bare ids and `anthropic/`/`openai/` ones —
    /// not Bedrock, Vertex, or the other resellers' copies) and only the
    /// token-price fields. `_flex`/`_priority`/`_batches` variants are other
    /// service tiers than the interactive one these logs record, so they're
    /// skipped. Nil if the data isn't a table of that shape.
    static func parseLiteLLM(_ data: Data, source: Source) -> PricingTable? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var models: [String: ModelPricing] = [:]
        for (key, value) in root {
            guard let entry = value as? [String: Any], isReachable(key),
                let pricing = parseEntry(entry)
            else { continue }
            models[key.lowercased()] = pricing
        }
        return models.isEmpty ? nil : PricingTable(models: models, source: source)
    }

    private static func isReachable(_ key: String) -> Bool {
        let slashes = key.filter { $0 == "/" }.count
        if slashes == 0 { return true }
        return slashes == 1 && (key.hasPrefix("anthropic/") || key.hasPrefix("openai/"))
    }

    private static let fields: [String: WritableKeyPath<ModelPricing.Rates, Double?>] = [
        "input_cost_per_token": \.input,
        "output_cost_per_token": \.output,
        "cache_read_input_token_cost": \.cacheRead,
        "cache_creation_input_token_cost": \.cacheWrite,
        "cache_creation_input_token_cost_above_1hr": \.cacheWrite1h,
    ]

    /// One entry's rates, or nil if it isn't priced per token (image and
    /// audio models, embeddings without output, …).
    static func parseEntry(_ entry: [String: Any]) -> ModelPricing? {
        var base = ModelPricing.Rates()
        var tiers: [Int: ModelPricing.Rates] = [:]
        for (key, value) in entry {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
            else { continue }
            if key.hasSuffix("_flex") || key.hasSuffix("_priority") || key.hasSuffix("_batches") {
                continue
            }
            // "<field>_above_<N>k_tokens" — N thousand prompt tokens.
            var field = key
            var threshold: Int?
            if key.hasSuffix("k_tokens"), let range = key.range(of: "_above_", options: .backwards)
            {
                let digits = key[range.upperBound...].dropLast("k_tokens".count)
                guard let n = Int(digits) else { continue }
                field = String(key[..<range.lowerBound])
                threshold = n * 1000
            }
            guard let path = fields[field] else { continue }
            if let threshold {
                tiers[threshold, default: .init()][keyPath: path] = number.doubleValue
            } else {
                base[keyPath: path] = number.doubleValue
            }
        }
        guard base.input != nil, base.output != nil else { return nil }
        return ModelPricing(
            base: base, tiers: tiers.map { ModelPricing.Tier(threshold: $0.key, rates: $0.value) })
    }
}
