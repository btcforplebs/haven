//
//  StarterPack.swift
//  HavenApp
//
//  Data models for curated starter account packs
//

import Foundation

struct StarterPacksData: Codable {
    let packs: [StarterPack]
}

struct StarterPack: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let accounts: [RecommendedAccount]
}

struct RecommendedAccount: Codable, Identifiable {
    let npub: String
    let name: String
    let about: String
    let picture: String

    var id: String { npub }
}

extension StarterPacksData {
    /// Drops accounts whose npub is not well-formed, and any pack left empty.
    ///
    /// An account with a bad npub cannot be followed — the p-tag it would
    /// produce is rejected before publication — so offering it in the picker
    /// only lets someone select a name and get nothing. Two of the shipped
    /// entries are in that state today.
    func validated() -> StarterPacksData {
        let cleaned = packs.compactMap { pack -> StarterPack? in
            let accounts = pack.accounts.filter {
                NpubValidation.hexPubkey(fromNpub: $0.npub) != nil
            }
            guard !accounts.isEmpty else { return nil }
            return StarterPack(id: pack.id, name: pack.name, description: pack.description, accounts: accounts)
        }
        return StarterPacksData(packs: cleaned)
    }

    static func load() -> StarterPacksData? {
        guard let url = Bundle.main.url(forResource: "starter_packs", withExtension: "json") else {
            print("StarterPacks: Could not find starter_packs.json in bundle")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(StarterPacksData.self, from: data)
            print("StarterPacks: Loaded \(decoded.packs.count) packs")
            return decoded
        } catch {
            print("StarterPacks: Failed to load/decode: \(error)")
            return nil
        }
    }
}
