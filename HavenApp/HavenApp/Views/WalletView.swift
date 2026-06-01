import SwiftUI

struct WalletView: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WalletLightningTab()
                .environmentObject(nostrService)
                .environmentObject(configService)
            .navigationTitle("Wallet")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.havenPurple)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 550)
        #endif
    }
}
