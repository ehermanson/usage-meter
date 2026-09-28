import Foundation
import Testing

@testable import UsageMeter

private func record(
    _ model: String, _ tokens: TokenCounts, oneHour: Int = 0, fast: Bool = false,
    provider: String = "Claude"
) -> UsageRecord {
    UsageRecord(
        provider: provider, timestamp: .now, model: model, sessionId: "s", dedupeKey: nil,
        tokens: tokens, loggedCacheWrite1h: oneHour, fast: fast)
}

private let million = 1_000_000

@Suite("Model pricing")
struct ModelPricingTests {
    let table = PricingTable.bundled

    @Test("bundled prices match the published per-MTok rates")
    func verifiedPrices() throws {
        func perMTok(_ model: String, _ tokens: TokenCounts, oneHour: Int = 0) -> Double {
            (table.cost(of: record(model, tokens, oneHour: oneHour)) ?? -1)
        }
        let opus55 = "claude-opus-5-5"
        #expect(abs(perMTok(opus55, TokenCounts(input: million)) - 4) < 1e-9)
        #expect(abs(perMTok(opus55, TokenCounts(output: million)) - 20) < 1e-9)
        #expect(abs(perMTok(opus55, TokenCounts(cacheRead: million)) - 0.20) < 1e-9)
        #expect(abs(perMTok(opus55, TokenCounts(cacheWrite: million)) - 5) < 1e-9)
        #expect(abs(perMTok(opus55, TokenCounts(cacheWrite: million), oneHour: million) - 8) < 1e-9)
        let fable = "claude-fable-5-1"
        #expect(abs(perMTok(fable, TokenCounts(input: million)) - 10) < 1e-9)
        #expect(abs(perMTok(fable, TokenCounts(output: million)) - 50) < 1e-9)
        #expect(abs(perMTok(fable, TokenCounts(cacheRead: million)) - 0.25) < 1e-9)
        #expect(abs(perMTok("claude-sonnet-5", TokenCounts(input: million)) - 2) < 1e-9)
        #expect(abs(perMTok("claude-sonnet-5", TokenCounts(output: million)) - 10) < 1e-9)
        #expect(abs(perMTok("gpt-6-astra", TokenCounts(input: 100_000)) - 1.0) < 1e-9)
        #expect(abs(perMTok("gpt-6-astra", TokenCounts(output: million)) - 50) < 1e-9)
        #expect(abs(perMTok("gpt-6-astra", TokenCounts(cacheRead: 100_000)) - 0.1) < 1e-9)
    }

    @Test("every model the spec names is in the bundled fallback")
    func bundledCoverage() {
        let ids = [
            "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5", "claude-opus-5",
            "claude-opus-4-8", "claude-fable-5", "claude-opus-4-7", "claude-haiku-4-5-20251001",
            "claude-opus-5-5[1m]", "claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5",
            "gpt-6-astra", "gpt-5.6-sol", "gpt-5.5", "gpt-6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
            "gpt-5", "gpt-5-codex", "gpt-5.1-codex",
        ]
        for id in ids { #expect(table.pricing(for: id) != nil, "\(id)") }
    }

    @Test("lookup: exact, then without [1m], then without a date, then provider-prefixed")
    func lookupNormalization() {
        #expect(
            PricingTable.lookupKeys(for: "Claude-Opus-5-5[1m]") == [
                "claude-opus-5-5[1m]", "claude-opus-5-5",
                "anthropic/claude-opus-5-5[1m]", "anthropic/claude-opus-5-5",
                "openai/claude-opus-5-5[1m]", "openai/claude-opus-5-5",
            ])
        #expect(PricingTable.lookupKeys(for: "claude-haiku-4-5-20251001")[1] == "claude-haiku-4-5")
        #expect(PricingTable.lookupKeys(for: "gpt-5.4-2026-03-05")[1] == "gpt-5.4")

        let a = ModelPricing(base: .init(input: 1, output: 1))
        let b = ModelPricing(base: .init(input: 2, output: 2))
        let c = ModelPricing(base: .init(input: 3, output: 3))
        let custom = PricingTable(models: [
            "claude-haiku-4-5": a, "claude-haiku-4-5-20251001": b, "openai/solo-model": c,
        ])
        #expect(custom.pricing(for: "claude-haiku-4-5-20251001") == b)  // exact wins
        #expect(custom.pricing(for: "claude-haiku-4-5-20991231") == a)
        #expect(custom.pricing(for: "claude-haiku-4-5-2099-12-31") == a)
        #expect(custom.pricing(for: "CLAUDE-HAIKU-4-5[1m]") == a)
        #expect(custom.pricing(for: "solo-model") == c)
        #expect(custom.pricing(for: "mystery-model") == nil)
        #expect(custom.pricing(for: "claude-haiku-4-5-2025") == nil)  // not a date
    }

