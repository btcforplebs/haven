import Foundation

/// Pure parsing for a live stream's chat (NIP-53 kind 1311) and the zap
/// receipts (NIP-57 kind 9735) that are addressed to the same stream.
///
/// Kept free of SwiftUI and Combine so `MediaLogicTests` can compile it: the
/// awkward parts here — a zap receipt is signed by the *provider*, not the
/// person who paid, and half of them omit the amount tag — are exactly the
/// parts worth testing without a running app.

/// One row in the chat column.
struct LiveChatMessage: Identifiable, Equatable {
    enum Payload: Equatable {
        case chat
        /// Amount in sats. Zero means the receipt carried no amount we could read.
        case zap(sats: Int)
    }

    let id: String
    /// The person to attribute the row to. For a zap that is the payer taken
    /// from the embedded request, never the receipt's own pubkey.
    let authorPubkey: String
    let createdAt: Int64
    let text: String
    let payload: Payload

    var isZap: Bool { if case .zap = payload { return true }; return false }
    var zapSats: Int? { if case .zap(let sats) = payload { return sats }; return nil }
}

enum LiveChat {
    /// Where live events and their chat live, and the relay hint every chat
    /// message and stream zap carries so other clients know where to look.
    static let streamRelay = "wss://relay.zap.stream"

    /// The `a` tag every chat message and stream zap is addressed to.
    static func address(hostPubkey: String, identifier: String) -> String {
        "30311:\(hostPubkey):\(identifier)"
    }

    /// Who a zap for this stream should pay.
    ///
    /// NIP-53 lets the event be published by a service on the host's behalf
    /// (zap.stream does exactly this), with the real host carried as a `p` tag
    /// tagged `Host`. Paying the author in that case pays the service.
    static func hostPubkey(authorPubkey: String, tags: [[String]]) -> String {
        let host = tags.first { tag in
            tag.count >= 4 && tag[0] == "p" && tag[3].lowercased() == "host" && !tag[1].isEmpty
        }
        return host?[1] ?? authorPubkey
    }

    /// Builds a row from a relay event, or nil if it is not one we render.
    static func message(id: String, pubkey: String, kind: Int, createdAt: Int64,
                        content: String, tags: [[String]]) -> LiveChatMessage? {
        guard !id.isEmpty else { return nil }

        if kind == 1311 {
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LiveChatMessage(id: id, authorPubkey: pubkey, createdAt: createdAt,
                                   text: text, payload: .chat)
        }

        guard kind == 9735 else { return nil }

        let request = zapRequest(from: tags)
        // The receipt is signed by the LNURL provider. The payer is in the
        // embedded request; NIP-57's optional `P` tag is the only other place
        // it appears, and plenty of providers set neither.
        let payer = request?.pubkey
            ?? tags.first { $0.count >= 2 && $0[0] == "P" && !$0[1].isEmpty }?[1]
            ?? pubkey
        let sats = zapAmountSats(receiptTags: tags, requestTags: request?.tags ?? [])
        let comment = (request?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveChatMessage(id: id, authorPubkey: payer, createdAt: createdAt,
                               text: comment, payload: .zap(sats: sats))
    }

    /// Amount in sats, read from the request's `amount` tag, then the receipt's
    /// own, then the invoice itself. zap.stream receipts routinely carry only
    /// the bolt11, so without the last rung most stream zaps render as "0".
    static func zapAmountSats(receiptTags: [[String]], requestTags: [[String]]) -> Int {
        func msats(_ tags: [[String]]) -> Int? {
            guard let raw = tags.first(where: { $0.count >= 2 && $0[0] == "amount" })?[1],
                  let value = Int(raw), value > 0 else { return nil }
            return value
        }
        if let msat = msats(requestTags) ?? msats(receiptTags) { return msat / 1000 }
        if let bolt11 = receiptTags.first(where: { $0.count >= 2 && $0[0] == "bolt11" })?[1] {
            return satsFromBolt11(bolt11) ?? 0
        }
        return 0
    }

    /// BOLT-11 encodes the amount in its human-readable part: `lnbc2500u1…` is
    /// 2500 micro-BTC, i.e. 250,000 sats. An amountless invoice has no digits.
    static func satsFromBolt11(_ invoice: String) -> Int? {
        let lower = invoice.lowercased()
        guard let prefixRange = ["lnbcrt", "lnbc", "lntbs", "lntb"]
            .first(where: { lower.hasPrefix($0) })
            .map({ lower.index(lower.startIndex, offsetBy: $0.count) })
        else { return nil }

        var digits = ""
        var index = prefixRange
        while index < lower.endIndex, lower[index].isNumber {
            digits.append(lower[index])
            index = lower.index(after: index)
        }
        guard !digits.isEmpty, let value = Double(digits) else { return nil }

        let multiplier: Double
        switch index < lower.endIndex ? lower[index] : " " {
        case "m": multiplier = 1e-3
        case "u": multiplier = 1e-6
        case "n": multiplier = 1e-9
        case "p": multiplier = 1e-12
        default: multiplier = 1  // whole BTC
        }

        let sats = value * multiplier * 100_000_000
        guard sats >= 1, sats < 21_000_000 * 100_000_000 else { return nil }
        return Int(sats.rounded())
    }

    // MARK: - Private

    private struct ZapRequest {
        let pubkey: String
        let content: String
        let tags: [[String]]
    }

    /// The zap request lives as JSON inside the receipt's `description` tag.
    private static func zapRequest(from receiptTags: [[String]]) -> ZapRequest? {
        guard let description = receiptTags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
              !description.isEmpty else { return nil }

        func parse(_ text: String) -> [String: Any]? {
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        // Some providers copy the request through a channel that leaves raw
        // control characters in the string, which JSONSerialization rejects.
        let json = parse(description) ?? parse(String(description.unicodeScalars.filter {
            $0.value >= 0x20 || $0 == "\n" || $0 == "\t"
        }))

        guard let json,
              let pubkey = json["pubkey"] as? String, !pubkey.isEmpty else { return nil }
        return ZapRequest(pubkey: pubkey,
                          content: json["content"] as? String ?? "",
                          tags: json["tags"] as? [[String]] ?? [])
    }
}
