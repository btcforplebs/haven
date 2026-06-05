import SwiftUI

// MARK: - BlossomDashboardView

/// Fast-loading Blossom dashboard with stats, mirror management, and media grid.
/// All operations are inline with no blocking popups.
struct BlossomDashboardView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.dismiss) private var dismiss

    @State private var stats = BlossomStats()
    @State private var mirrors: [MirrorInfo] = []
    @State private var isLoadingStats = true
    @State private var showMirrorSection = false
    @State private var showingBlossomSettings = false

    // Sync operations
    @State private var isPulling = false
    @State private var isPushing = false
    @State private var syncProgress: Double = 0
    @State private var syncMessage: String = ""

    // Activity logs
    @State private var activityLogs: [BlossomActivityLog] = []

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Stats Section
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "STATISTICS")
                        StatsSection(stats: stats, isLoading: isLoadingStats)
                    }
                    .padding(.horizontal)

                    // Quick Actions
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "QUICK ACTIONS")
                        QuickActionsSection(
                            stats: stats,
                            isPulling: $isPulling,
                            isPushing: $isPushing,
                            syncProgress: syncProgress,
                            syncMessage: syncMessage,
                            onPull: pullFromNotes,
                            onPush: pushAllToMirrors,
                            onRefresh: refreshAll
                        )
                    }
                    .padding(.horizontal)

                    // Mirror Status (Expandable)
                    if !mirrors.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "MIRRORS")
                            MirrorStatusSection(
                                mirrors: mirrors,
                                isExpanded: $showMirrorSection,
                                onTest: testMirrors
                            )
                        }
                        .padding(.horizontal)
                    }

                    Divider()
                        .padding(.vertical, 8)

                    // Storage Breakdown
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "STORAGE OVERVIEW")
                        StorageBreakdownSection(stats: stats)
                    }
                    .padding(.horizontal)

                    Divider()
                        .padding(.vertical, 8)

                    // Activity Console
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "ACTIVITY LOG")

                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.havenPurple)

                                Text("CONSOLE")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.8))

                                Spacer()

                                HStack(spacing: 5) {
                                    Circle().fill(Color.red.opacity(0.7)).frame(width: 7, height: 7)
                                    Circle().fill(Color.yellow.opacity(0.7)).frame(width: 7, height: 7)
                                    Circle().fill(Color.green.opacity(0.7)).frame(width: 7, height: 7)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(UIColor.secondarySystemBackground))

                            Divider()

                            ActivityLogView(logs: activityLogs, syncMessage: syncMessage)
                                .frame(height: 300)
                        }
                        .background(Color(UIColor.tertiarySystemBackground))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.havenPurple.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.macro")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.havenPurple)
                        Text("Blossom")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: { showingBlossomSettings = true }) {
                            Image(systemName: "gearshape")
                        }

                        Button(action: refreshAll) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoadingStats || isPulling || isPushing)
                    }
                }
            }
        }
        .task {
            await loadDashboard()
        }
        .sheet(isPresented: $showingBlossomSettings) {
            NavigationStack {
                BlossomSettingsView()
                    .environmentObject(configService)
                    .environmentObject(nostrService)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingBlossomSettings = false }
                                .foregroundColor(.havenPurple)
                        }
                    }
            }
        }
    }

    private func loadDashboard() async {
        await loadStats()
        await loadMirrors()
        addLog("Dashboard loaded", level: .info)
    }

    private func loadStats() async {
        isLoadingStats = true

        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: blossomDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            await MainActor.run { isLoadingStats = false }
            return
        }

        let validFiles = files.filter { url in
            let hashPart = url.deletingPathExtension().lastPathComponent
            return hashPart.count == 64 && hashPart.allSatisfy { $0.isHexDigit }
        }

        let totalSize = validFiles.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + size
        }

        await MainActor.run {
            stats.totalFiles = validFiles.count
            stats.totalSize = Int64(totalSize)
            isLoadingStats = false
        }
    }

    private func loadMirrors() async {
        let mirrorURLs = await MainActor.run { configService.config.activeBlossomMirrors }

        let mirrorInfos = mirrorURLs.map { urlString in
            MirrorInfo(
                id: UUID(),
                url: urlString,
                host: URL(string: urlString)?.host ?? urlString,
                isHealthy: nil,
                responseTime: nil,
                fileCount: nil
            )
        }

        await MainActor.run {
            mirrors = mirrorInfos
            stats.mirrorCount = mirrorInfos.count
        }

        // Auto-check health after loading
        await checkMirrorHealth()
    }

    private func checkMirrorHealth() async {
        let currentMirrors = await MainActor.run { mirrors }
        guard !currentMirrors.isEmpty else { return }

        await withTaskGroup(of: (Int, Bool, Int?).self) { group in
            for (index, mirror) in currentMirrors.enumerated() {
                group.addTask {
                    let start = Date()
                    guard let url = URL(string: mirror.url) else {
                        return (index, false, nil)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 10
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                        if let httpResponse = response as? HTTPURLResponse,
                           (200..<500).contains(httpResponse.statusCode) {
                            return (index, true, elapsed)
                        }
                        return (index, false, elapsed)
                    } catch {
                        return (index, false, nil)
                    }
                }
            }

            for await (index, healthy, responseTime) in group {
                await MainActor.run {
                    guard index < mirrors.count else { return }
                    mirrors[index].isHealthy = healthy
                    mirrors[index].responseTime = responseTime
                }
            }
        }

        let healthyCount = await MainActor.run { mirrors.filter { $0.isHealthy == true }.count }
        let totalCount = await MainActor.run { mirrors.count }
        addLog("Mirror check: \(healthyCount)/\(totalCount) healthy", level: healthyCount == totalCount ? .success : .warning)
    }

    private func addLog(_ message: String, level: BlossomActivityLog.LogLevel) {
        let log = BlossomActivityLog(timestamp: Date(), message: message, level: level)
        activityLogs.insert(log, at: 0)
        // Keep only last 50 logs
        if activityLogs.count > 50 {
            activityLogs = Array(activityLogs.prefix(50))
        }
    }

    private func refreshAll() {
        Task {
            await loadDashboard()
        }
    }

    private func pullFromNotes() {
        Task {
            await MainActor.run {
                isPulling = true
                syncProgress = 0
                syncMessage = "Scanning notes for media..."
                addLog("Started pulling media from notes", level: .info)
            }

            let service = BlossomService(configService: configService, nostrService: nostrService)
            let noteMedia = await MainActor.run { nostrService.noteMedia }

            var pulledCount = 0
            _ = await service.mirrorFromNoteMedia(noteMedia) { current, total in
                Task { @MainActor in
                    syncProgress = total > 0 ? Double(current) / Double(total) : 0
                    syncMessage = "Pulled \(current) of \(total) files"
                    pulledCount = current
                }
            }

            await loadDashboard()

            await MainActor.run {
                isPulling = false
                syncMessage = ""
                addLog("Completed pulling \(pulledCount) files from notes", level: .success)
            }
        }
    }

    private func pushAllToMirrors() {
        Task {
            let needsBackup = stats.totalFiles - stats.backedUpCount
            guard needsBackup > 0 else {
                await MainActor.run {
                    addLog("All files already backed up", level: .info)
                }
                return
            }

            await MainActor.run {
                isPushing = true
                syncProgress = 0
                syncMessage = "Starting backup of \(needsBackup) files..."
                addLog("Started pushing \(needsBackup) files to mirrors", level: .info)
            }

            // TODO: Get list of files that need backup and push them
            // For now just refresh stats
            await loadDashboard()

            await MainActor.run {
                isPushing = false
                syncMessage = ""
                addLog("Completed backup operation", level: .success)
            }
        }
    }

    private func testMirrors() {
        Task {
            addLog("Testing mirror connectivity...", level: .info)
            // Reset to pending state
            await MainActor.run {
                for i in mirrors.indices {
                    mirrors[i].isHealthy = nil
                    mirrors[i].responseTime = nil
                }
            }
            await checkMirrorHealth()
        }
    }
}

