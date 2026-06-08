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


struct RelayRow: View {
    let name: String
    let subtitle: String
    let icon: String
    let uri: String
    let endpoint: String

    @State private var copied = false
    @State private var isHovered = false

    var fullURI: String {
        return uri + endpoint
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(Color.havenPurple)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(fullURI)
                .font(.appSystem(size: 10, design: .monospaced))
                .foregroundColor(copied ? .green : Color.havenPurpleLight)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(copied ? 0.5 : 0.35))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(copied ? Color.green.opacity(0.6) : Color.havenPurple.opacity(0.3), lineWidth: 1)
                )
                .scaleEffect(copied ? 1.05 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: copied)

            Button(action: {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullURI, forType: .string)
                #else
                UIPasteboard.general.string = fullURI
                #endif
                withAnimation(.easeInOut(duration: 0.2)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                }
            }) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundColor(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? Color.platformSecondaryGroupedBackground : Color.platformCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? Color.havenPurple.opacity(0.2) : Color.white.opacity(0.03), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    
    @Environment(\.controlSize) private var controlSize // Can check size context
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

struct StatsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var isLoading: Bool = false
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.appSystem(size: 16))
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.appSystem(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8, anchor: .leading)
                        .frame(height: 24)
                } else {
                    Text(value)
                        .font(.appSystem(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(isHovered ? color.opacity(0.08) : Color.platformCardBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? color.opacity(0.4) : Color.platformCardBorder, lineWidth: 1.0)
        )
        .shadow(color: color.opacity(isHovered ? 0.18 : 0.0), radius: 8, x: 0, y: 3)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
    }

    var body: some View {
        Group {
            if let action = action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering && action != nil }
        }
    }
}

