import Foundation
import Testing

@testable import YorozuShared

private func scopedRuleDraft(amount: Double? = 25) -> RuleEditorView.Draft {
    RuleEditorView.Draft(rule: ApprovalRule(
        id: "coffee-cap", actionClass: "purchase", decision: .always,
        scope: ["merchant": ApprovalRuleField(mode: .exact, value: "Coffee shop")],
        maxAmount: amount, currency: "JPY"
    ))
}

@Test(arguments: [-1.0, Double.infinity, -Double.infinity, Double.nan])
func invalidRuleCapsPreventSavingAndExplainWhy(amount: Double) {
    var draft = scopedRuleDraft()
    draft.maxAmount = amount
    #expect(!draft.canSave)
    #expect(draft.validationMessage?.isEmpty == false)
}

@Test(arguments: ["", " \n\t", "not an amount", "12oops", "1e+"])
func invalidAmountTextCannotSilentlyReuseThePreviousCap(text: String) {
    var draft = scopedRuleDraft()
    draft.amountText = text
    #expect(!draft.canSave)
    #expect(draft.validationMessage?.isEmpty == false)
}

@Test func aBlankSelectedScopeCannotSilentlyWidenAnOtherwiseValidRule() {
    var draft = scopedRuleDraft()
    let recipient = draft.fields.firstIndex { $0.id == "recipient" }!
    draft.fields[recipient].isAny = false
    draft.fields[recipient].value = " \n\t"
    #expect(!draft.canSave)
    #expect(draft.validationMessage?.isEmpty == false)

    draft.fields[recipient].value = "home@example.com"
    #expect(draft.canSave)
    #expect(draft.validationMessage == nil)
    #expect(draft.rule.scope?["recipient"]?.value == "home@example.com")
}

@Test func anUnconstrainedRuleExplainsWhyItCannotBeSaved() {
    var draft = scopedRuleDraft()
    for index in draft.fields.indices { draft.fields[index].isAny = true }
    #expect(!draft.canSave)
    #expect(draft.validationMessage?.isEmpty == false)
}

@Test func turningOffAnInvalidCapRestoresAValidScopedRule() {
    var draft = scopedRuleDraft()
    draft.amountText = "not a number"
    #expect(!draft.canSave)
    draft.hasCap = false
    #expect(draft.canSave)
    #expect(draft.validationMessage == nil)
    #expect(draft.rule.maxAmount == nil)
    #expect(draft.rule.currency == "JPY")
}

@Test func zeroCapsAndPreciseExistingCapsRoundTripWithoutChangingAuthority() {
    var draft = scopedRuleDraft(amount: 123.456789123)
    #expect(draft.canSave)
    #expect(draft.rule.maxAmount == 123.456789123)
    draft.maxAmount = 0
    #expect(draft.canSave)
    #expect(draft.validationMessage == nil)
    #expect(draft.rule.maxAmount == 0)
}

@Test func malformedGroupingCannotSilentlyIncreaseAnAmount() {
    guard let grouping = Locale.current.groupingSeparator, !grouping.isEmpty else { return }
    var draft = scopedRuleDraft()
    draft.amountText = "1\(grouping)5"
    #expect(!draft.canSave)
    #expect(draft.validationMessage?.isEmpty == false)
    draft.amountText = "1\(grouping)\(grouping)000"
    #expect(!draft.canSave)
}

@Test func aCorrectlyGroupedPastedAmountKeepsItsValue() {
    guard let grouping = Locale.current.groupingSeparator, !grouping.isEmpty else { return }
    var draft = scopedRuleDraft()
    draft.amountText = "1\(grouping)000"
    #expect(draft.canSave)
    #expect(draft.rule.maxAmount == 1000)
}
