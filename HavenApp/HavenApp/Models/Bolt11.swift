import Foundation

/// Reading a BOLT-11 invoice's human-readable part.
///
/// Only the amount, which is all the app needs: enough to tell you what a zap
/// was worth, and what you are about to pay before you tap the button.
enum Bolt11 {

    /// What an invoice says it is worth.
    enum Amount: Equatable {
        /// At least one whole sat.
        case sats(Int)
        /// A well-formed invoice that names no amount you could show — either
        /// an amountless invoice ("pay me what you like") or one worth less
        /// than a sat.
        case unspecified
        /// Not a BOLT-11 invoice, or not one we can read.
        case unreadable
    }

    /// 1 BTC = 100_000_000_000 msat.
    private static let msatPerBTC = 100_000_000_000

    static func amount(_ invoice: String) -> Amount {
        let lower = invoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // The bech32 data charset excludes `1`, so the last `1` is the
        // separator — unambiguously. Reading digits forward from the network
        // prefix instead turns an amountless invoice's separator into an
        // amount, whose size is then decided by the first character of the
        // payload: `lnbc1qqq…` reads as 1 BTC, `lnbc1u3q…` as 100 sats.
        guard let separator = lower.lastIndex(of: "1"),
              lower.index(after: separator) < lower.endIndex
        else { return .unreadable }

        let hrp = lower[lower.startIndex..<separator]
        guard let network = ["lnbcrt", "lnbc", "lntbs", "lntb"].first(where: { hrp.hasPrefix($0) })
        else { return .unreadable }

        var rest = hrp[hrp.index(hrp.startIndex, offsetBy: network.count)...]
        let digits = rest.prefix(while: \.isNumber)
        rest = rest.dropFirst(digits.count)
        // No digits is an amountless invoice; more than one trailing character
        // is not a multiplier.
        guard rest.count <= 1 else { return .unreadable }
        guard !digits.isEmpty else { return .unspecified }
        // Digits that will not fit an Int are junk, not an amountless invoice.
        guard let value = Int(digits) else { return .unreadable }

        let perUnit: Int
        switch rest.first {
        case "m": perUnit = msatPerBTC / 1_000
        case "u": perUnit = msatPerBTC / 1_000_000
        case "n": perUnit = msatPerBTC / 1_000_000_000
        // Pico-BTC is a tenth of a msat; a valid pico amount is a multiple of 10.
        case "p": return sats(msat: value / 10)
        case nil: perUnit = msatPerBTC
        default: return .unreadable
        }

        // Reported rather than `*`, which traps: the digit run comes off the
        // wire and nothing upstream bounds its length.
        let (msat, overflowed) = value.multipliedReportingOverflow(by: perUnit)
        guard !overflowed else { return .unreadable }
        return sats(msat: msat)
    }

    /// Sats, or nil for anything that does not state at least one.
    static func sats(_ invoice: String) -> Int? {
        if case .sats(let n) = amount(invoice) { return n }
        return nil
    }

    private static func sats(msat: Int) -> Amount {
        // 21 million BTC is the whole supply; at or past it the invoice is junk.
        guard msat >= 1_000 else { return .unspecified }
        guard msat < 21_000_000 * msatPerBTC else { return .unreadable }
        return .sats(msat / 1_000)
    }
}
