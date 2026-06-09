import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var statsService: StatsService
    @ObservedObject private var mirrorService = MirrorService.shared

    @State private var isExporting = false
    @State private var isBackingUpBlossom = false
    @State private var isPreparingImport = false
    @State private var exportStatusMessage = ""
    @State private var statusAnimate = false
    @State private var showingKindBreakdown = false
    @State private var showingBlossomBreakdown = false
    @State private var showingCacheBreakdown = false
    @State private var showingStorageBreakdown = false
    @State private var showingFullLogs = false
    @State private var shareSheetURL: URL?
    @State private var showingShareSheet = false

    var isSidebar: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            #if os(macOS)
            if geometry.size.width < 750 {
                iOSConsoleLayout(geometry: geometry)
            } else {
                macOSConsoleLayout(geometry: geometry)
            }
            #else
            iOSConsoleLayout(geometry: geometry)
            #endif
        }
        .onAppear {
            statsService.refreshStats()
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            if !isBooting && relayManager.isRunning {
                statsService.refreshStats()
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingShareSheet) {
            if let url = shareSheetURL {
                ShareSheet(activityItems: [url])
            }
        }
        #endif
        .onChange(of: relayManager.importCompleted) { _, completed in
            if completed {
                isPreparingImport = false
            }
        }
        .onChange(of: relayManager.isImporting) { _, isImporting in
            if isImporting {
                isPreparingImport = false
            }
        }
        .sheet(isPresented: $showingKindBreakdown) {
            EventKindBreakdownView()
                .environmentObject(statsService)
        }
        .sheet(isPresented: $showingBlossomBreakdown) {
            BlossomBreakdownView()
                .environmentObject(statsService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingCacheBreakdown) {
            MediaCacheBreakdownView()
                .environmentObject(statsService)
        }
        .sheet(isPresented: $showingStorageBreakdown) {
            StorageBreakdownView()
                .environmentObject(statsService)
        }
        .sheet(isPresented: $showingFullLogs) {
            NavigationStack {
                LogsView(logStore: relayManager.logStore)
                    .environmentObject(relayManager)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingFullLogs = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 700, minHeight: 400, idealHeight: 500)
            #endif
        }
    }

    #if os(macOS)
    private func macOSConsoleLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            relayStatusHeader
                .padding(.top, 8)
                .background(Color.platformWindowBackground)
            
            // Statistics Grid (Full Width 4 Columns)
            let statsColumns = [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ]
            
            LazyVGrid(columns: statsColumns, spacing: 12) {
                StatsCard(
                    title: "Total Relay Events",
                    value: "\(statsService.loadedEventsCount)",
                    icon: "doc.text.fill",
                    color: Color.havenPurple,
                    isLoading: statsService.isUpdatingCount && statsService.loadedEventsCount == 0,
                    action: { showingKindBreakdown = true }
                )

                StatsCard(
                    title: "Storage Used",
                    value: statsService.formattedStorageSize,
                    icon: "internaldrive.fill",
                    color: .blue,
                    action: { showingStorageBreakdown = true }
                )

                StatsCard(
                    title: "Blossom Storage",
                    value: statsService.formattedBlossomSize,
                    icon: "camera.macro",
                    color: .green,
                    action: { showingBlossomBreakdown = true }
                )

                StatsCard(
                    title: "Media Cache",
                    value: statsService.formattedCacheSize,
                    icon: "photo.stack.fill",
                    color: .orange,
                    action: { showingCacheBreakdown = true }
                )
            }
            .padding(.horizontal)
            
            // Side-by-Side Console & Controls
            HStack(alignment: .top, spacing: 16) {
                // Left Column: Actions
                VStack(alignment: .leading, spacing: 12) {
                    if relayManager.isImporting {
                        importProgressSection
                    }

                    if mirrorService.state != .idle {
                        blossomImportSection
                    }

                    if !relayManager.isImporting {
                        let actionColumns = [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ]

                        LazyVGrid(columns: actionColumns, spacing: 8) {
                            ActionButton(icon: "safari", title: "Browser") {
                                if let url = URL(string: configService.config.webURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }

                            ActionButton(icon: "arrow.down.circle", title: "Import", isLoading: isPreparingImport || relayManager.isImporting) {
                                isPreparingImport = true
                                relayManager.importNotes(config: configService.config)
                            }
                            .disabled(isPreparingImport || relayManager.isImporting)

                            ActionButton(icon: "photo.on.rectangle.angled", title: "Import Blossom", isLoading: mirrorService.state == .mirroring) {
                                mirrorService.runMirror(configService: configService, nostrService: nostrService)
                            }
                            .disabled(mirrorService.state == .mirroring)

                            ActionButton(icon: "arrow.up.doc.fill", title: "Export JSONL", isLoading: isExporting) {
                                exportBackup()
                            }
                            .disabled(isExporting || isBackingUpBlossom)

                            ActionButton(icon: "photo.stack", title: "Export Media", isLoading: isBackingUpBlossom) {
                                exportBlossom()
                            }
                            .disabled(isExporting || isBackingUpBlossom)
                        }
                    }
                }
                .frame(width: 380)
                
                // Right Column: System Terminal Logs
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "terminal.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.green)
                        
                        Text("LOCAL RELAY SERVER CONSOLE")
                            .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        HStack(spacing: 5) {
                            Circle().fill(Color.red.opacity(0.7)).frame(width: 7, height: 7)
                            Circle().fill(Color.yellow.opacity(0.7)).frame(width: 7, height: 7)
                            Circle().fill(Color.green.opacity(0.7)).frame(width: 7, height: 7)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.platformConsoleHeaderBackground)
                    
                    Divider()
                        .background(Color.platformCardBorder)
                    
                    LogsView(logStore: relayManager.logStore, hideHeader: true)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformTertiaryGroupedBackground)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green.opacity(0.12), lineWidth: 1)
                )
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.platformWindowBackground.ignoresSafeArea())
    }
    #endif

    private func iOSConsoleLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if isSidebar {
                #if os(macOS)
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(.havenPurple)
                    Text("Relay Dashboard")
                        .font(.appSystem(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .background(Color.platformWindowBackground)
                #endif
            }
            
            relayStatusHeader
                .padding(.top, isSidebar ? 4 : 8)
                .background(Color.platformWindowBackground)
            
            ScrollView {
                VStack(spacing: 20) {
                    // MARK: - Compact Log Console
                    compactLogConsole

                    // MARK: - Statistics
                    fullStatsLayout
                    
                    // MARK: - Actions
                    Spacer(minLength: 8)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Actions")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        if relayManager.isImporting {
                            importProgressSection
                        }

                        if mirrorService.state != .idle {
                            blossomImportSection
                        }

                        let actionColumns = [GridItem(.flexible()), GridItem(.flexible())]

                        LazyVGrid(columns: actionColumns, spacing: 10) {
                            #if os(macOS)
                            ActionButton(icon: "safari", title: "Open Browser") {
                                if let url = URL(string: configService.config.webURL) {
                                    #if os(macOS)
                                    NSWorkspace.shared.open(url)
                                    #else
                                    UIApplication.shared.open(url)
                                    #endif
                                }
                            }
                            #endif

                            ActionButton(icon: "arrow.down.circle", title: "Import Notes", isLoading: isPreparingImport || relayManager.isImporting) {
                                isPreparingImport = true
                                relayManager.importNotes(config: configService.config)
                            }
                            .disabled(isPreparingImport || relayManager.isImporting)

                            ActionButton(icon: "photo.on.rectangle.angled", title: "Import Blossom", isLoading: mirrorService.state == .mirroring) {
                                mirrorService.runMirror(configService: configService, nostrService: nostrService)
                            }
                            .disabled(mirrorService.state == .mirroring)

                            ActionButton(icon: "arrow.up.doc.fill", title: "Export JSONL", isLoading: isExporting) {
                                exportBackup()
                            }
                            .disabled(isExporting || isBackingUpBlossom)

                            ActionButton(icon: "photo.stack", title: "Export Blossom", isLoading: isBackingUpBlossom) {
                                exportBlossom()
                            }
                            .disabled(isExporting || isBackingUpBlossom)
                        }
                        .padding(.horizontal)

                        if !exportStatusMessage.isEmpty {
                            Text(exportStatusMessage)
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                        }
                    }
                    .disabled(!relayManager.isRunning && !relayManager.isImporting)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .frame(minHeight: 350, maxHeight: .infinity, alignment: .top)
            }
            .refreshable {
                guard relayManager.isRunning && !relayManager.isImporting else { return }
                isPreparingImport = true
                relayManager.importNotes(config: configService.config)

                while relayManager.isImporting {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                isPreparingImport = false
            }
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    private var fullStatsLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal)

            let columns = [GridItem(.flexible()), GridItem(.flexible())]

            LazyVGrid(columns: columns, spacing: 8) {
                StatsCard(title: "Total Relay Events", value: "\(statsService.loadedEventsCount)", icon: "doc.text.fill", color: Color.havenPurple, isLoading: statsService.isUpdatingCount && statsService.loadedEventsCount == 0, action: { showingKindBreakdown = true })
                StatsCard(title: "Storage Used", value: statsService.formattedStorageSize, icon: "internaldrive.fill", color: .blue, action: { showingStorageBreakdown = true })
                StatsCard(title: "Blossom Storage", value: statsService.formattedBlossomSize, icon: "camera.macro", color: .green, action: { showingBlossomBreakdown = true })
                StatsCard(title: "Media Cache", value: statsService.formattedCacheSize, icon: "photo.stack.fill", color: .orange, action: { showingCacheBreakdown = true })
            }
            .padding(.horizontal)
        }
    }

    private var compactLogConsole: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.appSystem(size: 10, weight: .bold))
                    .foregroundColor(.green)

                Text("CONSOLE")
                    .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    showingFullLogs = true
                } label: {
                    Text("View All")
                        .font(.appSystem(size: 10, weight: .semibold))
                        .foregroundColor(Color.havenPurple)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.platformConsoleHeaderBackground)

            Divider()
                .background(Color.platformCardBorder)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(relayManager.logStore.logs.suffix(50)) { log in
                            HStack(alignment: .top, spacing: 6) {
                                Text(log.timestamp, style: .time)
                                    .font(.appSystem(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .frame(width: 55, alignment: .leading)

                                Text(log.level)
                                    .font(.appSystem(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(logLevelColor(log.level))
                                    .frame(width: 35, alignment: .leading)

                                Text(log.message)
                                    .font(.appSystem(size: 10, design: .monospaced))
                                    .foregroundColor(.primary.opacity(0.85))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(log.id)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(height: 140)
                .onChange(of: relayManager.logStore.logs.count) { _, _ in
                    if let lastId = relayManager.logStore.logs.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let lastId = relayManager.logStore.logs.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func logLevelColor(_ level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        case "DEBUG": return .gray
        default: return .green
        }
    }

    private func geometryHeight(for width: CGFloat) -> CGFloat {
        var height: CGFloat = 350
        if width < 400 { height += 200 } // Stacked stats
        if width < 350 { height += 150 } // Stacked buttons
        return height
    }
    
    private func exportBackup() {
        isExporting = true
        exportStatusMessage = "Preparing export..."

        let tempDir = NSTemporaryDirectory()
        let tempPath = (tempDir as NSString).appendingPathComponent("haven-backup-\(Date().timeIntervalSince1970).zip")

        relayManager.runBackupExport(config: configService.config, outputPath: tempPath) { success in
            Task { @MainActor in
                isExporting = false

                guard success else {
                    exportStatusMessage = "Export failed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        exportStatusMessage = ""
                    }
                    return
                }

                #if os(macOS)
                let panel = NSSavePanel()
                panel.title = "Save JSONL Backup"
                panel.nameFieldStringValue = "haven-backup.zip"
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true
                
                if panel.runModal() == .OK, let destURL = panel.url {
                    let srcURL = URL(fileURLWithPath: tempPath)
                    do {
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.moveItem(at: srcURL, to: destURL)
                        exportStatusMessage = "Saved to \(destURL.lastPathComponent)"
                    } catch {
                        exportStatusMessage = "Failed to save: \(error.localizedDescription)"
                    }
                } else {
                    // User cancelled the save panel
                    exportStatusMessage = "Export cancelled"
                    try? FileManager.default.removeItem(atPath: tempPath)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    exportStatusMessage = ""
                }
                #else
                // iOS: Share the file
                shareSheetURL = URL(fileURLWithPath: tempPath)
                showingShareSheet = true
                exportStatusMessage = "Ready to share"
                #endif
            }
        }
    }
    
    private func exportBlossom() {
        isBackingUpBlossom = true
        exportStatusMessage = "Preparing Blossom export..."

        let tempDir = NSTemporaryDirectory()
        let tempPath = (tempDir as NSString).appendingPathComponent("blossom-backup-\(Date().timeIntervalSince1970).zip")

        relayManager.runBlossomExportWithExtensions(config: configService.config, outputPath: tempPath) { success in
            Task { @MainActor in
                isBackingUpBlossom = false

                guard success else {
                    exportStatusMessage = "Blossom export failed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        exportStatusMessage = ""
                    }
                    return
                }

                #if os(macOS)
                let panel = NSSavePanel()
                panel.title = "Save Blossom Backup"
                panel.nameFieldStringValue = "blossom-backup.zip"
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true
                
                if panel.runModal() == .OK, let destURL = panel.url {
                    let srcURL = URL(fileURLWithPath: tempPath)
                    do {
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.moveItem(at: srcURL, to: destURL)
                        exportStatusMessage = "Saved to \(destURL.lastPathComponent)"
                    } catch {
                        exportStatusMessage = "Failed to save: \(error.localizedDescription)"
                    }
                } else {
                    exportStatusMessage = "Export cancelled"
                    try? FileManager.default.removeItem(atPath: tempPath)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    exportStatusMessage = ""
                }
                #else
                // iOS: Share the file
                shareSheetURL = URL(fileURLWithPath: tempPath)
                showingShareSheet = true
                exportStatusMessage = "Ready to share"
                #endif
            }
        }
    }

    private var importProgressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Progress")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    Text(relayManager.importStatusMessage)
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Text("\(Int(relayManager.importProgress * 100))%")
                    .font(.appSystem(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.havenPurple)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.havenPurple.opacity(0.1))
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.havenPurple, .havenPurpleLight]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * relayManager.importProgress)
                }
            }
            .frame(height: 8)
            
            if relayManager.importProgress >= 1.0 || relayManager.importStatusMessage.contains("Complete") {
                Button(action: {
                    relayManager.dismissImport()
                }) {
                    Text("Dismiss")
                        .font(.appSystem(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.havenPurple)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private var blossomImportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blossom Import")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text(mirrorService.statusText.isEmpty ? "Complete" : mirrorService.statusText)
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if let prog = mirrorService.progress {
                    Text("\(prog.completed)/\(prog.total)")
                        .font(.appSystem(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                }
            }

            if let prog = mirrorService.progress, prog.total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.green.opacity(0.1))

                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [.green, .green.opacity(0.7)]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * (Double(prog.completed) / Double(prog.total)))
                    }
                }
                .frame(height: 8)
            }

            // Scrollable log view
            if !mirrorService.logEntries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(mirrorService.logEntries) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.timestamp, style: .time)
                                        .font(.appSystem(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.6))
                                        .frame(width: 55, alignment: .leading)

                                    Text(entry.level)
                                        .font(.appSystem(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(blossomLogColor(entry.level))
                                        .frame(width: 35, alignment: .leading)

                                    Text(entry.message)
                                        .font(.appSystem(size: 10, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .id(entry.id)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 160)
                    .background(Color.platformTertiaryGroupedBackground)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.green.opacity(0.12), lineWidth: 0.5)
                    )
                    .onChange(of: mirrorService.logEntries.count) { _, _ in
                        if let lastId = mirrorService.logEntries.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if mirrorService.state == .complete {
                Button(action: {
                    mirrorService.state = .idle
                    mirrorService.logEntries = []
                }) {
                    Text("Dismiss")
                        .font(.appSystem(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.8))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func blossomLogColor(_ level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        case "DEBUG": return .gray
        default: return .green
        }
    }

    private var relayStatusHeader: some View {
        let statusColor = relayManager.isBooting ? Color.yellow : (relayManager.isRunning && relayManager.isWotSyncing ? Color.orange : (relayManager.isRunning ? Color.green : Color.red))
        return VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RELAY STATUS")
                        .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))

                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(statusColor.opacity(0.15))
                                .frame(width: 24, height: 24)
                                .scaleEffect(statusAnimate ? 1.3 : 1.0)

                            Circle()
                                .stroke(statusColor.opacity(0.5), lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                                .scaleEffect(statusAnimate ? 1.5 : 1.0)
                                .opacity(statusAnimate ? 0.0 : 1.0)

                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                                .shadow(color: statusColor.opacity(0.8), radius: 4)
                        }

                        Text(relayManager.isBooting ? "BOOTING..." : (relayManager.isRunning && relayManager.isWotSyncing ? "ONLINE" : (relayManager.isRunning ? "ONLINE" : "OFFLINE")))
                             .font(.appSystem(size: 16, weight: .bold, design: .monospaced))
                             .foregroundColor(.white)
                    }
                }

                Spacer()

                Button(action: {
                    if relayManager.isRunning {
                        relayManager.stopRelay {
                            relayManager.startRelay(config: configService.config)
                        }
                    } else {
                        relayManager.startRelay(config: configService.config)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: relayManager.isRunning ? "arrow.clockwise" : "play.fill")
                            .font(.appSystem(size: 11, weight: .bold))
                        Text(relayManager.isRunning ? "Restart Relay" : "Start Relay")
                            .font(.appSystem(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: relayManager.isRunning
                                ? [Color.orange.opacity(0.8), Color.orange.opacity(0.6)]
                                : [Color.havenPurple, Color.havenPurpleDark]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(relayManager.isBooting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.platformCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                statusColor.opacity(0.35),
                                Color.platformCardBorder,
                                Color.white.opacity(0.02)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: statusColor.opacity(relayManager.isRunning && !relayManager.isBooting ? 0.08 : 0), radius: 10, x: 0, y: 4)
            
            // Error recovery banner
            if relayManager.isLocked || relayManager.isPortConflict {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(relayManager.isPortConflict ? "Port 3355 is already in use" : "Database lock detected")
                            .font(.appSystem(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                    }

                    Text(relayManager.isPortConflict
                        ? "Another process is using the relay port. Close other Nostr Vault instances or restart your computer."
                        : "A previous session did not shut down cleanly. Clear locks to restart the relay.")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Button {
                            relayManager.forceCleanAndRestart()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Force Restart")
                            }
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.havenPurple)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        if relayManager.isLocked {
                            Button {
                                relayManager.clearDatabaseLocks { [relayManager, configService] in
                                    Task { @MainActor in
                                        relayManager.startRelay(config: configService.config, isRetry: true)
                                    }
                                }
                            } label: {
                                Text("Clear Locks Only")
                                    .font(.appSystem(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.08))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1))
            }
        }
        .padding(.horizontal)
    }
}
