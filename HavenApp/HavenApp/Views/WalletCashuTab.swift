import SwiftUI
import CoreImage.CIFilterBuiltins

struct WalletCashuTab: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var cashuService = CashuService.shared

    // Mode pickers
    /// The tab is organised by what you're trying to do, not by which protocol
    /// does it. It used to be two cards split by rail — a "Lightning Bridge"
    /// with Fund/Cash Out, and "Ecash Tokens" with Send/Receive — so you had to
    /// know the plumbing before you could find the action. "Cash Out" was also
    /// simply wrong: nothing cashes out, it pays a Lightning invoice using ecash.
    enum MoneyDirection: String, CaseIterable, Identifiable {
        case add = "Add sats"
        case send = "Send sats"
        var id: String { rawValue }
    }

    /// Which rail carries it. Secondary to the direction, and labelled by what
    /// it does rather than by protocol name.
    enum MoneyRail: String, CaseIterable, Identifiable {
        case lightning, token
        var id: String { rawValue }

        func label(for direction: MoneyDirection) -> String {
            switch (direction, self) {
            case (.add, .lightning):  return "From Lightning"
            case (.add, .token):      return "Paste a token"
            case (.send, .lightning): return "Pay an invoice"
            case (.send, .token):     return "Create a token"
            }
        }

        var icon: String {
            switch self {
            case .lightning: return "bolt.fill"
            case .token: return "banknote.fill"
            }
        }
    }

    @State private var direction: MoneyDirection = .add
    @State private var rail: MoneyRail = .lightning

    // Balance
    @State private var isLoadingBalance = false
    @State private var balanceError: String? = nil

    // Fund (Lightning -> Ecash)
    @State private var mintAmountSats: String = ""
    @State private var isMinting = false
    @State private var mintQuote: CashuMintQuote? = nil
    @State private var isPollingQuote = false
    @State private var isFundingFromLightning = false
    @State private var mintError: String? = nil
    @State private var mintSuccess: String? = nil
    @State private var copiedInvoice = false

    // Cash Out (Ecash -> Lightning)
    @State private var cashOutAmountSats: String = ""
    @State private var isGeneratingInvoice = false
    @State private var cashOutInvoice: String? = nil
    @State private var isMelting = false
    @State private var meltQuote: CashuMeltQuote? = nil
    @State private var meltResult: String? = nil
    @State private var meltError: String? = nil

    // Send Token
    @State private var sendAmountSats: String = ""
    @State private var isSendingToken = false
    @State private var generatedToken: String? = nil
    @State private var copiedToken = false
    @State private var sendTokenError: String? = nil

    // Receive Token
    @State private var receiveTokenString: String = ""
    @State private var isReceivingToken = false
    @State private var receiveResult: String? = nil
    @State private var receiveError: String? = nil

    // Info sheet
    @State private var showingCashuInfo = false

    // Bearer instruments
    @State private var copiedProofId: String? = nil

    // Recovery animation
    @State private var recoveredSats: UInt64 = 0
    @State private var showRecoveryBanner = false
    @State private var balancePulse = false
    @State private var isRestoringFromRelays = false

    private static let ecashBrown = Color(red: 0.65, green: 0.45, blue: 0.2)

    private var hasMint: Bool {
        !configService.config.cashuMintURL.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                betaBanner
                if !hasMint {
                    mintNotConfiguredCard
                } else {
                    balanceCard
                    if showRecoveryBanner {
                        recoveryBanner
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.8))
                            ))
                    }
                    mintInfoCard
                    moveMoneyCard
                    unclaimedTokensCard
                    bearerInstrumentsCard
                }
                Spacer(minLength: 20)
            }
            .padding(.top, 12)
            .animation(Motion.bannerIn, value: showRecoveryBanner)
        }
        .sheet(isPresented: $showingCashuInfo) {
            CashuInfoView()
        }
        .onAppear {
            if hasMint {
                cashuService.configureMint(urlString: configService.config.cashuMintURL)
                refreshBalance()
                Task {
                    // Auto-restore from relays if wallet is empty (e.g. after reinstall)
                    if cashuService.balanceSats == 0 && cashuService.proofs.isEmpty {
                        await restoreFromRelays()
                    }

                    // Move any token someone has since claimed out of the
                    // unclaimed list before it's shown as reclaimable.
                    await cashuService.refreshSentTokenStates()

                    let recovered = await cashuService.recoverPendingQuotes()
                    if recovered > 0 {
                        recoveredSats = recovered
                        withAnimation(Motion.bannerIn) {
                            showRecoveryBanner = true
                            balancePulse = true
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        withAnimation(Motion.pop) {
                            balancePulse = false
                        }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation(Motion.bannerOut) {
                            showRecoveryBanner = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Beta Banner

    private var betaBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.appSystem(size: 18, weight: .bold))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("BETA - EXPERIMENTAL")
                    .font(.appSystem(size: 13, weight: .black))
                    .foregroundColor(.orange)
                Text("Cashu ecash backed by your relay. Tokens are stored encrypted on your private relay for cross-device sync and recovery. Do not store large amounts.")
                    .font(.appSystem(size: 11, weight: .medium))
                    .foregroundColor(.orange.opacity(0.8))
            }
            Spacer()
            Button(action: { showingCashuInfo = true }) {
                Image(systemName: "info.circle.fill")
                    .font(.appSystem(size: 20))
                    .foregroundColor(.orange.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1.5)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Not Configured Card

    private var mintNotConfiguredCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "banknote.fill")
                .font(.appSystem(size: 32))
                .foregroundColor(.secondary)
            Text("No Mint Connected")
                .font(.appSystem(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text("Add a Cashu mint URL in Settings to enable the ecash wallet.")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "banknote.fill")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(Self.ecashBrown)
                Text("ECASH BALANCE")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if isLoadingBalance {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: { refreshBalance() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = balanceError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatSats(cashuService.balanceSats))
                        .font(.appSystem(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .scaleEffect(balancePulse ? 1.15 : 1.0)
                        .animation(Motion.pop, value: balancePulse)
                    Text("sats")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            Button(action: { Task { await restoreFromRelays() } }) {
                HStack(spacing: 6) {
                    if isRestoringFromRelays {
                        ProgressView().controlSize(.small)
                    }
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.appSystem(size: 12, weight: .semibold))
                    Text("Restore from Relays")
                        .font(.appSystem(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .disabled(isRestoringFromRelays)
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(balancePulse ? Self.ecashBrown.opacity(0.6) : Color.platformSeparator.opacity(0.4), lineWidth: balancePulse ? 2 : 1)
        )
        .animation(Motion.fade, value: balancePulse)
        .padding(.horizontal, 16)
    }

    // MARK: - Recovery Banner

    private var recoveryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.appSystem(size: 14, weight: .bold))
            Text("Recovered \(formatSats(recoveredSats)) sats of ecash")
                .font(.appSystem(size: 13, weight: .bold))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.2, green: 0.8, blue: 0.6))
                .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
        )
        .foregroundColor(.white)
        .padding(.horizontal, 16)
    }

    // MARK: - Mint Info Card

    private var mintInfoCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.columns.fill")
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(Self.ecashBrown)
            VStack(alignment: .leading, spacing: 2) {
                if let info = cashuService.mintInfo, let name = info.name, !name.isEmpty {
                    Text(name)
                        .font(.appSystem(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                }
                Text(configService.config.cashuMintURL)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Lightning Bridge Card

    private var moveMoneyCard: some View {
        VStack(spacing: 14) {
            // Primary choice: what you want to do.
            Picker("", selection: $direction) {
                ForEach(MoneyDirection.allCases) { d in
                    Text(d.rawValue).tag(d)
                }
            }
            .pickerStyle(.segmented)

            // Secondary choice: how it travels. Labelled by outcome, so the
            // rail never has to be understood in the abstract.
            Picker("", selection: $rail) {
                ForEach(MoneyRail.allCases) { r in
                    Label(r.label(for: direction), systemImage: r.icon).tag(r)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch (direction, rail) {
                case (.add, .lightning):  fundContent
                case (.add, .token):      receiveContent
                case (.send, .lightning): cashOutContent
                case (.send, .token):     sendContent
                }
            }

            Text(railExplainer)
                .font(.appCaption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .animation(Motion.toggle, value: direction)
        .animation(Motion.toggle, value: rail)
    }

    /// One plain sentence per combination — the thing the old layout never said.
    private var railExplainer: String {
        switch (direction, rail) {
        case (.add, .lightning):
            return "Creates a Lightning invoice. Pay it from any wallet and the sats arrive here as ecash."
        case (.add, .token):
            return "Paste an ecash token someone gave you to add it to your balance."
        case (.send, .lightning):
            return "Pays a Lightning invoice using your ecash balance. The mint settles it over Lightning."
        case (.send, .token):
            return "Creates a token string. Anyone holding it can claim it, so treat it like cash — your balance drops as soon as it's created."
        }
    }

    // MARK: - Fund Content (Lightning → Ecash)

    private var fundContent: some View {
        VStack(spacing: 12) {
            TextField("Amount (sats)", text: $mintAmountSats)
                .font(.appSystem(size: 14, design: .monospaced))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .textFieldStyle(.roundedBorder)

            if mintQuote == nil {
                // Step 1: Create the mint invoice
                Button(action: { createMintQuote() }) {
                    HStack(spacing: 6) {
                        if isMinting {
                            ProgressView().controlSize(.small)
                        }
                        Text("Create Invoice")
                            .font(.appSystem(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(mintAmountSats.isEmpty || isMinting)
            }

            if let quote = mintQuote, quote.state == "UNPAID" {
                invoiceView(quote.request)

                // Step 2: Pay from Lightning wallet or externally
                HStack(spacing: 8) {
                    Button(action: { fundFromLightning() }) {
                        HStack(spacing: 6) {
                            if isFundingFromLightning {
                                ProgressView().controlSize(.small)
                            }
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.yellow)
                            Text("Fund from Lightning")
                                .font(.appSystem(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                    .disabled(isFundingFromLightning || isPollingQuote)

                    Button(action: { waitForExternalPayment() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                            Text("Paid Externally")
                                .font(.appSystem(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .disabled(isFundingFromLightning || isPollingQuote)
                }

                if isPollingQuote {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for payment to confirm...")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let error = mintError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }

            if let success = mintSuccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(success)
                        .font(.appCaption)
                        .foregroundColor(.green)
                }
            }
        }
    }

    // MARK: - Cash Out Content (Ecash → Lightning)

    private var cashOutContent: some View {
        VStack(spacing: 12) {
            TextField("Amount (sats)", text: $cashOutAmountSats)
                .font(.appSystem(size: 14, design: .monospaced))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .textFieldStyle(.roundedBorder)

            if cashOutInvoice == nil {
                // Step 1: Generate a Lightning receive invoice via NWC
                Button(action: { generateCashOutInvoice() }) {
                    HStack(spacing: 6) {
                        if isGeneratingInvoice {
                            ProgressView().controlSize(.small)
                        }
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.yellow)
                        Text("Generate Invoice")
                            .font(.appSystem(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(cashOutAmountSats.isEmpty || isGeneratingInvoice)
            }

            if let invoice = cashOutInvoice {
                // Show the generated invoice
                Text(invoice)
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)

                if let quote = meltQuote {
                    HStack {
                        Text("Amount: \(quote.amount) sats")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Fee: \(quote.fee_reserve) sats")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }

                    // Step 2: Pay the invoice from Ecash
                    Button(action: { executeMelt() }) {
                        HStack(spacing: 6) {
                            if isMelting {
                                ProgressView().controlSize(.small)
                            }
                            Image(systemName: "banknote.fill")
                                .foregroundColor(Self.ecashBrown)
                            Text("Pay from Ecash")
                                .font(.appSystem(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(Self.ecashBrown)
                    .disabled(isMelting)
                }
            }

            if let error = meltError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }

            if let result = meltResult {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(result)
                        .font(.appCaption)
                        .foregroundColor(.green)
                }
            }
        }
    }

    // MARK: - Invoice Display

    private func invoiceView(_ invoice: String) -> some View {
        VStack(spacing: 10) {
            if let qrImage = generateQRCode(from: invoice.uppercased()) {
                HStack {
                    Spacer()
                    Image(platformImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                        .cornerRadius(8)
                    Spacer()
                }
            }

            Text(invoice)
                .font(.appSystem(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)

            Button(action: {
                PlatformClipboard.copy(invoice)
                copiedInvoice = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedInvoice = false }
            }) {
                Label(
                    copiedInvoice ? "Copied!" : "Copy Invoice",
                    systemImage: copiedInvoice ? "checkmark" : "doc.on.doc"
                )
                .font(.appSystem(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.green)
        }
        .padding(.top, 8)
    }

    // MARK: - Ecash Token Card

    // MARK: - Unclaimed Tokens

    /// Tokens this wallet created that nobody has claimed yet.
    ///
    /// The sats left the balance the moment each was created, so until someone
    /// redeems it the string here is the only thing that can claim them. Without
    /// this list, losing the string stranded the money.
    private var unclaimedTokensCard: some View {
        let outstanding = cashuService.sentTokens.filter { !$0.isClaimed }
        return Group {
            if !outstanding.isEmpty {
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.appSystem(size: 14, weight: .semibold))
                            .foregroundColor(.orange)
                        Text("UNCLAIMED TOKENS")
                            .font(.appSystem(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(formatSats(outstanding.reduce(0) { $0 + $1.amountSats })) sats")
                            .font(.appSystem(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.orange)
                    }

                    Text("These are already out of your balance. Anyone holding the string can claim one — reclaim it to take the sats back.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(outstanding) { sent in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(formatSats(sent.amountSats)) sats")
                                    .font(.appSystem(size: 14, weight: .semibold, design: .monospaced))
                                Spacer()
                                Text(sent.createdAt, style: .relative)
                                    .font(.appCaption2)
                                    .foregroundColor(.secondary)
                            }
                            if let memo = sent.memo, !memo.isEmpty {
                                Text(memo)
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            HStack(spacing: 8) {
                                Button {
                                    copyToClipboard(sent.token)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.appSystem(size: 12, weight: .semibold))
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    reclaimToken(sent)
                                } label: {
                                    Label("Reclaim", systemImage: "arrow.uturn.backward")
                                        .font(.appSystem(size: 12, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)

                                Spacer()

                                Button {
                                    cashuService.forgetSentToken(sent)
                                } label: {
                                    Text("Forget")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(8)
                    }
                }
                .padding(16)
                .background(Color.platformControlBackground.opacity(0.6))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Send Token Content

    private var sendContent: some View {
        VStack(spacing: 12) {
            TextField("Amount (sats)", text: $sendAmountSats)
                .font(.appSystem(size: 14, design: .monospaced))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .textFieldStyle(.roundedBorder)

            Button(action: { createSendToken() }) {
                HStack(spacing: 6) {
                    if isSendingToken {
                        ProgressView().controlSize(.small)
                    }
                    Text("Create Token")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(sendAmountSats.isEmpty || isSendingToken)

            if let error = sendTokenError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }

            if let token = generatedToken {
                VStack(spacing: 8) {
                    Text(token)
                        .font(.appSystem(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)

                    Button(action: {
                        PlatformClipboard.copy(token)
                        copiedToken = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedToken = false }
                    }) {
                        Label(
                            copiedToken ? "Copied!" : "Copy Token",
                            systemImage: copiedToken ? "checkmark" : "doc.on.doc"
                        )
                        .font(.appSystem(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }
            }
        }
    }

    // MARK: - Receive Token Content

    private var receiveContent: some View {
        VStack(spacing: 12) {
            TextField("Paste cashuA... token", text: $receiveTokenString)
                .font(.appSystem(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(3)

            Button(action: { redeemToken() }) {
                HStack(spacing: 6) {
                    if isReceivingToken {
                        ProgressView().controlSize(.small)
                    }
                    Text("Redeem")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .disabled(receiveTokenString.isEmpty || isReceivingToken)

            if let error = receiveError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }

            if let result = receiveResult {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(result)
                        .font(.appCaption)
                        .foregroundColor(.green)
                }
            }
        }
    }

    // MARK: - Bearer Instruments Card

    private var bearerInstrumentsCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(Self.ecashBrown)
                Text("PROOFS BACKED UP ON YOUR RELAY")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if !cashuService.proofs.filter({ !$0.isSpent }).isEmpty {
                    Button(action: { copyAllProofs() }) {
                        HStack(spacing: 4) {
                            Image(systemName: copiedProofId == "_all" ? "checkmark" : "doc.on.doc.fill")
                                .font(.appSystem(size: 11, weight: .medium))
                            Text(copiedProofId == "_all" ? "Copied!" : "Copy All")
                                .font(.appSystem(size: 11, weight: .medium))
                        }
                        .foregroundColor(copiedProofId == "_all" ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            let unspent = cashuService.proofs.filter { !$0.isSpent }

            if unspent.isEmpty {
                Text("No ecash tokens stored on relay.")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(unspent) { proof in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(proof.amount) sats")
                                .font(.appSystem(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary)
                            Text(String(proof.keysetId.prefix(12)))
                                .font(.appSystem(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: { copyProof(proof) }) {
                            Image(systemName: copiedProofId == proof.id ? "checkmark" : "doc.on.doc")
                                .font(.appSystem(size: 13, weight: .medium))
                                .foregroundColor(copiedProofId == proof.id ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.platformControlBackground.opacity(0.4))
                    .cornerRadius(8)
                }
            }
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func copyProof(_ proof: CashuProof) {
        let token = cashuService.encodeToken(proofs: [proof], memo: nil)
        PlatformClipboard.copy(token)
        copiedProofId = proof.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedProofId == proof.id { copiedProofId = nil }
        }
    }

    private func copyAllProofs() {
        let unspent = cashuService.proofs.filter { !$0.isSpent }
        guard !unspent.isEmpty else { return }
        let token = cashuService.encodeToken(proofs: unspent, memo: nil)
        PlatformClipboard.copy(token)
        copiedProofId = "_all"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedProofId == "_all" { copiedProofId = nil }
        }
    }

    // MARK: - Actions

    private func restoreFromRelays() async {
        await MainActor.run { isRestoringFromRelays = true }
        let balanceBefore = cashuService.balanceSats
        await cashuService.loadWalletFromRelays()
        try? await cashuService.checkProofStates()
        let restored = cashuService.balanceSats > balanceBefore ? cashuService.balanceSats - balanceBefore : 0
        await MainActor.run {
            isRestoringFromRelays = false
            if restored > 0 {
                recoveredSats = restored
                withAnimation(Motion.bannerIn) {
                    showRecoveryBanner = true
                    balancePulse = true
                }
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    withAnimation(Motion.pop) {
                        balancePulse = false
                    }
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    withAnimation(Motion.bannerOut) {
                        showRecoveryBanner = false
                    }
                }
            }
        }
    }

    private func refreshBalance() {
        isLoadingBalance = true
        balanceError = nil
        Task {
            do {
                cashuService.configureMint(urlString: configService.config.cashuMintURL)
                let _ = try await cashuService.fetchMintInfo()
                let _ = try await cashuService.fetchActiveKeys()
                try await cashuService.checkProofStates()
                await MainActor.run {
                    isLoadingBalance = false
                }
            } catch {
                await MainActor.run {
                    balanceError = error.localizedDescription
                    isLoadingBalance = false
                }
            }
        }
    }

    private func createMintQuote() {
        guard let sats = UInt64(mintAmountSats), sats > 0 else {
            mintError = "Enter a valid amount in sats."
            return
        }
        isMinting = true
        mintError = nil
        mintSuccess = nil
        mintQuote = nil
        Task {
            do {
                let quote = try await cashuService.requestMintQuote(amountSats: sats)
                cashuService.addPendingQuote(quote: quote, amountSats: sats)
                await MainActor.run {
                    mintQuote = quote
                    isMinting = false
                }
            } catch {
                await MainActor.run {
                    mintError = "Could not reach mint: \(error.localizedDescription)"
                    isMinting = false
                }
            }
        }
    }

    private func waitForExternalPayment() {
        guard let quote = mintQuote else { return }
        guard let sats = UInt64(mintAmountSats), sats > 0 else { return }
        mintError = nil
        isPollingQuote = true
        Task {
            await pollMintQuote(quoteId: quote.quote, amountSats: sats)
        }
    }

    private func fundFromLightning() {
        guard let quote = mintQuote else { return }
        guard let sats = UInt64(mintAmountSats), sats > 0 else { return }
        isFundingFromLightning = true
        mintError = nil
        Task {
            do {
                // Step 1: Pay the mint invoice from Lightning wallet via NWC
                let _ = try await NWCService.payInvoice(bolt11: quote.request)

                // Step 2: Poll until the mint confirms payment, then mint tokens
                await MainActor.run { isPollingQuote = true; isFundingFromLightning = false }
                await pollMintQuote(quoteId: quote.quote, amountSats: sats)
            } catch {
                await MainActor.run {
                    mintError = "Lightning payment failed: \(error.localizedDescription)"
                    isFundingFromLightning = false
                }
            }
        }
    }

    private func pollMintQuote(quoteId: String, amountSats: UInt64) async {
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            do {
                let updated = try await cashuService.checkMintQuote(quoteId: quoteId)
                if updated.state == "PAID" {
                    try await cashuService.mintTokens(quoteId: quoteId, amountSats: amountSats)
                    cashuService.removePendingQuote(quoteId: quoteId)
                    await MainActor.run {
                        mintSuccess = "Minted \(amountSats) sats of ecash!"
                        mintQuote = nil
                        mintAmountSats = ""
                        isPollingQuote = false
                    }
                    return
                } else if updated.state == "ISSUED" {
                    cashuService.removePendingQuote(quoteId: quoteId)
                    await MainActor.run {
                        mintSuccess = "Tokens already issued."
                        mintQuote = nil
                        isPollingQuote = false
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    mintError = "Could not confirm with mint: \(error.localizedDescription). If you already paid, tokens will be recovered automatically on next refresh."
                    isPollingQuote = false
                }
                return
            }
        }

        await MainActor.run {
            mintError = "Payment not yet confirmed. If you paid externally, tokens will be recovered automatically."
            mintQuote = nil
            isPollingQuote = false
        }
    }

    private func generateCashOutInvoice() {
        guard let sats = UInt64(cashOutAmountSats), sats > 0 else {
            meltError = "Enter a valid amount in sats."
            return
        }
        isGeneratingInvoice = true
        meltError = nil
        meltResult = nil
        cashOutInvoice = nil
        meltQuote = nil
        Task {
            do {
                // Step 1: Create a Lightning receive invoice via NWC
                let msats = Int(sats) * 1000
                let invoice = try await NWCService.makeInvoice(amountMsats: msats, description: "Ecash cash out")

                // Step 2: Get a melt quote from the mint for this invoice
                let quote = try await cashuService.requestMeltQuote(bolt11: invoice)

                await MainActor.run {
                    cashOutInvoice = invoice
                    meltQuote = quote
                    isGeneratingInvoice = false
                }
            } catch {
                await MainActor.run {
                    meltError = error.localizedDescription
                    isGeneratingInvoice = false
                }
            }
        }
    }

    private func executeMelt() {
        guard let quote = meltQuote else { return }
        isMelting = true
        meltError = nil
        meltResult = nil
        Task {
            do {
                let paid = try await cashuService.meltTokens(
                    quoteId: quote.quote,
                    amount: quote.amount,
                    feeReserve: quote.fee_reserve
                )
                await MainActor.run {
                    if paid {
                        meltResult = "Cashed out to Lightning!"
                        cashOutAmountSats = ""
                        cashOutInvoice = nil
                        meltQuote = nil
                    } else {
                        meltError = "Payment not confirmed. Check the invoice status."
                    }
                    isMelting = false
                }
            } catch {
                await MainActor.run {
                    meltError = error.localizedDescription
                    isMelting = false
                }
            }
        }
    }

    private func createSendToken() {
        guard let sats = UInt64(sendAmountSats), sats > 0 else {
            sendTokenError = "Enter a valid amount in sats."
            return
        }
        isSendingToken = true
        sendTokenError = nil
        generatedToken = nil
        Task {
            do {
                let token = try await cashuService.createSendToken(amountSats: sats)
                await MainActor.run {
                    generatedToken = token
                    sendAmountSats = ""
                    isSendingToken = false
                }
            } catch {
                await MainActor.run {
                    sendTokenError = error.localizedDescription
                    isSendingToken = false
                }
            }
        }
    }

    private func redeemToken() {
        let token = receiveTokenString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isReceivingToken = true
        receiveError = nil
        receiveResult = nil
        Task {
            do {
                try await cashuService.receiveToken(tokenString: token)
                await MainActor.run {
                    receiveResult = "Token redeemed! Balance updated."
                    receiveTokenString = ""
                    isReceivingToken = false
                }
            } catch {
                await MainActor.run {
                    receiveError = error.localizedDescription
                    isReceivingToken = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func copyToClipboard(_ value: String) {
        PlatformClipboard.copy(value)
    }

    /// Pulls an unclaimed token back into the balance. `receiveToken` swaps for
    /// fresh proofs, so any copy of the string someone else kept dies with it.
    private func reclaimToken(_ sent: SentEcashToken) {
        Task {
            do {
                try await cashuService.reclaimSentToken(sent)
                refreshBalance()
            } catch {
                // Already claimed by someone else is the expected failure here —
                // refresh so it moves out of the unclaimed list on its own.
                await cashuService.refreshSentTokenStates()
            }
        }
    }

    private func formatSats(_ sats: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }

    private func generateQRCode(from string: String) -> PlatformImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
        #endif
    }
}

// MARK: - Cashu Info View

private struct CashuInfoView: View {
    @Environment(\.dismiss) private var dismiss

    private static let ecashBrown = Color(red: 0.65, green: 0.45, blue: 0.2)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Hero
                    VStack(spacing: 12) {
                        Image(systemName: "banknote.fill")
                            .font(.appSystem(size: 48, weight: .light))
                            .foregroundColor(Self.ecashBrown)
                        Text("Cashu Ecash Wallet")
                            .font(.appSystem(size: 22, weight: .bold, design: .rounded))
                        Text("Digital cash backed by your relay")
                            .font(.appSubheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    // What is Cashu?
                    infoSection(
                        title: "What is Cashu?",
                        icon: "questionmark.circle.fill",
                        color: Self.ecashBrown
                    ) {
                        Text("Cashu is an open-source ecash protocol for Bitcoin. It lets you hold sats as digital bearer tokens — like digital cash — that are private, instant, and nearly free to transfer.")
                        bulletPoint("Ecash tokens are blinded: the mint that issues them cannot link tokens back to who withdrew them, preserving your privacy.")
                        bulletPoint("Tokens are backed 1:1 by Bitcoin. You fund the wallet via Lightning, and cash out back to Lightning at any time.")
                        bulletPoint("Transfers between users are instant and offline-capable — just copy and paste a token string.")
                    }

                    // Three-layer payment stack
                    infoSection(
                        title: "Three-Layer Payment Stack",
                        icon: "square.stack.3d.up.fill",
                        color: .yellow
                    ) {
                        Text("Haven manages your Nostr identity, relay, and payments in one place. Ecash completes a three-layer payment stack — each layer suited for different use cases:")
                        bulletPoint("Lightning: Fast global payments via your NWC-connected wallet. Best for paying invoices and receiving zaps.")
                        bulletPoint("Ecash: Private bearer tokens for tips, gifts, and peer-to-peer transfers without revealing your Lightning node or on-chain activity.")
                        Text("The Lightning Bridge lets you move sats between Lightning and Ecash in two taps. Fund ecash from Lightning for spending, cash out back to Lightning when you want.")
                    }

                    // How it works
                    infoSection(
                        title: "How It Works",
                        icon: "gearshape.2.fill",
                        color: .blue
                    ) {
                        Text("The Cashu protocol uses Blind Diffie-Hellman key exchange (BDHKE) so the mint signs your tokens without seeing them:")
                        bulletPoint("1. You choose a mint (a server that issues and redeems tokens). The mint holds Bitcoin and issues ecash against it.")
                        bulletPoint("2. To fund: You pay a Lightning invoice to the mint. The mint signs blinded tokens and returns them. You unblind them locally — the mint never sees the final token.")
                        bulletPoint("3. To spend: You send token strings to anyone. They redeem at the same mint for fresh tokens (a swap), proving validity without revealing the sender.")
                        bulletPoint("4. To cash out: You present tokens to the mint and it pays a Lightning invoice of your choice.")
                    }

                    // Relay-backed storage
                    infoSection(
                        title: "Backed by Your Relay",
                        icon: "server.rack",
                        color: .purple
                    ) {
                        Text("Your ecash tokens are stored encrypted on your Haven private relay using NIP-60. Unlike other wallets that depend on third-party relays, your tokens live on infrastructure you control:")
                        bulletPoint("When you mint ecash, the proofs are encrypted with NIP-44 (only your nsec can decrypt them) and published to your relay's private endpoint.")
                        bulletPoint("If you reinstall the app or set up a new device, your tokens are restored automatically from your relay — no seed phrases or manual backups needed.")
                        bulletPoint("Use the \"Restore from Relays\" button in the wallet to manually trigger recovery at any time.")
                        Text("As long as your Haven relay is running and you have your nsec, your ecash is recoverable.")
                            .fontWeight(.semibold)
                    }

                    // Trust model
                    infoSection(
                        title: "Trust & Risk",
                        icon: "exclamationmark.shield.fill",
                        color: .red
                    ) {
                        Text("Ecash requires trusting the mint. This is fundamentally different from self-custodial Bitcoin:")
                        bulletPoint("The mint is custodial: It holds the Bitcoin backing your tokens. If the mint disappears or acts maliciously, your ecash could become worthless.")
                        bulletPoint("Choose mints carefully: Use established, reputable mints. Never store more ecash than you're willing to lose.")
                        bulletPoint("Privacy is strong but not absolute: The mint cannot link withdrawals to deposits (blinding), but it knows the total amount issued and redeemed.")
                        bulletPoint("Tokens are bearer instruments: If someone intercepts a token string before you redeem it, they can claim it. Treat tokens like physical cash.")
                        Text("Ecash is best suited for spending money — smaller amounts you plan to use — not long-term savings.")
                            .fontWeight(.semibold)
                    }

                    // Beta status
                    infoSection(
                        title: "Beta Status",
                        icon: "exclamationmark.triangle.fill",
                        color: .orange
                    ) {
                        Text("This Cashu implementation is experimental. Known limitations:")
                        bulletPoint("The Cashu NUT protocol is still evolving — token formats and mint APIs may change.")
                        bulletPoint("Multi-mint support is not yet implemented (one mint at a time).")
                        bulletPoint("There is no offline token verification — tokens are verified by swapping at the mint.")
                        bulletPoint("Token recovery depends on your Haven relay being reachable.")
                        bulletPoint("No spending conditions (P2PK locks, HTLC) yet.")
                        Text("DO NOT store significant amounts as ecash. Use this for small, everyday amounts you want to move quickly and privately.")
                            .fontWeight(.semibold)
                    }

                    // References
                    infoSection(
                        title: "References",
                        icon: "doc.text.fill",
                        color: .secondary
                    ) {
                        bulletPoint("Cashu Protocol: cashu.space")
                        bulletPoint("NUT-00 through NUT-07: Token format, mint/melt, key rotation, state checks")
                        bulletPoint("NIP-60: Cashu wallet event kinds for Nostr relay storage")
                        bulletPoint("NIP-44: Versioned encryption (ChaCha20 + HMAC-SHA256)")
                        bulletPoint("BDHKE: Blind Diffie-Hellman Key Exchange (David Wagner, 1996)")
                    }

                    Spacer(minLength: 40)
                }
                .padding(20)
            }
            .navigationTitle("Ecash Wallet Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 550, idealWidth: 620, minHeight: 600, idealHeight: 750)
        #endif
    }

    // MARK: - Section Builder

    private func infoSection(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.appSystem(size: 16, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.appSystem(size: 16, weight: .bold))
                    .foregroundColor(.primary)
            }
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .font(.appSystem(size: 13))
            .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.3), lineWidth: 1)
        )
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .font(.appSystem(size: 13, weight: .bold))
                .foregroundColor(Self.ecashBrown.opacity(0.7))
            Text(text)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
