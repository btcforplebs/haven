import SwiftUI

// MARK: - Stats Section

struct StatsSection: View {
    let stats: BlossomStats
    let isLoading: Bool

    var body: some View {
        let columns = [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ]

        LazyVGrid(columns: columns, spacing: 12) {
            UnifiedStatCard(
                title: "Total Files",
                value: isLoading ? "..." : "\(stats.totalFiles)",
                icon: "photo.on.rectangle",
                color: .blue
            )

            UnifiedStatCard(
                title: "Storage Used",
                value: isLoading ? "..." : stats.formattedSize,
                icon: "internaldrive.fill",
                color: .havenPurple
            )

            UnifiedStatCard(
                title: "Active Mirrors",
                value: isLoading ? "..." : "\(stats.mirrorCount)",
                icon: "server.rack",
                color: .green
            )

            UnifiedStatCard(
                title: "Backed Up",
                value: isLoading ? "..." : "\(stats.backupPercentage)%",
                icon: "checkmark.seal.fill",
                color: stats.backupPercentage == 100 ? .green : .orange
            )
        }
    }
}

// MARK: - Unified Stat Card

struct UnifiedStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: { action?() }) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(color)

                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.platformSecondaryGroupedBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

// MARK: - Quick Actions Section

struct QuickActionsSection: View {
    let stats: BlossomStats
    @Binding var isPulling: Bool
    @Binding var isPushing: Bool
    let syncProgress: Double
    let syncMessage: String
    let onPull: () -> Void
    let onPush: () -> Void
    let onRefresh: () -> Void

    var needsBackupCount: Int {
        stats.totalFiles - stats.backedUpCount
    }

    var body: some View {
        VStack(spacing: 12) {
            let columns = [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ]

            LazyVGrid(columns: columns, spacing: 10) {
                UnifiedActionButton(
                    icon: "arrow.down.circle",
                    title: "Pull",
                    isLoading: isPulling,
                    action: onPull
                )

                UnifiedActionButton(
                    icon: "arrow.up.circle",
                    title: needsBackupCount > 0 ? "Backup \(needsBackupCount)" : "100% Backed Up",
                    isLoading: isPushing,
                    action: onPush
                )
                .disabled(needsBackupCount == 0)

                UnifiedActionButton(
                    icon: "arrow.clockwise",
                    title: "Refresh",
                    action: onRefresh
                )
            }

            // Inline progress
            if isPulling || isPushing {
                VStack(spacing: 4) {
                    ProgressView(value: syncProgress)
                        .tint(.havenPurple)

                    Text(syncMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.platformSecondaryGroupedBackground)
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - Unified Action Button

struct UnifiedActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.havenPurple)
                }

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .background(Color.platformSecondaryGroupedBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(isHovered ? 0.12 : 0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))

            Spacer()

            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(actionTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.havenPurple)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.havenPurple.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
