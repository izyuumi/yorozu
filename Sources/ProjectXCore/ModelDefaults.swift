import Foundation

/// One model the harness allows, as its metadata reports it. `price` is input plus output price per million tokens,
/// nil when unknown; `inputs` are input kinds ("text", "image"); `runtimes` the agent runtimes that can run it.
public struct ModelInfo: Sendable, Equatable, Codable {
    public var id: String; public var contextTokens: Int?; public var maxOutputTokens: Int?; public var price: Double?
    public var inputs: [String]; public var runtimes: [String]
    public init(id: String, contextTokens: Int? = nil, maxOutputTokens: Int? = nil, price: Double? = nil, inputs: [String] = [], runtimes: [String] = []) {
        self.id = id; self.contextTokens = contextTokens; self.maxOutputTokens = maxOutputTokens; self.price = price; self.inputs = inputs; self.runtimes = runtimes
    }
}
/// A role's model: nil `id` when nothing could be chosen. `allowed` is false only for an explicit choice the harness does not list.
public struct ModelChoice: Sendable, Equatable {
    public var id: String?; public var reason: String; public var allowed = true; public var explicit = false
}
public struct ModelChoices: Sendable, Equatable {
    public var secretary, extraction, worker, review: ModelChoice
}

/// Smart model defaults (#312): pure, recomputed at launch and on every config reload. Explicit choices always win.
public enum ModelDefaults {
    public static func resolve(_ models: [ModelInfo], primary: String?, explicit: Config.Models) -> ModelChoices {
        let rules = explicit.rules, priced = models.filter { $0.price != nil }
        let k = { (n: Int) in n % 1000 == 0 ? "\(n / 1000)k" : "\(n)" }
        /// Most expensive; a model with no output cap is left out (open question 3).
        func top(_ list: [ModelInfo]) -> ModelInfo? { list.filter { $0.maxOutputTokens != nil }.max { ($0.price ?? 0, $0.contextTokens ?? 0, $1.id) < ($1.price ?? 0, $1.contextTokens ?? 0, $0.id) } }
        func pick(_ chosen: String?, _ auto: () -> ModelChoice) -> ModelChoice {
            guard let chosen else { return auto() }
            return ModelChoice(id: chosen, reason: String(localized: "explicit choice"), allowed: models.isEmpty || models.contains { $0.id == chosen }, explicit: true)
        }
        let fallback = ModelChoice(id: primary, reason: primary == nil ? String(localized: "no model metadata and no primary model") : String(localized: "the agent's primary model (no allowed model reports a price and an output cap)"))
        func worker() -> ModelChoice {
            if let primary { return ModelChoice(id: primary, reason: String(localized: "the agent's primary model")) }
            return top(priced).map { ModelChoice(id: $0.id, reason: String(localized: "most expensive allowed model")) } ?? fallback
        }
        func cheap() -> ModelChoice {
            guard !priced.isEmpty else { return fallback }
            let fit = priced.filter { ($0.contextTokens ?? 0) >= rules.minContextTokens && ($0.maxOutputTokens ?? 0) >= rules.minOutputTokens }
            guard let best = fit.min(by: { ($0.price!, $0.id) < ($1.price!, $1.id) }) else { return ModelChoice(id: primary, reason: String(localized: "the agent's primary model (no priced model has ≥ \(k(rules.minContextTokens)) context and ≥ \(k(rules.minOutputTokens)) output)")) }
            return ModelChoice(id: best.id, reason: String(localized: "cheapest allowed model with ≥ \(k(rules.minContextTokens)) context and ≥ \(k(rules.minOutputTokens)) output"))
        }
        let secretary = pick(explicit.secretary, cheap)
        let review = pick(explicit.review) {
            guard let best = top(priced) else { return fallback }
            if let other = top(priced.filter { $0.id != secretary.id }) { return ModelChoice(id: other.id, reason: String(localized: "most expensive allowed model other than the secretary's")) }
            return ModelChoice(id: best.id, reason: String(localized: "most expensive allowed model (no other priced model)"))
        }
        return ModelChoices(secretary: secretary, extraction: pick(explicit.extraction, cheap), worker: pick(explicit.worker, worker), review: review)
    }
}