    @Test("a tier applies to the whole request once the prompt exceeds its threshold")
    func tiers() {
        // gpt-6-astra: $10/$50, cached $1; above 272k prompt tokens $20/$75, cached $2.
        let at = TokenCounts(input: 72_000, output: million, cacheRead: 200_000)
        let over = TokenCounts(input: 72_001, output: million, cacheRead: 200_000)
        let base = table.cost(of: record("gpt-6-astra", at, provider: "Codex")) ?? 0
        let tiered = table.cost(of: record("gpt-6-astra", over, provider: "Codex")) ?? 0
        #expect(abs(base - (72_000 * 10e-6 + 50 + 200_000 * 1e-6)) < 1e-9)
        #expect(abs(tiered - (72_001 * 20e-6 + 75 + 200_000 * 2e-6)) < 1e-9)

        // Rates a tier doesn't define keep falling back: highest exceeded
        // tier, then lower tiers, then the base.
        let pricing = ModelPricing(
            base: .init(input: 1, output: 10, cacheRead: 0.1),
            tiers: [
                .init(threshold: 2000, rates: .init(input: 3)),
                .init(threshold: 1000, rates: .init(input: 2, output: 20)),
            ])
        #expect(pricing.cost(TokenCounts(input: 1000, output: 1)) == 1000 + 10)
        #expect(pricing.cost(TokenCounts(input: 1500, output: 1)) == 3000 + 20)
        #expect(pricing.cost(TokenCounts(input: 2500, output: 1, cacheRead: 10)) == 7500 + 20 + 1)
    }

    @Test("missing rates: cache read/write at input, 1h write at the 5m write")
    func missingRateFallbacks() {
        let bare = ModelPricing(base: .init(input: 2, output: 5))
        #expect(bare.cost(TokenCounts(cacheRead: 10)) == 20)
        #expect(bare.cost(TokenCounts(cacheWrite: 10), longCacheWrites: 4) == 20)
        let noLong = ModelPricing(base: .init(input: 2, output: 5, cacheWrite: 3))
        #expect(noLong.cost(TokenCounts(cacheWrite: 10), longCacheWrites: 4) == 30)
        let full = ModelPricing(base: .init(input: 2, output: 5, cacheWrite: 3, cacheWrite1h: 7))
        #expect(full.cost(TokenCounts(cacheWrite: 10), longCacheWrites: 4) == 6 * 3 + 4 * 7)
    }

    @Test("fast mode doubles Opus 5 and 5.5 only")
    func fastMode() {
        let tokens = TokenCounts(input: 1000, output: 1000)
        for model in ["claude-opus-5-5", "claude-opus-5", "claude-opus-5-5[1m]"] {
            let standard = table.cost(of: record(model, tokens)) ?? 0
            let fast = table.cost(of: record(model, tokens, fast: true)) ?? 0
            #expect(standard > 0)
            #expect(abs(fast - 2 * standard) < 1e-12, "\(model)")
        }
        let sonnet = table.cost(of: record("claude-sonnet-5", tokens)) ?? 0
        #expect(table.cost(of: record("claude-sonnet-5", tokens, fast: true)) == sonnet)
    }