struct EventKindBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @Environment(\.dismiss) private var dismiss

    @State private var counts: [Int: Int] = [:]
    @State private var isLoading = true

    private static let kindNames: [Int: String] = [
        0: "Profile Metadata",
        1: "Short Notes",
        3: "Contacts",
        4: "Encrypted DMs (legacy)",
        5: "Event Deletions",
        6: "Reposts",
        7: "Reactions",
        8: "Badge Awards",
        9: "Chat Messages",
        16: "Generic Reposts",
        1059: "Gift Wraps (DMs)",
        1063: "File Metadata",
        1311: "Live Chat",
        1808: "Audio Tracks",
        9734: "Zap Requests",
        9735: "Zap Receipts",
        10000: "Mute Lists",
        10001: "Pinned Notes",
        10002: "Relay Lists",
        10003: "Bookmarks",
        10005: "Public Chats",
        10006: "Blocked Relays",
        10015: "Interest Lists",
        10030: "Emoji Lists",
        30000: "People Lists",
        30001: "Generic Lists",
        30002: "Relay Sets",
        30008: "Profile Badges",
        30009: "Badge Definitions",
        30023: "Long-form Articles",
        30024: "Long-form Drafts",
        30030: "Emoji Sets",
        30078: "App Data"
    ]

    private var total: Int { counts[-1] ?? 0 }

    private var sortedKinds: [(kind: Int, count: Int)] {
        counts.filter { $0.key != -1 }
              .sorted { $0.value > $1.value }
              .map { (kind: $0.key, count: $0.value) }
    }

    private var knownTotal: Int {
        sortedKinds.reduce(0) { $0 + $1.count }
    }

    private var otherCount: Int {
        max(0, total - knownTotal)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Counting events by kind…")
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(total)")
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Events")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(16)
                            .background(Color.havenPurple.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .padding(.top, 12)

                            VStack(spacing: 1) {
                                ForEach(sortedKinds, id: \.kind) { item in
                                    KindRow(
                                        kind: item.kind,
                                        name: Self.kindNames[item.kind] ?? "Kind \(item.kind)",
                                        count: item.count,
                                        total: total
                                    )
                                }

                                if otherCount > 0 {
                                    KindRow(
                                        kind: -2,
                                        name: "Other (unqueried kinds)",
                                        count: otherCount,
                                        total: total
                                    )
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("Event Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await reload() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        counts = await statsService.fetchCountsByKind()
        isLoading = false
    }
}

struct BlossomBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var blobs: [BlobDescriptor] = []
    @State private var isLoading = true

    private var totalCount: Int { blobs.count }
    private var totalSize: Int { blobs.compactMap(\.size).reduce(0, +) }

    private struct TypeBucket {
        let label: String
        let icon: String
        let color: Color
        let count: Int
        let size: Int
    }

    private var buckets: [TypeBucket] {
        var images = (count: 0, size: 0), videos = (count: 0, size: 0), audio = (count: 0, size: 0), other = (count: 0, size: 0)
        for blob in blobs {
            let t = blob.type ?? ""
            let s = blob.size ?? 0
            if t.hasPrefix("image/") { images.count += 1; images.size += s }
            else if t.hasPrefix("video/") { videos.count += 1; videos.size += s }
            else if t.hasPrefix("audio/") { audio.count += 1; audio.size += s }
            else { other.count += 1; other.size += s }
        }
        return [
            TypeBucket(label: "Images", icon: "photo.fill", color: .blue, count: images.count, size: images.size),
            TypeBucket(label: "Videos", icon: "video.fill", color: .orange, count: videos.count, size: videos.size),
            TypeBucket(label: "Audio", icon: "waveform", color: .purple, count: audio.count, size: audio.size),
            TypeBucket(label: "Other", icon: "doc.fill", color: .secondary, count: other.count, size: other.size),
        ].filter { $0.count > 0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Counting blobs…")
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(totalCount)")
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Blobs")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Size")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color.havenPurple.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .padding(.top, 12)

                            VStack(spacing: 1) {
                                ForEach(buckets, id: \.label) { bucket in
                                    BlobTypeRow(
                                        label: bucket.label,
                                        icon: bucket.icon,
                                        color: bucket.color,
                                        count: bucket.count,
                                        size: bucket.size,
                                        total: totalSize
                                    )
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("Blob Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await reload() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        let pubkey = configService.activeAccountHexPubkey
        blobs = await statsService.fetchBlobList(for: pubkey)
        isLoading = false
    }
}

struct MediaCacheBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @Environment(\.dismiss) private var dismiss

    @State private var breakdown: StatsService.CacheBreakdown?
    @State private var isLoading = true
    @State private var showingClearConfirmation = false
    @State private var isClearing = false

    private var totalSize: Int64 {
        guard let b = breakdown else { return 0 }
        return b.imageSize + b.videoSize + b.thumbnailSize + b.otherSize
    }

    private var totalCount: Int {
        guard let b = breakdown else { return 0 }
        return b.imageCount + b.videoCount + b.thumbnailCount + b.otherCount
    }

    private struct TypeBucket {
        let label: String
        let icon: String
        let color: Color
        let count: Int
        let size: Int64
    }

    private var buckets: [TypeBucket] {
        guard let b = breakdown else { return [] }
        return [
            TypeBucket(label: "Cached Images", icon: "photo.fill", color: .blue, count: b.imageCount, size: b.imageSize),
            TypeBucket(label: "Cached Videos", icon: "video.fill", color: .orange, count: b.videoCount, size: b.videoSize),
            TypeBucket(label: "Video Thumbnails", icon: "rectangle.grid.2x2.fill", color: .purple, count: b.thumbnailCount, size: b.thumbnailSize),
            TypeBucket(label: "Other", icon: "doc.fill", color: .secondary, count: b.otherCount, size: b.otherSize),
        ].filter { $0.count > 0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Scanning cache\u{2026}")
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(totalCount)")
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Cached Files")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Size")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color.havenPurple.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .padding(.top, 12)

                            VStack(spacing: 1) {
                                ForEach(buckets, id: \.label) { bucket in
                                    BlobTypeRow(
                                        label: bucket.label,
                                        icon: bucket.icon,
                                        color: bucket.color,
                                        count: bucket.count,
                                        size: Int(bucket.size),
                                        total: Int(totalSize)
                                    )
                                }
                            }
                            .padding(.horizontal)

                            // Cache lifetime info
                            if let b = breakdown, totalCount > 0 {
                                let ttlDays = ConfigService.shared.config.cacheTTLDays
                                VStack(spacing: 6) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "clock.fill")
                                            .font(.appSystem(size: 12))
                                            .foregroundColor(.secondary)
                                        Text("TTL: \(ttlDays > 0 ? "\(ttlDays) day\(ttlDays == 1 ? "" : "s")" : "Never expires")")
                                            .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    if let oldest = b.oldestFile {
                                        HStack(spacing: 8) {
                                            Image(systemName: "calendar")
                                                .font(.appSystem(size: 12))
                                                .foregroundColor(.secondary)
                                            Text("Oldest: \(Self.relativeDate(oldest))")
                                                .font(.appSystem(size: 12, design: .monospaced))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            if let newest = b.newestFile {
                                                Text("Newest: \(Self.relativeDate(newest))")
                                                    .font(.appSystem(size: 12, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color.platformCardBackground)
                                .cornerRadius(8)
                                .padding(.horizontal)
                                .padding(.top, 4)
                            }

                            Button(action: { showingClearConfirmation = true }) {
                                HStack {
                                    if isClearing {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "trash")
                                    }
                                    Text("Clear Cache")
                                }
                                .font(.appSystem(size: 14, weight: .semibold))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                                )
                            }
                            .disabled(isClearing || totalCount == 0)
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("Cache Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await reload() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .alert("Clear Media Cache?", isPresented: $showingClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    isClearing = true
                    MediaCacheService.shared.clearCache()
                    statsService.refreshStats()
                    Task {
                        await reload()
                        isClearing = false
                    }
                }
            } message: {
                Text("This will remove all cached images, videos, and thumbnails. Blossom media will not be affected. Files will be re-downloaded as needed.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        let service = statsService
        let relayDir = ConfigService.shared.relayDataDir
        breakdown = await Task.detached(priority: .userInitiated) {
            return service.calculateCacheBreakdown(relayDir: relayDir)
        }.value
        isLoading = false
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct BlobTypeRow: View {
    let label: String
    let icon: String
    let color: Color
    let count: Int
    let size: Int
    let total: Int

    private var sizePercent: Double {
        guard total > 0 else { return 0 }
        return Double(size) / Double(total)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text("\(count) \(count == 1 ? "blob" : "blobs")")
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.appSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                Text(String(format: "%.1f%%", sizePercent * 100))
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformCardBorder, lineWidth: 0.5)
        )
        .cornerRadius(8)
    }
}

struct StorageBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @Environment(\.dismiss) private var dismiss

    private struct StorageBucket: Identifiable {
        let id = UUID()
        let label: String
        let icon: String
        let color: Color
        let size: Int64
    }

    private var buckets: [StorageBucket] {
        let dbSize = max(0, statsService.storageSize - statsService.blossomSize - statsService.cacheSize - statsService.thumbnailSize)
        return [
            StorageBucket(label: "Database", icon: "cylinder.fill", color: .blue, size: dbSize),
            StorageBucket(label: "Blossom Media", icon: "camera.macro", color: .green, size: statsService.blossomSize),
            StorageBucket(label: "Media Cache", icon: "photo.stack.fill", color: .orange, size: statsService.cacheSize + statsService.thumbnailSize),
        ].filter { $0.size > 0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ByteCountFormatter.string(fromByteCount: statsService.storageSize, countStyle: .file))
                                    .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                Text("Total Storage Used")
                                    .font(.appSystem(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(Color.havenPurple.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal)
                        .padding(.top, 12)

                        VStack(spacing: 1) {
                            ForEach(buckets) { bucket in
                                StorageRow(
                                    label: bucket.label,
                                    icon: bucket.icon,
                                    color: bucket.color,
                                    size: bucket.size,
                                    total: statsService.storageSize
                                )
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Storage Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { statsService.refreshStats() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
    }
}

private struct StorageRow: View {
    let label: String
    let icon: String
    let color: Color
    let size: Int64
    let total: Int64

    private var sizePercent: Double {
        guard total > 0 else { return 0 }
        return Double(size) / Double(total)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 24)

            Text(label)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.appSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                Text(String(format: "%.1f%%", sizePercent * 100))
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformCardBorder, lineWidth: 0.5)
        )
        .cornerRadius(8)
    }
}

private struct KindRow: View {
    let kind: Int
    let name: String
    let count: Int
    let total: Int

    private var percent: Double {
        guard total > 0 else { return 0 }
        return Double(count) / Double(total)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(kind >= 0 ? "kind \(kind)" : "—")
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(count)")
                    .font(.appSystem(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.havenPurple)
                Text(String(format: "%.1f%%", percent * 100))
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformCardBorder, lineWidth: 0.5)
        )
        .cornerRadius(8)
    }
}

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
