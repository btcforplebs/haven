//
//  InitialFollowsStepView.swift
//  HavenApp
//
//  Initial follows step for new user onboarding
//

import SwiftUI

struct InitialFollowsStepView: View {
    let onContinue: ([String]) -> Void
    let onSkip: () -> Void

    @State private var packsData: StarterPacksData?
    @State private var expandedPackId: String?
    @State private var selectedNpubs: Set<String> = []
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            // Header
            VStack(spacing: 8) {
                Text("Discover Accounts")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(WizardColors.textPrimary)

                Text("Following accounts helps personalize your feed. Select any that interest you, or skip to explore on your own.")
                    .font(.system(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            ScrollView {
                VStack(spacing: 12) {
                    if let packs = packsData?.packs {
                        ForEach(packs) { pack in
                            PackCard(
                                pack: pack,
                                isExpanded: expandedPackId == pack.id,
                                selectedNpubs: $selectedNpubs,
                                onToggleExpand: {
                                    withAnimation(Motion.pop) {
                                        expandedPackId = expandedPackId == pack.id ? nil : pack.id
                                    }
                                }
                            )
                        }
                    } else {
                        Text("No packs available")
                            .foregroundColor(WizardColors.textMuted)
                    }
                }
                .padding(.vertical, 8)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(WizardAnimations.springEnter.delay(0.2), value: appeared)

            // Selected count badge
            if !selectedNpubs.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(WizardColors.accentPrimary)
                    Text("\(selectedNpubs.count) account\(selectedNpubs.count == 1 ? "" : "s") selected")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(WizardColors.bgCard)
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(WizardColors.borderActive, lineWidth: 1)
                )
                .transition(.scale.combined(with: .opacity))
            }

            // Buttons
            VStack(spacing: 12) {
                WizardPrimaryButton(
                    title: selectedNpubs.isEmpty ? "Skip for Now" : "Follow \(selectedNpubs.count)",
                    action: {
                        if selectedNpubs.isEmpty {
                            onSkip()
                        } else {
                            onContinue(Array(selectedNpubs))
                        }
                    }
                )

                if !selectedNpubs.isEmpty {
                    Button(action: onSkip) {
                        Text("Skip and don't follow")
                            .font(.system(size: 14))
                            .foregroundColor(WizardColors.textMuted)
                    }
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(WizardAnimations.springEnter.delay(0.3), value: appeared)

            Spacer()
        }
        .onAppear {
            appeared = true
            packsData = StarterPacksData.load()
        }
    }
}

private struct PackCard: View {
    let pack: StarterPack
    let isExpanded: Bool
    @Binding var selectedNpubs: Set<String>
    let onToggleExpand: () -> Void

    var body: some View {
        WizardGlassCard(isSelected: false) {
            VStack(alignment: .leading, spacing: 12) {
                // Pack header
                Button(action: onToggleExpand) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pack.name)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(WizardColors.textPrimary)

                            Text(pack.description)
                                .font(.system(size: 13))
                                .foregroundColor(WizardColors.textSecondary)
                                .lineSpacing(2)
                        }

                        Spacer()

                        VStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(WizardColors.accentPrimary)

                            Text("\(pack.accounts.count)")
                                .font(.system(size: 11))
                                .foregroundColor(WizardColors.textMuted)
                        }
                    }
                }
                .buttonStyle(.plain)

                // Expanded accounts list
                if isExpanded {
                    VStack(spacing: 8) {
                        ForEach(pack.accounts) { account in
                            AccountRow(
                                account: account,
                                isSelected: selectedNpubs.contains(account.npub),
                                onToggle: {
                                    withAnimation(Motion.pop) {
                                        if selectedNpubs.contains(account.npub) {
                                            selectedNpubs.remove(account.npub)
                                        } else {
                                            selectedNpubs.insert(account.npub)
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

private struct AccountRow: View {
    let account: RecommendedAccount
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Checkbox
                ZStack {
                    Circle()
                        .fill(isSelected ? WizardColors.accentPrimary : WizardColors.bgElevated)
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Circle()
                            .stroke(WizardColors.borderSubtle, lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                }

                // Account info
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)

                    Text(account.about)
                        .font(.system(size: 12))
                        .foregroundColor(WizardColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(10)
            .background(isSelected ? WizardColors.bgCard : WizardColors.bgElevated)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? WizardColors.borderActive : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
