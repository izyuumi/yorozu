import Foundation

/// Transaction units come from the action; the device locale only controls number formatting.
public enum ApprovalAmountFormatter {
    public static func string(amount: Double, currency: String?, locale: Locale = .current) -> String {
        let code = currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let code, Locale.commonISOCurrencyCodes.contains(code) else {
            return String(localized: "\(amount.formatted(.number.locale(locale))) (currency unspecified)")
        }
        // Read ISO minor-unit precision from Foundation, while always displaying the ISO code
        // explicitly: a bare dollar symbol is ambiguous even when the numeric value is correct.
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        let digits = formatter.maximumFractionDigits
        let number = amount.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        return "\(code) \(number)"
    }
}
