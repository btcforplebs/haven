import SwiftUI

struct ActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                } else {
                    Image(systemName: icon)
                        .font(.appSystem(size: 20, weight: .medium))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.appSystem(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleDark]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .shadow(color: Color.havenPurple.opacity(isHovered ? 0.35 : 0.0), radius: 8, x: 0, y: 4)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
