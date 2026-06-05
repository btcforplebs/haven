import Foundation
import Combine

@MainActor
class ZapService: ObservableObject {
    static let shared = ZapService()
    
    private init() {}
    
    enum ZapError: Error, LocalizedError {
        case lnurlResolutionFailed
        case invoiceFetchFailed
        case paymentFailed(String)
        case signFailed
        
        var errorDescription: String? {
            switch self {
            case .lnurlResolutionFailed: return "Failed to resolve Lightning Address"
            case .invoiceFetchFailed: return "Failed to fetch invoice from provider"
            case .paymentFailed(let msg): return "Payment failed: \(msg)"
            case .signFailed: return "Failed to sign Zap Request"
            }
        }
    }
    
    /// Executes a full Zap flow: LNURL -> Zap Request -> Invoice -> NWC Payment
    func zapNote(noteId: String, notePubkey: String, lud16: String, amountSats: Int? = nil, message: String = "Zap from Nostr Vault") async throws {
        let amountSats = amountSats ?? (ConfigService.shared.config.defaultZapAmount / 1000)
        guard amountSats > 0 else {
            throw ZapError.paymentFailed("Zap amount must be greater than 0")
        }
        guard amountSats <= 10_000_000 else {
            throw ZapError.paymentFailed("Zap amount exceeds safety limit")
        }
        let amountMsat = amountSats * 1000
        
        let recipientName = NostrService.shared.profiles[notePubkey]?.bestName ?? String(notePubkey.prefix(8))
        let notifId = ZapNotificationManager.shared.addZap(recipientName: recipientName, amountSats: amountSats)
        
        RelayProcessManager.shared.addLog("Zap: Starting zap for \(lud16) (\(amountSats) sats)", level: "INFO")
        
        do {
            // 1. Resolve LNURL — supports both LUD-16 (user@domain.com) and LUD-06 (bech32 lnurl1...)
            let lnurlResponse: LNURLService.LNURLPayResponse
            do {
                if lud16.lowercased().hasPrefix("lnurl:") {
                    // LUD-06: raw bech32-encoded LNURL stored with "lnurl:" sentinel prefix
                    lnurlResponse = try await LNURLService.resolveRawLNURL(lud16)
                } else {
                    // LUD-16: user@domain.com lightning address
                    lnurlResponse = try await LNURLService.resolveAddress(lud16)
                }
            } catch {
                RelayProcessManager.shared.addLog("Zap: LNURL resolution failed: \(error.localizedDescription)", level: "ERROR")
                throw ZapError.lnurlResolutionFailed
            }
            
            // 2. Build Zap Request (Kind 9734)
            // Include external relays so the provider can publish the receipt where it's queryable
            var relayList = [ConfigService.shared.config.nostrURL]
            let externalRelays = ConfigService.shared.config.activeFeedRelays.isEmpty
                ? ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
                : ConfigService.shared.config.activeFeedRelays
            relayList.append(contentsOf: externalRelays)

            var tags: [[String]] = [
                ["p", notePubkey],
                ["relays"] + relayList,
                ["amount", String(amountMsat)]
            ]
            
            if !noteId.isEmpty {
                tags.append(["e", noteId])
            }
            
            // Add lnurl tag — strip internal sentinel prefix if present
            let lnurlTag = lud16.lowercased().hasPrefix("lnurl:") ? String(lud16.dropFirst(6)) : lud16
            tags.append(["lnurl", lnurlTag])
            
            guard let signedZapReq = await NostrService.shared.signEventAsync(kind: 9734, content: message, tags: tags) else {
                RelayProcessManager.shared.addLog("Zap: Failed to sign Zap Request", level: "ERROR")
                throw ZapError.signFailed
            }
            
            // 3. Fetch Invoice
            let invoice: String
            do {
                invoice = try await LNURLService.fetchInvoice(
                    callback: lnurlResponse.callback,
                    amountMsat: amountMsat,
                    zapRequest: signedZapReq
                )
            } catch {
                RelayProcessManager.shared.addLog("Zap: Invoice fetch failed: \(error.localizedDescription)", level: "ERROR")
                throw ZapError.invoiceFetchFailed
            }
            
            // 4. Pay via NWC
            do {
                let preimage = try await NWCService.payInvoice(bolt11: invoice)
                RelayProcessManager.shared.addLog("Zap: Successfully paid! Preimage: \(preimage)", level: "INFO")
                ZapNotificationManager.shared.markSuccess(id: notifId)
            } catch {
                RelayProcessManager.shared.addLog("Zap: NWC Payment failed: \(error.localizedDescription)", level: "ERROR")
                throw ZapError.paymentFailed(error.localizedDescription)
            }
        } catch {
            ZapNotificationManager.shared.markFailed(id: notifId, message: error.localizedDescription)
            throw error
        }
    }
}