    @Test("LiteLLM parsing keeps reachable per-token entries and the fields that matter")
    func parsesLiteLLM() throws {
        let json = """
            {
              "sample_spec": {"input_cost_per_token": "0", "mode": "chat"},
              "model-a": {
                "input_cost_per_token": 1e-06, "output_cost_per_token": 5e-06,
                "cache_read_input_token_cost": 1e-07,
                "cache_creation_input_token_cost": 1.25e-06,
                "cache_creation_input_token_cost_above_1hr": 2e-06,
                "input_cost_per_token_above_200k_tokens": 2e-06,
                "cache_creation_input_token_cost_above_1hr_above_200k_tokens": 4e-06,
                "input_cost_per_token_above_200k_tokens_priority": 9,
                "input_cost_per_token_flex": 9, "output_cost_per_token_batches": 9,
                "supports_vision": true, "max_tokens": 8192
              },
              "openai/model-b": {"input_cost_per_token": 1, "output_cost_per_token": 2},
              "bedrock/us/model-c": {"input_cost_per_token": 1, "output_cost_per_token": 2},
              "vertex_ai/model-d": {"input_cost_per_token": 1, "output_cost_per_token": 2},
              "image-model": {"input_cost_per_image": 0.04}
            }
            """
        let table = try #require(PricingTable.parseLiteLLM(Data(json.utf8), source: .bundled))
        #expect(Set(table.models.keys) == ["model-a", "openai/model-b"])
        let a = try #require(table.models["model-a"])
        #expect(
            a.base
                == .init(
                    input: 1e-06, output: 5e-06, cacheRead: 1e-07, cacheWrite: 1.25e-06,
                    cacheWrite1h: 2e-06))
        #expect(
            a.tiers == [.init(threshold: 200_000, rates: .init(input: 2e-06, cacheWrite1h: 4e-06))])
        #expect(PricingTable.parseLiteLLM(Data("[1,2]".utf8), source: .bundled) == nil)
        #expect(PricingTable.parseLiteLLM(Data("{}".utf8), source: .bundled) == nil)
    }

    @Test("a download overrides the bundle entry by entry and keeps its gaps filled")
    func overlaying() {
        let bundled = PricingTable(models: [
            "a": ModelPricing(base: .init(input: 1, output: 1)),
            "b": ModelPricing(base: .init(input: 2, output: 2)),
        ])
        let fetched = Date(timeIntervalSince1970: 1_790_000_000)
        let download = PricingTable(
            models: ["b": ModelPricing(base: .init(input: 9, output: 9))],
            source: .downloaded(fetched))
        let merged = bundled.overlaying(download)
        #expect(merged.models["a"]?.base.input == 1)
        #expect(merged.models["b"]?.base.input == 9)
        #expect(merged.source == .downloaded(fetched))
    }

    @Test("the cache file is used when valid, the bundle otherwise; refresh is daily")
    func cachedCatalog() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("prices-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("model-prices.json")

        #expect(ModelPriceCatalog.loadCached(from: file).source == .bundled)
        #expect(ModelPriceCatalog.needsRefresh(file: file))

        try Data(#"{"new-model": {"input_cost_per_token": 1, "output_cost_per_token": 2}}"#.utf8)
            .write(to: file)
        let loaded = ModelPriceCatalog.loadCached(from: file)
        #expect(loaded.pricing(for: "new-model") != nil)
        #expect(loaded.pricing(for: "claude-opus-5-5") != nil)  // bundle fills in
        #expect(!ModelPriceCatalog.needsRefresh(file: file))
        #expect(ModelPriceCatalog.needsRefresh(file: file, now: .now.addingTimeInterval(25 * 3600)))

        try Data("<html>rate limited</html>".utf8).write(to: file)
        #expect(ModelPriceCatalog.loadCached(from: file).source == .bundled)
    }
}
