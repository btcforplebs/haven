import SwiftUI

// MARK: - Error Notification Model

struct ErrorNotification: Identifiable {
    let id = UUID()
    let message: String
    let icon: String

    enum Style { case error, warning }
    let style: Style
}

// MARK: - Error Notification Manager

@MainActor
class ErrorNotificationManager: ObservableObject {
    static let shared = ErrorNotificationManager()

    @Published var notifications: [ErrorNotification] = []

    func show(_ message: String, icon: String = "exclamationmark.triangle.fill", style: ErrorNotification.Style = .error) {
        let notification = ErrorNotification(message: message, icon: icon, style: style)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            notifications.insert(notification, at: 0)
        }
        // Cap at 3 visible
        if notifications.count > 3 {
            withAnimation(.easeOut(duration: 0.4)) {
                notifications = Array(notifications.prefix(3))
            }
        }
        let id = notification.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            withAnimation(.easeOut(duration: 0.4)) {
                self?.notifications.removeAll { $0.id == id }
            }
        }
    }
}

// MARK: - Error Notification Banner

struct ErrorNotificationBanner: View {
    @ObservedObject private var manager = ErrorNotificationManager.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(manager.notifications) { notification in
                ErrorPill(notification: notification)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.8))
                    ))
            }
        }
        .padding(.top, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: manager.notifications.map(\.id))
    }
}

// MARK: - Error Pill

struct ErrorPill: View {
    let notification: ErrorNotification

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notification.icon)
                .font(.appSystem(size: 12, weight: .bold))
            Text(notification.message)
                .font(.appSystem(size: 13, weight: .bold))
                .lineLimit(2)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(
            Capsule()
                .fill(notification.style == .error ? Color.red.opacity(0.85) : Color.orange.opacity(0.85))
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notification.message)
    }
}
