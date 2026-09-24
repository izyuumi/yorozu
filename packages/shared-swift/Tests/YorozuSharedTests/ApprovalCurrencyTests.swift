import Foundation
import Testing

@testable import YorozuShared

@Test func approvalAmountUsesTransactionCurrencyAcrossLocales() {
    #expect(ApprovalAmountFormatter.string(amount: 12.5, currency: "USD", locale: Locale(identifier: "ja_JP")) == "USD 12.50")
    #expect(ApprovalAmountFormatter.string(amount: 1200, currency: "JPY", locale: Locale(identifier: "en_US")) == "JPY 1,200")
}

@Test func approvalLegacyAmountDoesNotInventCurrency() throws {
    let json = Data(#"{"actionId":"old","actionClass":"purchase","target":"Book","amount":12.5}"#.utf8)
    let card = try JSONDecoder().decode(ApprovalCardData.self, from: json)
    #expect(card.currency == nil)
    let amount = try #require(card.amount)
    #expect(ApprovalAmountFormatter.string(amount: amount, currency: card.currency, locale: Locale(identifier: "en_US")) == "12.5 (currency unspecified)")
    #expect(ApprovalAmountFormatter.string(amount: 12.5, currency: "invalid", locale: Locale(identifier: "ja_JP")) == "12.5 (currency unspecified)")
}

@Test func approvalRuleEditorPreservesTransactionCurrency() throws {
    let rule = ApprovalRule(id: "usd-cap", actionClass: "purchase", decision: .always,
                            scope: ["merchant": ApprovalRuleField(mode: .exact, value: "Bookshop")],
                            maxAmount: 25, currency: "USD")
    let card = ApprovalCardData(actionId: "usd-card", actionClass: "purchase", target: "Bookshop",
                                amount: 25, currency: "USD", suggestedRule: rule)
    let decodedCard = try JSONDecoder().decode(ApprovalCardData.self, from: JSONEncoder().encode(card))
    #expect(decodedCard.currency == "USD")
    #expect(decodedCard.suggestedRule?.currency == "USD")
    var draft = RuleEditorView.Draft(rule: rule)
    draft.maxAmount = 30
    let edited = draft.rule
    #expect(edited.maxAmount == 30)
    #expect(edited.currency == "USD")
    let roundTripped = try JSONDecoder().decode(ApprovalRule.self, from: JSONEncoder().encode(edited))
    #expect(roundTripped.currency == "USD")
    draft.hasCap = false
    #expect(draft.rule.maxAmount == nil)
    #expect(draft.rule.currency == "USD")
}

@Test func approvalRuleSummaryExplainsCurrencyWithoutAmountCap() {
    let rule = ApprovalRule(id: "usd-only", actionClass: "purchase", decision: .always,
                            scope: ["merchant": ApprovalRuleField(mode: .exact, value: "Bookshop")],
                            currency: "USD")
    #expect(rule.summary.contains(" in USD"))
}
