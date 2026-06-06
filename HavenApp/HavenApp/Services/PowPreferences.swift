import Foundation

@MainActor
class PowPreferences: ObservableObject {
    static let shared = PowPreferences()

    nonisolated static let minDifficulty = 8
    nonisolated static let maxDifficulty = 32

    private struct Keys {
        static let noteEnabled = "pow_note_enabled"
        static let noteDifficulty = "pow_note_difficulty"
        static let reactionEnabled = "pow_reaction_enabled"
        static let reactionDifficulty = "pow_reaction_difficulty"
        static let dmEnabled = "pow_dm_enabled"
        static let dmDifficulty = "pow_dm_difficulty"
    }

    @Published var notePowEnabled: Bool {
        didSet { UserDefaults.standard.set(notePowEnabled, forKey: Keys.noteEnabled) }
    }
    @Published var noteDifficulty: Int {
        didSet {
            let clamped = Self.clamp(noteDifficulty)
            if clamped != noteDifficulty { noteDifficulty = clamped; return }
            UserDefaults.standard.set(noteDifficulty, forKey: Keys.noteDifficulty)
        }
    }
    @Published var reactionPowEnabled: Bool {
        didSet { UserDefaults.standard.set(reactionPowEnabled, forKey: Keys.reactionEnabled) }
    }
    @Published var reactionDifficulty: Int {
        didSet {
            let clamped = Self.clamp(reactionDifficulty)
            if clamped != reactionDifficulty { reactionDifficulty = clamped; return }
            UserDefaults.standard.set(reactionDifficulty, forKey: Keys.reactionDifficulty)
        }
    }
    @Published var dmPowEnabled: Bool {
        didSet { UserDefaults.standard.set(dmPowEnabled, forKey: Keys.dmEnabled) }
    }
    @Published var dmDifficulty: Int {
        didSet {
            let clamped = Self.clamp(dmDifficulty)
            if clamped != dmDifficulty { dmDifficulty = clamped; return }
            UserDefaults.standard.set(dmDifficulty, forKey: Keys.dmDifficulty)
        }
    }

    private init() {
        let d = UserDefaults.standard
        self.notePowEnabled = d.object(forKey: Keys.noteEnabled) as? Bool ?? true
        self.noteDifficulty = Self.clamp(d.object(forKey: Keys.noteDifficulty) as? Int ?? 16)
        self.reactionPowEnabled = d.object(forKey: Keys.reactionEnabled) as? Bool ?? true
        self.reactionDifficulty = Self.clamp(d.object(forKey: Keys.reactionDifficulty) as? Int ?? 12)
        self.dmPowEnabled = d.object(forKey: Keys.dmEnabled) as? Bool ?? true
        self.dmDifficulty = Self.clamp(d.object(forKey: Keys.dmDifficulty) as? Int ?? 12)
    }

    nonisolated private static func clamp(_ n: Int) -> Int {
        max(minDifficulty, min(maxDifficulty, n))
    }

    /// Thread-safe snapshot for background use (reads UserDefaults directly).
    nonisolated static func snapshot() -> Snapshot {
        let d = UserDefaults.standard
        return Snapshot(
            noteEnabled: d.object(forKey: Keys.noteEnabled) as? Bool ?? true,
            noteDifficulty: clamp(d.object(forKey: Keys.noteDifficulty) as? Int ?? 16),
            reactionEnabled: d.object(forKey: Keys.reactionEnabled) as? Bool ?? true,
            reactionDifficulty: clamp(d.object(forKey: Keys.reactionDifficulty) as? Int ?? 12),
            dmEnabled: d.object(forKey: Keys.dmEnabled) as? Bool ?? true,
            dmDifficulty: clamp(d.object(forKey: Keys.dmDifficulty) as? Int ?? 12)
        )
    }

    struct Snapshot: Sendable {
        let noteEnabled: Bool
        let noteDifficulty: Int
        let reactionEnabled: Bool
        let reactionDifficulty: Int
        let dmEnabled: Bool
        let dmDifficulty: Int
    }
}
