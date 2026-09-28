// Generated from LiteLLM's model_prices_and_context_window.json (snapshot 2026-09-27).
// Regenerate rather than edit by hand: values are USD per token, copied verbatim.

extension PricingTable {
    /// The offline fallback: prices for the models these logs actually contain,
    /// so the Cost tab works on first launch before (or without) a download.
    /// A downloaded table takes precedence entry by entry; this only fills gaps.
    static let bundledModels: [String: ModelPricing] = [
        "claude-fable-5-1": ModelPricing(
            base: .init(
                input: 1e-05, output: 5e-05, cacheRead: 2.5e-07, cacheWrite: 1.25e-05,
                cacheWrite1h: 2e-05)),
        "claude-opus-5-5": ModelPricing(
            base: .init(
                input: 4e-06, output: 2e-05, cacheRead: 2e-07, cacheWrite: 5e-06,
                cacheWrite1h: 8e-06)),
        "claude-sonnet-5": ModelPricing(
            base: .init(
                input: 2e-06, output: 1e-05, cacheRead: 2e-07, cacheWrite: 2.5e-06,
                cacheWrite1h: 4e-06)),
        "claude-opus-5": ModelPricing(
            base: .init(
                input: 5e-06, output: 2.5e-05, cacheRead: 5e-07, cacheWrite: 6.25e-06,
                cacheWrite1h: 1e-05)),
        "claude-opus-4-8": ModelPricing(
            base: .init(
                input: 5e-06, output: 2.5e-05, cacheRead: 5e-07, cacheWrite: 6.25e-06,
                cacheWrite1h: 1e-05)),
        "claude-fable-5": ModelPricing(
            base: .init(
                input: 1e-05, output: 5e-05, cacheRead: 1e-06, cacheWrite: 1.25e-05,
                cacheWrite1h: 2e-05)),
        "claude-opus-4-7": ModelPricing(
            base: .init(
                input: 5e-06, output: 2.5e-05, cacheRead: 5e-07, cacheWrite: 6.25e-06,
                cacheWrite1h: 1e-05)),
        "claude-haiku-4-5-20251001": ModelPricing(
            base: .init(
                input: 1e-06, output: 5e-06, cacheRead: 1e-07, cacheWrite: 1.25e-06,
                cacheWrite1h: 2e-06)),
        "claude-opus-4-6": ModelPricing(
            base: .init(
                input: 5e-06, output: 2.5e-05, cacheRead: 5e-07, cacheWrite: 6.25e-06,
                cacheWrite1h: 1e-05)),
        "claude-sonnet-4-6": ModelPricing(
            base: .init(
                input: 3e-06, output: 1.5e-05, cacheRead: 3e-07, cacheWrite: 3.75e-06,
                cacheWrite1h: 6e-06)),
        "claude-haiku-4-5": ModelPricing(
            base: .init(
                input: 1e-06, output: 5e-06, cacheRead: 1e-07, cacheWrite: 1.25e-06,
                cacheWrite1h: 2e-06)),
        "gpt-6-astra": ModelPricing(
            base: .init(input: 1e-05, output: 5e-05, cacheRead: 1e-06, cacheWrite: 1.25e-05),
            tiers: [
                .init(
                    threshold: 272000,
                    rates: .init(
                        input: 2e-05, output: 7.5e-05, cacheRead: 2e-06, cacheWrite: 2.5e-05))
            ]),
        "gpt-5.6-sol": ModelPricing(
            base: .init(input: 4e-06, output: 2e-05, cacheRead: 4e-07, cacheWrite: 5e-06),
            tiers: [
                .init(
                    threshold: 272000,
                    rates: .init(input: 8e-06, output: 3e-05, cacheRead: 8e-07, cacheWrite: 1e-05))
            ]),
        "gpt-5.5": ModelPricing(
            base: .init(input: 5e-06, output: 3e-05, cacheRead: 5e-07),
            tiers: [
                .init(
                    threshold: 272000, rates: .init(input: 1e-05, output: 4.5e-05, cacheRead: 1e-06)
                )
            ]),
        "gpt-6-sol": ModelPricing(
            base: .init(input: 2e-06, output: 1e-05, cacheRead: 2e-07, cacheWrite: 2.5e-06),
            tiers: [
                .init(
                    threshold: 272000,
                    rates: .init(input: 4e-06, output: 1.5e-05, cacheRead: 4e-07, cacheWrite: 5e-06)
                )
            ]),
        "gpt-5.6-terra": ModelPricing(
            base: .init(input: 2e-06, output: 1.2e-05, cacheRead: 2e-07, cacheWrite: 2.5e-06),
            tiers: [
                .init(
                    threshold: 272000,
                    rates: .init(input: 4e-06, output: 1.8e-05, cacheRead: 4e-07, cacheWrite: 5e-06)
                )
            ]),
        "gpt-5.6-luna": ModelPricing(
            base: .init(input: 2e-07, output: 1.2e-06, cacheRead: 2e-08, cacheWrite: 2.5e-07),
            tiers: [
                .init(
                    threshold: 272000,
                    rates: .init(input: 4e-07, output: 1.8e-06, cacheRead: 4e-08, cacheWrite: 5e-07)
                )
            ]),
        "gpt-5": ModelPricing(
            base: .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07)),
        "gpt-5-codex": ModelPricing(
            base: .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07)),
        "gpt-5.1-codex": ModelPricing(
            base: .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07)),
        "gpt-5.4": ModelPricing(
            base: .init(input: 2.5e-06, output: 1.5e-05, cacheRead: 2.5e-07),
            tiers: [
                .init(
                    threshold: 272000,
                    rates: .init(input: 5e-06, output: 2.25e-05, cacheRead: 5e-07))
            ]),
        "gpt-5.4-mini": ModelPricing(
            base: .init(input: 7.5e-07, output: 4.5e-06, cacheRead: 7.5e-08)),
        "gpt-5.3-codex": ModelPricing(
            base: .init(input: 1.75e-06, output: 1.4e-05, cacheRead: 1.75e-07)),
        "claude-opus-4-5": ModelPricing(
            base: .init(
                input: 5e-06, output: 2.5e-05, cacheRead: 5e-07, cacheWrite: 6.25e-06,
                cacheWrite1h: 1e-05)),
        "claude-sonnet-4-5": ModelPricing(
            base: .init(
                input: 3e-06, output: 1.5e-05, cacheRead: 3e-07, cacheWrite: 3.75e-06,
                cacheWrite1h: 6e-06),
            tiers: [
                .init(
                    threshold: 200000,
                    rates: .init(
                        input: 6e-06, output: 2.25e-05, cacheRead: 6e-07, cacheWrite: 7.5e-06,
                        cacheWrite1h: 1.2e-05))
            ]),
    ]
}
