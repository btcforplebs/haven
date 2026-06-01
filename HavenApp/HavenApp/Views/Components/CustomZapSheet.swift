import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Zap Sheet Context

struct ZapSheetContext: Identifiable {
    let id = UUID()
    let defaultAmount: Int // in sats
}

// MARK: - Custom Zap Sheet

struct CustomZapSheet: View {
    let defaultAmount: Int
    let onZap: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAmount: Int = 0
    @State private var customAmountText: String = ""
    @State private var isCustomActive: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    private let presetAmounts: [(sats: Int, label: String)] = [
        (21, "21"), (100, "100"), (500, "500"), (1_000, "1K"),
        (5_000, "5K"), (10_000, "10K"), (50_000, "50K")
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var effectiveAmount: Int {
        if isCustomActive, let custom = Int(customAmountText), custom > 0 {
            return custom
        }
        return selectedAmount
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Rectangle()
                .fill(Color.platformSeparator.opacity(0.5))
                .frame(height: 0.5)

            presetGrid
                .padding(.horizontal, 20)
                .padding(.top, 20)

            customAmountField
                .padding(.horizontal, 20)
                .padding(.top, 14)

            zapButton
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        .onAppear {
            selectedAmount = defaultAmount
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.orange)
                .shadow(color: .orange.opacity(0.6), radius: 8)

            Text("Zap Amount")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Preset Grid

    private var presetGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(presetAmounts, id: \.sats) { preset in
                let isSelected = selectedAmount == preset.sats && !isCustomActive
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        selectedAmount = preset.sats
                        isCustomActive = false
                        customAmountText = ""
                        isTextFieldFocused = false
                    }
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                } label: {
                    Text(preset.label)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            isSelected
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [.orange, .orange.opacity(0.7)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                  )
                                : AnyShapeStyle(Color.platformTertiaryGroupedBackground)
                        )
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    isSelected
                                        ? Color.orange.opacity(0.8)
                                        : Color.platformSeparator,
                                    lineWidth: isSelected ? 1.5 : 0.8
                                )
                        )
                        .shadow(
                            color: isSelected ? Color.orange.opacity(0.3) : .clear,
                            radius: 6
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(preset.sats) sats")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: - Custom Amount Field

    private var customAmountField: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.line")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isCustomActive ? .orange : .secondary)

            TextField("Custom amount", text: $customAmountText)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .textFieldStyle(.plain)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .focused($isTextFieldFocused)
                .onChange(of: customAmountText) { _, newValue in
                    let filtered = newValue.filter { $0.isNumber }
                    if filtered != newValue { customAmountText = filtered }
                    isCustomActive = !filtered.isEmpty
                }

            Text("sats")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isCustomActive ? Color.orange.opacity(0.6) : Color.platformSeparator,
                    lineWidth: isCustomActive ? 1.5 : 0.8
                )
        )
    }

    // MARK: - Zap Button

    private var zapButton: some View {
        Button {
            guard effectiveAmount > 0 else { return }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            #endif
            onZap(effectiveAmount)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .bold))
                Text("Zap \(effectiveAmount > 0 ? formatSats(effectiveAmount) : "---") sats")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(
                    colors: effectiveAmount > 0
                        ? [.orange, Color(red: 0.95, green: 0.55, blue: 0.1)]
                        : [Color.secondary.opacity(0.3), Color.secondary.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(14)
            .shadow(
                color: effectiveAmount > 0 ? .orange.opacity(0.35) : .clear,
                radius: 10, x: 0, y: 4
            )
        }
        .buttonStyle(.plain)
        .disabled(effectiveAmount <= 0)
    }

    private func formatSats(_ sats: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }
}