// MARK: - Data Models

struct BlossomStats {
    var totalFiles: Int = 0
    var totalSize: Int64 = 0
    var mirrorCount: Int = 0
    var backedUpCount: Int = 0

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var backupPercentage: Int {
        guard totalFiles > 0 else { return 0 }
        return Int((Double(backedUpCount) / Double(totalFiles)) * 100)
    }
}

struct MirrorInfo: Identifiable {
    let id: UUID
    let url: String
    let host: String
    var isHealthy: Bool?
    var responseTime: Int?
    var fileCount: Int?
}


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
            .background(Color(UIColor.secondarySystemBackground))
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
                .background(Color(UIColor.secondarySystemBackground))
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
            .background(Color(UIColor.secondarySystemBackground))
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

// MARK: - Mirror Status Section

struct MirrorStatusSection: View {
    let mirrors: [MirrorInfo]
    @Binding var isExpanded: Bool
    let onTest: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text("\(mirrors.count) configured")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemBackground))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(mirrors) { mirror in
                    MirrorRow(mirror: mirror)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MirrorRow: View {
    let mirror: MirrorInfo

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(mirror.isHealthy == true ? Color.green : mirror.isHealthy == false ? Color.red.opacity(0.7) : Color.yellow)
                .frame(width: 6, height: 6)

            Text(mirror.host)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))
                .lineLimit(1)

            Spacer()

            if let responseTime = mirror.responseTime {
                Text("\(responseTime)ms")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.green.opacity(0.7))
            } else {
                Text(mirror.isHealthy == nil ? "Pending" : (mirror.isHealthy == true ? "Healthy" : "Offline"))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(mirror.isHealthy == nil ? .yellow.opacity(0.7) : (mirror.isHealthy == true ? .green.opacity(0.7) : .red.opacity(0.5)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.03))
                .frame(height: 0.5),
            alignment: .bottom
        )
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

// MARK: - Storage Breakdown

struct StorageBreakdownSection: View {
    let stats: BlossomStats

    var body: some View {
        VStack(spacing: 1) {
            BlossomStorageRow(label: "Total Files", value: "\(stats.totalFiles)", icon: "doc.fill", color: .blue)
            BlossomStorageRow(label: "Total Size", value: stats.formattedSize, icon: "internaldrive.fill", color: .havenPurple)
            BlossomStorageRow(label: "Backed Up", value: "\(stats.backedUpCount) (\(stats.backupPercentage)%)", icon: "checkmark.seal.fill", color: .green)
            BlossomStorageRow(label: "Needs Backup", value: "\(stats.totalFiles - stats.backedUpCount)", icon: "exclamationmark.triangle.fill", color: .orange)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct BlossomStorageRow: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(color)
                .frame(width: 20)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemBackground))
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.03))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// MARK: - Activity Log

struct BlossomActivityLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: LogLevel

    enum LogLevel {
        case info, success, warning, error

        var color: Color {
            switch self {
            case .info: return .blue
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }
}

struct ActivityLogView: View {
    let logs: [BlossomActivityLog]
    let syncMessage: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if !syncMessage.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(syncMessage)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.havenPurple)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if logs.isEmpty && syncMessage.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("No recent activity")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(logs) { log in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: log.level.icon)
                                .font(.system(size: 10))
                                .foregroundColor(log.level.color)

                            Text(logTimestamp(log.timestamp))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text(log.message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
