import SwiftUI

struct ProofOfWorkSettingsView: View {
    @ObservedObject private var prefs = PowPreferences.shared

    var body: some View {
        Form {
            Section {
                Text("Proof of Work mines a hash prefix on your events, acting as a spam deterrent. Higher difficulty takes longer but signals more effort.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Enable for notes", isOn: $prefs.notePowEnabled)
                if prefs.notePowEnabled {
                    Stepper("Difficulty: \(prefs.noteDifficulty) bits",
                            value: $prefs.noteDifficulty,
                            in: PowPreferences.minDifficulty...PowPreferences.maxDifficulty)
                }
            } header: {
                Text("Notes & Replies")
            }

            Section {
                Toggle("Enable for reactions", isOn: $prefs.reactionPowEnabled)
                if prefs.reactionPowEnabled {
                    Stepper("Difficulty: \(prefs.reactionDifficulty) bits",
                            value: $prefs.reactionDifficulty,
                            in: PowPreferences.minDifficulty...PowPreferences.maxDifficulty)
                }
            } header: {
                Text("Reactions")
            }

            Section {
                Toggle("Enable for DMs", isOn: $prefs.dmPowEnabled)
                if prefs.dmPowEnabled {
                    Stepper("Difficulty: \(prefs.dmDifficulty) bits",
                            value: $prefs.dmDifficulty,
                            in: PowPreferences.minDifficulty...PowPreferences.maxDifficulty)
                }
            } header: {
                Text("Direct Messages")
            }
        }
        #if os(iOS)
        .navigationTitle("Proof of Work")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
