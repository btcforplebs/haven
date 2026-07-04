import SwiftUI

// MARK: - Relay Activity Notification Model
//
// In-app "drop down" banner for relay NOTIFY events (like/reply/repost/zap/mention/DM)
// that arrive while the app is foregrounded — LocalNotificationService suppresses the
// system notification in that case (it can't banner while active), so this is the
// foreground equivalent. Tapping navigates the same place the system notification would.

struct RelayActivityNotification: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let body: String
    let color: Color
    let onTap: () -> Void
}

// MARK: - Relay Activity Notification Manager

@MainActor
final class RelayActivityNotificationManager: ObservableObject {
    static let shared = RelayActivityNotificationManager()
    private init() {}

    @Published var notifications: [RelayActivityNotification] = []

    func show(icon: String, title: String, body: String, color: Color, onTap: @escaping () -> Void) {
        let notification = RelayActivityNotification(icon: icon, title: title, body: body, color: color, onTap: onTap)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            notifications.insert(notification, at: 0)
        }
        // Cap at 3 visible so a burst of activity doesn't fill the screen.
        if notifications.count > 3 {
            withAnimation(.easeOut(duration: 0.4)) {
                notifications = Array(notifications.prefix(3))
            }
        }
        let id = notification.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.4)) {
            notifications.removeAll { $0.id == id }
        }
    }
}

// MARK: - Relay Activity Banner

struct RelayActivityBanner: View {
    @ObservedObject private var manager = RelayActivityNotificationManager.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(manager.notifications) { notification in
                RelayActivityPill(notification: notification) {
                    manager.dismiss(notification.id)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.8))
                ))
            }
        }
        .padding(.top, manager.notifications.isEmpty ? 0 : 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: manager.notifications.map(\.id))
    }
}

// MARK: - Relay Activity Pill

struct RelayActivityPill: View {
    let notification: RelayActivityNotification
    let onDismiss: () -> Void

    var body: some View {
        Button {
            onDismiss()
            notification.onTap()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: notification.icon)
                    .font(.appSystem(size: 15, weight: .bold))

                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.title)
                        .font(.appSystem(size: 13, weight: .bold))
                        .lineLimit(1)
                    if !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.appSystem(size: 12, weight: .regular))
                            .lineLimit(1)
                            .opacity(0.85)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .frame(maxWidth: 340)
            .background(
                Capsule()
                    .fill(notification.color)
                    .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            )
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notification.body.isEmpty ? notification.title : "\(notification.title). \(notification.body)")
    }
}
