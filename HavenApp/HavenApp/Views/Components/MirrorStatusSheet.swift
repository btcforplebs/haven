import SwiftUI

struct MirrorStatusSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State private var mirrorStatus: [String: Bool] = [:]
    @State private var isLoading = true
    @State private var sha256Hash: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("Checking mirrors...")
                        .padding()
                } else if mirrorStatus.isEmpty {
                    ContentUnavailableView(
                        "No Mirrors Configured",
                        systemImage: "server.rack",
                        description: Text("Configure Blossom mirrors in Settings to enable external backup")
                    )
                } else {
                    List {
                        Section {
                            if let hash = sha256Hash {
                                HStack {
                                    Text("Hash")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(hash.prefix(16) + "...")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Section("Mirror Status") {
                            ForEach(Array(mirrorStatus.keys.sorted()), id: \.self) { mirror in
                                HStack {
                                    Image(systemName: mirrorStatus[mirror] == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(mirrorStatus[mirror] == true ? .green : .red)

                                    VStack(alignment: .leading, spacing: 2) {
                                        if let host = URL(string: mirror)?.host {
                                            Text(host)
                                                .font(.appSystem(size: 14, weight: .semibold))
                                        }
                                        Text(mirror)
                                            .font(.appSystem(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if mirrorStatus[mirror] == true {
                                        Text("Available")
                                            .font(.appSystem(size: 11, weight: .medium))
                                            .foregroundColor(.green)
                                    } else {
                                        Text("Not Found")
                                            .font(.appSystem(size: 11, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Blossom Mirrors")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await checkMirrors()
        }
    }

    private func checkMirrors() async {
        isLoading = true

        // Extract hash from URL
        let lastComponent = url.deletingPathExtension().lastPathComponent
        if lastComponent.count == 64, lastComponent.allSatisfy({ $0.isHexDigit }) {
            sha256Hash = lastComponent

            let service = BlossomService(configService: configService, nostrService: nostrService)
            let status = await service.checkMirrorStatus(sha256: lastComponent)

            await MainActor.run {
                mirrorStatus = status
                isLoading = false
            }
        } else {
            await MainActor.run {
                isLoading = false
            }
        }
    }
}
