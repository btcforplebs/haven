import SwiftUI

// MARK: - Design System

private enum WizardColors {
    static let bgPrimary = Color(red: 0.035, green: 0.035, blue: 0.043)      // #09090B
    static let bgCard = Color(red: 0.094, green: 0.094, blue: 0.106)          // #18181B
    static let bgElevated = Color(red: 0.153, green: 0.153, blue: 0.165)      // #27272A
    static let accentPrimary = Color(red: 0.961, green: 0.620, blue: 0.043)   // #F59E0B
    static let accentGlow = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.3)
    static let textPrimary = Color(red: 0.980, green: 0.980, blue: 0.980)     // #FAFAFA
    static let textSecondary = Color(red: 0.631, green: 0.631, blue: 0.667)   // #A1A1AA
    static let textMuted = Color(red: 0.443, green: 0.443, blue: 0.478)       // #71717A
    static let borderSubtle = Color(red: 0.153, green: 0.153, blue: 0.165)    // #27272A
    static let borderActive = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.5)
    static let success = Color(red: 0.133, green: 0.773, blue: 0.369)         // #22C55E
    static let error = Color(red: 0.937, green: 0.267, blue: 0.267)           // #EF4444

    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.918, green: 0.345, blue: 0.047), Color(red: 0.961, green: 0.620, blue: 0.043)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

private enum WizardAnimations {
    static let springEnter: Animation = .spring(response: 0.6, dampingFraction: 0.8)
    static let springBounce: Animation = .spring(response: 0.5, dampingFraction: 0.6)
    static let springGentle: Animation = .spring(response: 0.8, dampingFraction: 0.9)
    static let fadeIn: Animation = .easeOut(duration: 0.4)
    static let staggerDelay: Double = 0.08
}

// MARK: - Ambient Gradient Background

private struct AmbientGradientView: View {
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate * 0.08
                let cx = size.width * 0.5 + sin(t) * size.width * 0.1
                let cy = size.height * 0.4 + cos(t * 0.7) * size.height * 0.08
                let radius = min(size.width, size.height) * 0.45

                let gradient = Gradient(colors: [
                    Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.15),
                    Color(red: 0.918, green: 0.345, blue: 0.047).opacity(0.08),
                    Color.clear
                ])
                let shading = GraphicsContext.Shading.radialGradient(
                    gradient,
                    center: CGPoint(x: cx, y: cy),
                    startRadius: 0,
                    endRadius: radius
                )
                context.fill(Path(CGRect(origin: .zero, size: size)), with: shading)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Shared Components

private struct WizardPrimaryButton: View {
    let title: String
    let action: () -> Void
    var disabled: Bool = false

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .frame(maxWidth: isIOSDevice ? .infinity : nil, minHeight: 44)
                .padding(.horizontal, isIOSDevice ? 0 : 32)
                .background(WizardColors.accentGradient)
                .cornerRadius(12)
                .shadow(color: WizardColors.accentGlow, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .opacity(disabled ? 0.4 : 1.0)
        .disabled(disabled)
        .animation(WizardAnimations.springGentle, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

private struct WizardSkipLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(WizardColors.textMuted)
        }
        .buttonStyle(.plain)
    }
}

private struct WizardGlassCard<Content: View>: View {
    var isSelected: Bool = false
    let content: () -> Content

    var body: some View {
        content()
            .padding(20)
            .background(WizardColors.bgCard)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? WizardColors.borderActive : WizardColors.borderSubtle, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? WizardColors.accentGlow : .clear, radius: 12)
    }
}

private struct WizardInputField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var isSecure: Bool = false
    var isDisabled: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(WizardColors.textSecondary)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundColor(WizardColors.textPrimary)
            .padding(12)
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? WizardColors.borderActive : WizardColors.borderSubtle, lineWidth: isFocused ? 2 : 1)
            )
            .focused($isFocused)
            .disabled(isDisabled)
        }
    }
}

private struct StepDots: View {
    let totalSteps: Int
    let currentStep: Int
    @Namespace private var dotNamespace

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Circle()
                    .fill(index <= currentStep ? WizardColors.accentPrimary : WizardColors.borderSubtle)
                    .frame(width: index == currentStep ? 10 : 6, height: index == currentStep ? 10 : 6)
                    .shadow(color: index == currentStep ? WizardColors.accentGlow : .clear, radius: 4)
                    .animation(WizardAnimations.springEnter, value: currentStep)
            }
        }
        .padding(.vertical, 16)
    }
}

// MARK: - Main Wizard View

struct SetupWizardView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @Environment(\.dismiss) var dismiss

    // Navigation state
    @State private var currentStep = 0
    @State private var setupPath: SetupPath = .none
    @State private var direction: TransitionDirection = .forward

    // Identity state
    @State private var npub = ""
    @State private var nsec = ""
    @State private var nsecPassword = ""
    @State private var signingMode = "local"
    @State private var bunkerURI = ""
    @State private var bunkerConnected = false

    // Relay state
    @State private var relayURL = ""
    @State private var macRelayURL = ""

    // Wallet state
    @State private var nwcURI = ""
    @State private var cashuMintURL = ""

    // Error state
    @State private var setupError: String?
    @State private var showSetupError = false

    let onComplete: () -> Void

    enum SetupPath {
        case none, full, browse
    }

    enum TransitionDirection {
        case forward, backward
    }

    // Compute visible steps based on path and platform
    private var totalVisibleSteps: Int {
        switch setupPath {
        case .none: return 3 // welcome, path, identity
        case .browse: return 3 // welcome, path, identity, done (3 dots, last = complete)
        case .full: return isIOSDevice ? 8 : 7  // welcome, path, identity, relay, import, media, wallet, (notif), done
        }
    }

    private var currentDotIndex: Int {
        // Map actual step numbers to dot indices
        let fullSteps: [Int] = isIOSDevice ? [0, 1, 2, 3, 4, 5, 6, 7, 8] : [0, 1, 2, 3, 4, 5, 6, 8]
        let browseSteps: [Int] = [0, 1, 2, 8]
        let steps = setupPath == .browse ? browseSteps : fullSteps
        return steps.firstIndex(of: currentStep) ?? 0
    }

    var body: some View {
        ZStack {
            // Full-screen dark background
            WizardColors.bgPrimary.ignoresSafeArea()

            // Ambient gradient
            AmbientGradientView()

            VStack(spacing: 0) {
                // Back button
                HStack {
                    if currentStep > 0 {
                        Button(action: goBack) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text(String(localized: "setup.nav.back"))
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(WizardColors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .frame(height: 36)

                // Content area
                ScrollView {
                    VStack {
                        stepContent
                            .frame(maxWidth: 560)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Step dots
                StepDots(totalSteps: totalVisibleSteps, currentStep: currentDotIndex)
            }

            // Process kill alert overlay
            if relayManager.showProcessKillAlert {
                processKillOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(String(localized: "setup.alert.error.title"), isPresented: $showSetupError) {
            Button(String(localized: "setup.alert.ok"), role: .cancel) {}
        } message: {
            Text(setupError ?? String(localized: "setup.alert.error.unknown"))
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            WelcomeStepView(onContinue: { goForward() })
        case 1:
            ChoosePathStep(selectedPath: $setupPath, onContinue: { goForward() })
        case 2:
            IdentityStepView(
                isBrowseMode: setupPath == .browse,
                npub: $npub,
                nsec: $nsec,
                nsecPassword: $nsecPassword,
                signingMode: $signingMode,
                bunkerURI: $bunkerURI,
                bunkerConnected: $bunkerConnected,
                onContinue: { goForward() }
            )
        case 3:
            RelayConfigStep(
                relayURL: $relayURL,
                macRelayURL: $macRelayURL,
                onContinue: { goForward() },
                onSkip: { goForward() }
            )
        case 4:
            ImportNotesStep(onContinue: { goForward() }, onSkip: { goForward() })
        case 5:
            MirrorMediaStep(onContinue: { goForward() }, onSkip: { goForward() })
        case 6:
            WalletSetupStep(
                nwcURI: $nwcURI,
                cashuMintURL: $cashuMintURL,
                onContinue: {
                    if isIOSDevice {
                        goForward() // Go to notifications
                    } else {
                        currentStep = 8 // Go to complete
                    }
                },
                onSkip: {
                    if isIOSDevice {
                        goForward()
                    } else {
                        currentStep = 8
                    }
                }
            )
        case 7:
            if isIOSDevice {
                PushNotificationStep(onContinue: { currentStep = 8 }, onSkip: { currentStep = 8 })
            } else {
                // macOS browse mode lands here as "complete"
                CompleteStep(isBrowseMode: setupPath == .browse, onLaunch: { saveAndComplete() })
            }
        case 8:
            CompleteStep(isBrowseMode: setupPath == .browse, onLaunch: { saveAndComplete() })
        default:
            EmptyView()
        }
    }

    private func goForward() {
        direction = .forward
        withAnimation(WizardAnimations.springEnter) {
            if currentStep == 2 && setupPath == .browse {
                // Browse mode: skip relay, import, media, wallet, notifications — go straight to complete
                currentStep = 8
            } else if currentStep == 6 && !isIOSDevice {
                // macOS full setup: skip notifications, go to complete
                currentStep = 8
            } else {
                currentStep += 1
            }
        }
        // Save intermediate config at key points
        if currentStep >= 3 || (currentStep == 8 && setupPath == .browse) {
            saveIntermediateConfig()
        }
    }

    private func goBack() {
        direction = .backward
        withAnimation(WizardAnimations.springEnter) {
            if currentStep == 8 {
                if setupPath == .browse {
                    currentStep = 2 // Browse: back to identity
                } else if isIOSDevice {
                    currentStep = 7 // iOS full: back to notifications
                } else {
                    currentStep = 6 // macOS full: back to wallet
                }
            } else if currentStep == 7 && isIOSDevice {
                currentStep = 6 // iOS full: back to wallet
            } else {
                currentStep -= 1
            }
        }
    }

    private func saveIntermediateConfig() {
        configService.config.ownerNpub = npub
        configService.config.relayURL = relayURL
        configService.config.dbEngine = "badger"
        configService.config.signingMode = signingMode
        configService.config.setupMode = setupPath == .browse ? "browse" : "full"
        configService.config.macRelayURL = macRelayURL
        configService.config.nwcURI = nwcURI
        configService.config.cashuMintURL = cashuMintURL

        if signingMode == "nip46" {
            configService.config.nip46BunkerURI = bunkerURI
        } else if !nsec.isEmpty && !nsecPassword.isEmpty {
            do {
                configService.config.ownerNcryptsec = try NIP49Service.encrypt(nsec: nsec, password: nsecPassword)
                configService.config.ownerNsec = ""
                _ = NIP49Service.storePasswordInKeychain(nsecPassword)
            } catch {
                setupError = "Failed to encrypt private key: \(error.localizedDescription)"
                showSetupError = true
                return
            }
        }
        configService.save()
    }

    private func saveAndComplete() {
        saveIntermediateConfig()
        configService.config.hasCompletedSetup = true
        configService.save()
        configService.refreshActiveAccountHex()

        if isIOSDevice {
            PushNotificationService.shared.requestPermissionAndRegister()
        }

        onComplete()
        dismiss()
    }

    private var processKillOverlay: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(WizardColors.accentPrimary)

                VStack(spacing: 6) {
                    Text(String(localized: "setup.error.processKill.title"))
                        .font(.title2.bold())
                        .foregroundColor(WizardColors.textPrimary)

                    Text(String(localized: "setup.error.processKill.message"))
                        .multilineTextAlignment(.center)
                        .foregroundColor(WizardColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Text("pkill -9 haven")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(WizardColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)

                    Button(action: {
                        #if os(macOS)
                        NSApp.activate(ignoringOtherApps: true)
                        #endif
                        PlatformClipboard.copy("pkill -9 haven")
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundColor(WizardColors.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(WizardColors.accentPrimary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    relayManager.showProcessKillAlert = false
                    relayManager.forceCleanAndRestart()
                }) {
                    Text(String(localized: "setup.error.processKill.retry"))
                        .font(.headline)
                        .foregroundColor(WizardColors.textPrimary)
                        .frame(width: 140, height: 36)
                        .background(WizardColors.accentPrimary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(30)
            .frame(width: 400)
            .background(WizardColors.bgCard)
            .cornerRadius(16)
            .transition(.scale.combined(with: .opacity))
        }
        .zIndex(100)
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStepView: View {
    let onContinue: () -> Void
    @State private var appeared = false

    private let features: [(icon: String, title: String, line: String)] = [
        ("externaldrive.connected.to.line.below", "Personal Relay", "Run your own relay on-device. Notes are stored locally and broadcast to the network — you always have a copy."),
        ("doc.text.image", "Full Nostr Client", "Browse your feed, post notes, reply, repost, and discover content from the network."),
        ("lock.shield", "Private Messaging", "NIP-17 encrypted DMs that stay on your device. No third-party server reads your conversations."),
        ("photo.stack", "Blossom Media", "Host images and videos on your machine with Blossom. Mirror media from the network to your local storage."),
        ("bolt.fill", "Lightning + Ecash", "Send and receive zaps over Lightning with NWC. Store ecash tokens with a built-in Cashu wallet.")
    ]

    var body: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 20)

            // App icon
            Image(systemName: "shield.checkered")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(WizardColors.accentGradient)
                .scaleEffect(appeared ? 1.0 : 0.8)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.springEnter, value: appeared)

            // Title
            Text(String(localized: "setup.welcome.appName"))
                .font(.system(size: isIOSDevice ? 32 : 36, weight: .bold, design: .default))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.2), value: appeared)

            // Subtitle lines
            VStack(spacing: 6) {
                Text(String(localized: "setup.welcome.subtitle1"))
                Text(String(localized: "setup.welcome.subtitle2"))
            }
            .font(.system(size: isIOSDevice ? 15 : 16))
            .foregroundColor(WizardColors.textSecondary)
            .multilineTextAlignment(.center)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(WizardAnimations.springEnter.delay(0.4), value: appeared)

            // Feature cards
            VStack(spacing: 10) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    featureCard(icon: feature.icon, title: feature.title, line: feature.line)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(WizardAnimations.springEnter.delay(0.6 + Double(index) * WizardAnimations.staggerDelay), value: appeared)
                }
            }

            // CTA
            WizardPrimaryButton(title: String(localized: "setup.welcome.getStarted"), action: onContinue)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(1.0), value: appeared)

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
    }

    private func featureCard(icon: String, title: String, line: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(WizardColors.accentPrimary)
                .shadow(color: WizardColors.accentGlow, radius: 4)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: isIOSDevice ? 15 : 16, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                Text(line)
                    .font(.system(size: isIOSDevice ? 13 : 14))
                    .foregroundColor(WizardColors.textSecondary)
            }

            Spacer()
        }
        .padding(14)
        .background(WizardColors.bgCard)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(WizardColors.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Step 1: Choose Path

private struct ChoosePathStep: View {
    @Binding var selectedPath: SetupWizardView.SetupPath
    let onContinue: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 40)

            Text(String(localized: "setup.path.title"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            VStack(spacing: 14) {
                // Full Setup card
                Button(action: { withAnimation(WizardAnimations.springEnter) { selectedPath = .full } }) {
                    WizardGlassCard(isSelected: selectedPath == .full) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 28))
                                .foregroundColor(selectedPath == .full ? WizardColors.accentPrimary : WizardColors.textSecondary)
                                .frame(width: 36)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(String(localized: "setup.path.full.title"))
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(WizardColors.textPrimary)
                                    Spacer()
                                    if selectedPath == .full {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(WizardColors.accentPrimary)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                Text(String(localized: "setup.path.full.description"))
                                    .font(.system(size: 14))
                                    .foregroundColor(WizardColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .opacity(selectedPath == .browse ? 0.7 : 1.0)
                }
                .buttonStyle(.plain)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(WizardAnimations.springEnter.delay(0.25), value: appeared)

                // Browse Mode card
                Button(action: { withAnimation(WizardAnimations.springEnter) { selectedPath = .browse } }) {
                    WizardGlassCard(isSelected: selectedPath == .browse) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 28))
                                .foregroundColor(selectedPath == .browse ? WizardColors.accentPrimary : WizardColors.textSecondary)
                                .frame(width: 36)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(String(localized: "setup.path.browse.title"))
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(WizardColors.textPrimary)
                                    Spacer()
                                    if selectedPath == .browse {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(WizardColors.accentPrimary)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                Text(String(localized: "setup.path.browse.description"))
                                    .font(.system(size: 14))
                                    .foregroundColor(WizardColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .opacity(selectedPath == .full ? 0.7 : 1.0)
                }
                .buttonStyle(.plain)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(WizardAnimations.springEnter.delay(0.35), value: appeared)
            }

            if selectedPath != .none {
                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer()
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Step 2: Identity

private struct IdentityStepView: View {
    let isBrowseMode: Bool
    @Binding var npub: String
    @Binding var nsec: String
    @Binding var nsecPassword: String
    @Binding var signingMode: String
    @Binding var bunkerURI: String
    @Binding var bunkerConnected: Bool
    let onContinue: () -> Void

    enum SigningMethod { case local, nip46 }

    @State private var appeared = false
    @State private var generatedKeys = false
    @State private var isConnectingBunker = false
    @State private var bunkerError: String?
    @State private var selectedMethod: SigningMethod = .local

    private var isNpubValid: Bool {
        guard !npub.isEmpty, npub.hasPrefix("npub") else { return false }
        guard let decoded = Bech32.decode(npub), decoded.hrp == "npub" else { return false }
        return true
    }

    private var canContinue: Bool {
        guard isNpubValid else { return false }
        if isBrowseMode { return true }
        if selectedMethod == .nip46 { return bunkerConnected }
        if !nsec.isEmpty && nsecPassword.isEmpty { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(isBrowseMode ? String(localized: "setup.identity.title.browse") : String(localized: "setup.identity.title.full"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            if isBrowseMode {
                Text(String(localized: "setup.identity.browseHint"))
                    .font(.system(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)
            }

            // npub field
            WizardInputField(label: String(localized: "setup.identity.label.npub"), text: $npub, placeholder: "npub1...", isDisabled: selectedMethod == .nip46 && bunkerConnected)
                .opacity(appeared ? 1 : 0)
                .offset(x: appeared ? 0 : 20)
                .animation(WizardAnimations.springEnter.delay(0.2), value: appeared)

            if !npub.isEmpty && !isNpubValid {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                    Text(String(localized: "setup.identity.invalidNpub"))
                        .font(.system(size: 13))
                }
                .foregroundColor(WizardColors.error)
            }

            if !isBrowseMode {
                // Signing method selector cards
                HStack(spacing: 12) {
                    signingMethodCard(
                        method: .local,
                        icon: "key.fill",
                        title: String(localized: "setup.identity.method.local.title"),
                        subtitle: String(localized: "setup.identity.method.local.subtitle")
                    )
                    signingMethodCard(
                        method: .nip46,
                        icon: "link.badge.plus",
                        title: String(localized: "setup.identity.method.remote.title"),
                        subtitle: String(localized: "setup.identity.method.remote.subtitle")
                    )
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.28), value: appeared)

                // Fields for the selected method
                if selectedMethod == .local {
                    VStack(spacing: 16) {
                        WizardInputField(label: String(localized: "setup.identity.label.nsec"), text: $nsec, placeholder: "nsec1...", isSecure: true)

                        if !nsec.isEmpty && !nsec.hasPrefix("nsec") {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                Text(String(localized: "setup.identity.invalidNsec"))
                                    .font(.system(size: 13))
                            }
                            .foregroundColor(WizardColors.error)
                        }

                        if !nsec.isEmpty {
                            WizardInputField(label: String(localized: "setup.identity.label.password"), text: $nsecPassword, placeholder: "Enter password...", isSecure: true)
                                .transition(.move(edge: .top).combined(with: .opacity))

                            Text(String(localized: "setup.identity.passwordHint"))
                                .font(.system(size: 12))
                                .foregroundColor(WizardColors.textMuted)

                            if nsecPassword.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.caption)
                                    Text(String(localized: "setup.identity.passwordRequired"))
                                        .font(.system(size: 13))
                                }
                                .foregroundColor(WizardColors.accentPrimary)
                            }
                        }

                        Button(action: generateNewIdentity) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(WizardColors.accentPrimary)
                                Text(String(localized: "setup.identity.generateKeys"))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(WizardColors.accentPrimary)
                            }
                        }
                        .buttonStyle(.plain)

                        if generatedKeys {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundColor(WizardColors.accentPrimary)
                                Text(String(localized: "setup.identity.nsecWarning"))
                                    .font(.system(size: 13))
                                    .foregroundColor(WizardColors.accentPrimary)
                            }
                            .padding(12)
                            .background(WizardColors.accentPrimary.opacity(0.1))
                            .cornerRadius(10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    VStack(spacing: 12) {
                        WizardInputField(label: String(localized: "setup.identity.label.bunker"), text: $bunkerURI, placeholder: "bunker://...", isDisabled: bunkerConnected)

                        Text(String(localized: "setup.identity.bunkerHint"))
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)

                        if let error = bunkerError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                Text(error)
                                    .font(.system(size: 13))
                            }
                            .foregroundColor(WizardColors.error)
                        }

                        if bunkerConnected {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(WizardColors.success)
                                Text(String(localized: "setup.identity.bunkerConnected"))
                                    .font(.system(size: 13))
                                    .foregroundColor(WizardColors.success)
                            }
                        }

                        HStack(spacing: 12) {
                            WizardPrimaryButton(
                                title: bunkerConnected ? String(localized: "setup.identity.bunker.disconnect") : String(localized: "setup.identity.bunker.connect"),
                                action: {
                                    if bunkerConnected {
                                        disconnectBunker()
                                    } else {
                                        testBunkerConnection()
                                    }
                                },
                                disabled: bunkerURI.isEmpty || isConnectingBunker
                            )

                            if isConnectingBunker {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(WizardColors.accentPrimary)
                            }
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue, disabled: !canContinue)

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
    }

    private func generateNewIdentity() {
        guard let resultCStr = GenerateKeyPairC() else { return }
        let result = String(cString: resultCStr)
        let parts = result.split(separator: ":")
        guard parts.count == 2 else { return }
        let sk = String(parts[0])
        let pk = String(parts[1])

        if let pubData = Bech32.hexToData(pk),
           let generatedNpub = Bech32.encode(hrp: "npub", data: pubData) {
            npub = generatedNpub
        }

        if let secData = Bech32.hexToData(sk),
           let generatedNsec = Bech32.encode(hrp: "nsec", data: secData) {
            nsec = generatedNsec
        }

        withAnimation(WizardAnimations.springBounce) {
            generatedKeys = true
        }
    }

    private func signingMethodCard(method: SigningMethod, icon: String, title: String, subtitle: String) -> some View {
        let isSelected = selectedMethod == method
        return Button {
            withAnimation(WizardAnimations.springEnter) {
                selectedMethod = method
                signingMode = method == .nip46 ? "nip46" : "local"
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? WizardColors.accentPrimary : WizardColors.textSecondary)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(WizardColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? WizardColors.accentPrimary.opacity(0.5) : WizardColors.borderSubtle, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? WizardColors.accentGlow : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }

    private func testBunkerConnection() {
        isConnectingBunker = true
        bunkerError = nil
        bunkerConnected = false

        Task {
            do {
                let info = try NIP46Service.parseBunkerURI(bunkerURI)
                ConfigService.shared.config.nip46SignerPubkey = info.signerPubkey
                ConfigService.shared.config.nip46RelayURL = info.relayURL
                ConfigService.shared.config.nip46Secret = info.secret
                ConfigService.shared.config.signingMode = "nip46"
                ConfigService.shared.save()

                try await NIP46Service.shared.connect()
                let pubkey = try await NIP46Service.shared.getPublicKey()

                if let pubData = Bech32.hexToData(pubkey),
                   let generatedNpub = Bech32.encode(hrp: "npub", data: pubData) {
                    npub = generatedNpub
                }

                bunkerConnected = true
                isConnectingBunker = false
            } catch {
                bunkerError = error.localizedDescription
                isConnectingBunker = false
                ConfigService.shared.config.signingMode = "local"
            }
        }
    }

    private func disconnectBunker() {
        NIP46Service.shared.disconnect()
        bunkerConnected = false
        npub = ""
        ConfigService.shared.config.signingMode = "local"
        ConfigService.shared.config.nip46SignerPubkey = ""
        ConfigService.shared.config.nip46RelayURL = ""
        ConfigService.shared.config.nip46Secret = ""
    }
}

// MARK: - Step 3: Relay Configuration

private struct RelayConfigStep: View {
    @Binding var relayURL: String
    @Binding var macRelayURL: String
    let onContinue: () -> Void
    let onSkip: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            #if os(macOS)
            macOSRelayContent
            #else
            iOSRelayContent
            #endif

            WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)

            WizardSkipLink(title: String(localized: "setup.relay.skip")) {
                onSkip()
            }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
    }

    // MARK: macOS variant
    private var macOSRelayContent: some View {
        VStack(spacing: 20) {
            Text(String(localized: "setup.relay.mac.title"))
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            // Network diagram
            RelayDiagramMac(hasURL: !relayURL.isEmpty)
                .frame(height: 160)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            VStack(spacing: 8) {
                Text(String(localized: "setup.relay.mac.description1"))
                    .font(.system(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)

                Text(String(localized: "setup.relay.mac.description2"))
                    .font(.system(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            WizardInputField(label: String(localized: "setup.relay.mac.label"), text: $relayURL, placeholder: "relay.yourdomain.com")
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.4), value: appeared)

            Text(String(localized: "setup.relay.mac.hint"))
                .font(.system(size: 12))
                .foregroundColor(WizardColors.textMuted)
        }
    }

    // MARK: iOS variant
    private var iOSRelayContent: some View {
        VStack(spacing: 20) {
            Text(String(localized: "setup.relay.ios.title"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            // Network diagram
            RelayDiagramiOS(hasURL: !macRelayURL.isEmpty)
                .frame(height: 120)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            VStack(spacing: 8) {
                Text(String(localized: "setup.relay.ios.description1"))
                    .font(.system(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)

                Text(String(localized: "setup.relay.ios.description2"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            WizardInputField(label: String(localized: "setup.relay.ios.label"), text: $macRelayURL, placeholder: "wss://relay.yourdomain.com")
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.4), value: appeared)

            Text(String(localized: "setup.relay.ios.hint"))
                .font(.system(size: 12))
                .foregroundColor(WizardColors.textMuted)
        }
    }
}

// MARK: - Relay Diagrams

private struct RelayDiagramMac: View {
    let hasURL: Bool
    @State private var particlePhase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let centerX = size.width / 2
                let centerY = size.height / 2

                // Mac icon position
                let macX = centerX - 80
                let macY = centerY

                // Relay position
                let relayX = centerX
                let relayY = centerY + 40

                // Network position
                let netX = centerX + 100
                let netY = centerY - 10

                // Draw connection lines
                drawLine(context: context, from: CGPoint(x: macX, y: macY), to: CGPoint(x: relayX, y: relayY), color: WizardColors.accentPrimary.opacity(0.4))
                drawLine(context: context, from: CGPoint(x: relayX, y: relayY), to: CGPoint(x: netX, y: netY), color: WizardColors.accentPrimary.opacity(0.3))

                // Draw flowing particle
                let particleT = fmod(t * 0.3, 1.0)
                let px = macX + (netX - macX) * particleT
                let py = macY + (netY - macY) * particleT
                let particleRect = CGRect(x: px - 3, y: py - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: particleRect), with: .color(WizardColors.accentPrimary))

                // Globe connection when URL entered
                if hasURL {
                    let globeX = relayX
                    let globeY = centerY - 40
                    drawLine(context: context, from: CGPoint(x: relayX, y: relayY), to: CGPoint(x: globeX, y: globeY), color: WizardColors.accentPrimary.opacity(0.3))
                }

                // Network dots
                for i in 0..<6 {
                    let angle = Double(i) * (.pi * 2.0 / 6.0) + t * 0.05
                    let dx = netX + cos(angle) * 25
                    let dy = netY + sin(angle) * 25
                    let brightness = 0.3 + 0.2 * sin(t * 0.5 + Double(i))
                    let dotRect = CGRect(x: dx - 3, y: dy - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dotRect), with: .color(WizardColors.textMuted.opacity(brightness)))
                }
            }
            .overlay {
                // SF Symbol overlays
                VStack {
                    HStack(spacing: 80) {
                        VStack(spacing: 4) {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 32))
                                .foregroundColor(WizardColors.textPrimary)
                                .shadow(color: WizardColors.accentGlow, radius: 6)
                            Text(String(localized: "setup.relay.diagram.mac"))
                                .font(.system(size: 11))
                                .foregroundColor(WizardColors.textMuted)
                        }
                        .offset(y: -8)

                        VStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.system(size: 24))
                                .foregroundColor(WizardColors.textMuted)
                            Text(String(localized: "setup.relay.diagram.network"))
                                .font(.system(size: 11))
                                .foregroundColor(WizardColors.textMuted)
                        }
                        .offset(y: -20)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 16))
                            .foregroundColor(WizardColors.accentPrimary)
                        Text(String(localized: "setup.relay.diagram.relay"))
                            .font(.system(size: 11))
                            .foregroundColor(WizardColors.accentPrimary)
                    }
                    .offset(y: 8)

                    if hasURL {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 14))
                                .foregroundColor(WizardColors.accentPrimary.opacity(0.7))
                            Text(String(localized: "setup.relay.diagram.public"))
                                .font(.system(size: 10))
                                .foregroundColor(WizardColors.textMuted)
                        }
                        .offset(y: -50)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    private func drawLine(context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}

private struct RelayDiagramiOS: View {
    let hasURL: Bool

    var body: some View {
        HStack(spacing: 0) {
            // iPhone
            VStack(spacing: 4) {
                Image(systemName: "iphone")
                    .font(.system(size: 28))
                    .foregroundColor(WizardColors.textPrimary)
                Text(String(localized: "setup.relay.diagram.iphone"))
                    .font(.system(size: 11))
                    .foregroundColor(WizardColors.textMuted)
            }

            // Connection line
            VStack(spacing: 2) {
                Rectangle()
                    .fill(hasURL ? WizardColors.accentPrimary.opacity(0.5) : WizardColors.textMuted.opacity(0.3))
                    .frame(height: 2)
                    .overlay {
                        if !hasURL {
                            // Dashed line
                            Rectangle()
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                .foregroundColor(WizardColors.textMuted.opacity(0.4))
                        }
                    }
                if !hasURL {
                    Text("?")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(WizardColors.textMuted)
                }
            }
            .frame(width: 60)

            // Mac + Relay
            VStack(spacing: 4) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 28))
                    .foregroundColor(hasURL ? WizardColors.textPrimary : WizardColors.textMuted)
                    .shadow(color: hasURL ? WizardColors.accentGlow : .clear, radius: 4)
                HStack(spacing: 2) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 10))
                    Text(String(localized: "setup.relay.diagram.macRelay"))
                        .font(.system(size: 11))
                }
                .foregroundColor(hasURL ? WizardColors.accentPrimary : WizardColors.textMuted)
            }

            // Connection to network
            Rectangle()
                .fill(WizardColors.textMuted.opacity(0.3))
                .frame(width: 40, height: 2)

            // Network
            VStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 24))
                    .foregroundColor(WizardColors.textMuted)
                Text(String(localized: "setup.relay.diagram.nostr"))
                    .font(.system(size: 11))
                    .foregroundColor(WizardColors.textMuted)
            }
        }
        .padding(.vertical, 16)
    }
}

// MARK: - Step 4: Import Notes

private struct ImportNotesStep: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var activeTab = 0 // 0 = Network, 1 = Backup
    @State private var showingFileImporter = false
    @State private var isRestoring = false
    @State private var restoreCompleted = false
    @State private var restoreError: String?
    @State private var showRestoreError = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(String(localized: "setup.import.title"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            Text(String(localized: "setup.import.subtitle"))
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            // Tab bar
            HStack(spacing: 4) {
                tabPill(String(localized: "setup.import.tab.network"), isActive: activeTab == 0) { activeTab = 0 }
                tabPill(String(localized: "setup.import.tab.backup"), isActive: activeTab == 1) { activeTab = 1 }
            }
            .padding(3)
            .background(WizardColors.bgCard)
            .cornerRadius(10)
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.25), value: appeared)

            // Tab content
            Group {
                if activeTab == 0 {
                    networkImportContent
                } else {
                    backupRestoreContent
                }
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            WizardSkipLink(title: String(localized: "setup.import.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.zip, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                restoreBackup(from: url)
            case .failure(let error):
                restoreError = error.localizedDescription
                showRestoreError = true
            }
        }
        .alert(String(localized: "setup.import.alert.restoreFailed"), isPresented: $showRestoreError) {
            Button(String(localized: "setup.alert.ok"), role: .cancel) {}
        } message: {
            Text(restoreError ?? "Unknown error")
        }
        .alert(String(localized: "setup.import.alert.portConflict"), isPresented: $relayManager.isPortConflict) {
            Button(String(localized: "setup.import.alert.retry")) {
                relayManager.isPortConflict = false
                relayManager.importNotes(config: configService.config)
            }
            Button(String(localized: "setup.action.cancel"), role: .cancel) {
                relayManager.isPortConflict = false
                relayManager.cancelImport()
            }
        } message: {
            Text("Port \(configService.config.relayPort) is currently in use. Stop the other process or change the port in Settings.")
        }
    }

    @ViewBuilder
    private var networkImportContent: some View {
        VStack(spacing: 14) {
            if relayManager.isImporting || relayManager.importCompleted {
                VStack(spacing: 12) {
                    HStack {
                        Text(relayManager.importCompleted ? String(localized: "setup.import.done") : String(localized: "setup.import.importing"))
                            .font(.system(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                        Spacer()
                        Text("\(Int(relayManager.importProgress * 100))%")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(WizardColors.accentPrimary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(WizardColors.bgElevated)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(WizardColors.accentGradient)
                                .frame(width: geo.size.width * relayManager.importProgress, height: 6)
                        }
                    }
                    .frame(height: 6)

                    if !relayManager.importCompleted {
                        Text(relayManager.importStatusMessage)
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                            .lineLimit(2)
                    }

                    if relayManager.importCompleted {
                        WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
                    } else {
                        Button(action: { relayManager.cancelImport() }) {
                            Text(String(localized: "setup.import.cancelImport"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(WizardColors.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker(String(localized: "setup.import.startDate"), selection: Binding(
                        get: {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyy-MM-dd"
                            return formatter.date(from: configService.config.importStartDate) ?? Date()
                        },
                        set: {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyy-MM-dd"
                            configService.config.importStartDate = formatter.string(from: $0)
                        }
                    ), displayedComponents: .date)
                    .font(.system(size: 14))
                    .foregroundColor(WizardColors.textPrimary)
                    .colorScheme(.dark)

                    Divider().background(WizardColors.borderSubtle)

                    Text(String(localized: "setup.import.seedRelays"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)

                    RelayListEditor(relays: $configService.config.importSeedRelays)
                        .frame(minHeight: 80, maxHeight: 120)
                        .cornerRadius(8)
                }
                .padding(16)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))

                WizardPrimaryButton(title: String(localized: "setup.import.action")) {
                    configService.save()
                    relayManager.importNotes(config: configService.config)
                }
            }
        }
    }

    @ViewBuilder
    private var backupRestoreContent: some View {
        VStack(spacing: 14) {
            if isRestoring {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(WizardColors.accentPrimary)
                    Text(String(localized: "setup.import.restoring"))
                        .font(.system(size: 14))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
            } else if restoreCompleted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WizardColors.success)
                        .font(.title2)
                    Text(String(localized: "setup.import.restoreSuccess"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.success.opacity(0.5), lineWidth: 2))

                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
            } else {
                Button(action: {
                    #if os(macOS)
                    NSApp.activate(ignoringOtherApps: true)
                    #endif
                    showingFileImporter = true
                }) {
                    HStack {
                        Image(systemName: "doc.zipper")
                            .font(.title3)
                        Text(String(localized: "setup.import.chooseBackup"))
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(WizardColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(WizardColors.bgCard)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
                            .foregroundColor(WizardColors.borderSubtle)
                    )
                }
                .buttonStyle(.plain)

                Text(String(localized: "setup.import.backupHint"))
                    .font(.system(size: 12))
                    .foregroundColor(WizardColors.textMuted)
            }
        }
    }

    private func restoreBackup(from url: URL) {
        isRestoring = true
        guard url.startAccessingSecurityScopedResource() else {
            restoreError = "Permission denied to access the file."
            showRestoreError = true
            isRestoring = false
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { safeURL in
            do {
                if FileManager.default.fileExists(atPath: tempFile.path) {
                    try FileManager.default.removeItem(at: tempFile)
                }
                try FileManager.default.copyItem(at: safeURL, to: tempFile)
            } catch {
                copyError = error
            }
        }

        if let error = coordinationError ?? copyError {
            restoreError = "Failed to copy backup file: \(error.localizedDescription)"
            showRestoreError = true
            isRestoring = false
            return
        }

        configService.save()
        RelayProcessManager.shared.runBackupRestore(config: configService.config, inputPath: tempFile.path) { success in
            try? FileManager.default.removeItem(at: tempFile)
            Task { @MainActor in
                isRestoring = false
                if success {
                    configService.reload()
                    restoreCompleted = true
                } else {
                    restoreError = "Failed to restore backup. Check logs for details."
                    showRestoreError = true
                }
            }
        }
    }
}

// MARK: - Step 5: Mirror Media

private struct MirrorMediaStep: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var activeTab = 0
    @State private var blossomURL = "https://blossom.primal.net"
    @State private var showingFileImporter = false
    @State private var isSyncing = false
    @State private var syncCompleted = false
    @State private var syncError: String?
    @State private var showSyncError = false
    @State private var progressMessage = ""
    @State private var progressValue: Double = 0
    @State private var syncedCount = 0
    @State private var totalCount = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(String(localized: "setup.media.title"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            Text(String(localized: "setup.media.subtitle"))
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            // Tab bar
            HStack(spacing: 4) {
                tabPill(String(localized: "setup.media.tab.server"), isActive: activeTab == 0) { activeTab = 0 }
                tabPill(String(localized: "setup.media.tab.backup"), isActive: activeTab == 1) { activeTab = 1 }
            }
            .padding(3)
            .background(WizardColors.bgCard)
            .cornerRadius(10)
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.25), value: appeared)

            Group {
                if activeTab == 0 {
                    serverSyncContent
                } else {
                    backupImportContent
                }
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            WizardSkipLink(title: String(localized: "setup.media.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importMedia(from: url)
            case .failure(let error):
                syncError = error.localizedDescription
                showSyncError = true
            }
        }
        .alert(String(localized: "setup.media.alert.importFailed"), isPresented: $showSyncError) {
            Button(String(localized: "setup.alert.ok"), role: .cancel) {}
        } message: {
            Text(syncError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var serverSyncContent: some View {
        VStack(spacing: 14) {
            if isSyncing {
                VStack(spacing: 16) {
                    // Circular progress
                    ZStack {
                        Circle()
                            .stroke(WizardColors.bgElevated, lineWidth: 6)
                            .frame(width: 80, height: 80)
                        Circle()
                            .trim(from: 0, to: progressValue)
                            .stroke(WizardColors.accentGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(WizardAnimations.springGentle, value: progressValue)

                        Text("\(syncedCount) / \(totalCount)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(WizardColors.textPrimary)
                    }

                    Text(progressMessage.isEmpty ? String(localized: "setup.media.syncing") : progressMessage)
                        .font(.system(size: 13))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
            } else if syncCompleted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WizardColors.success)
                        .font(.title2)
                    Text(progressMessage.isEmpty ? String(localized: "setup.media.syncSuccess") : progressMessage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.success.opacity(0.5), lineWidth: 2))

                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
            } else {
                WizardInputField(label: String(localized: "setup.media.label.blossomURL"), text: $blossomURL, placeholder: "https://blossom.primal.net")

                WizardPrimaryButton(title: String(localized: "setup.media.syncAction")) {
                    startNetworkSync()
                }
            }
        }
    }

    @ViewBuilder
    private var backupImportContent: some View {
        VStack(spacing: 14) {
            if isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(WizardColors.accentPrimary)
                    Text(String(localized: "setup.media.importing"))
                        .font(.system(size: 14))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
            } else if syncCompleted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WizardColors.success)
                        .font(.title2)
                    Text(String(localized: "setup.media.importSuccess"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.success.opacity(0.5), lineWidth: 2))

                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
            } else {
                Button(action: {
                    #if os(macOS)
                    NSApp.activate(ignoringOtherApps: true)
                    #endif
                    showingFileImporter = true
                }) {
                    HStack {
                        Image(systemName: "doc.zipper")
                            .font(.title3)
                        Text(String(localized: "setup.media.chooseArchive"))
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(WizardColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(WizardColors.bgCard)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
                            .foregroundColor(WizardColors.borderSubtle)
                    )
                }
                .buttonStyle(.plain)

                Text(String(localized: "setup.media.backupHint"))
                    .font(.system(size: 12))
                    .foregroundColor(WizardColors.textMuted)
            }
        }
    }

    private func startNetworkSync() {
        isSyncing = true
        progressMessage = "Connecting..."
        progressValue = 0
        syncedCount = 0
        totalCount = 0

        let trimmedURL = blossomURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let _ = URL(string: trimmedURL) else {
            syncError = "Invalid Blossom server URL."
            showSyncError = true
            isSyncing = false
            return
        }

        if !configService.config.blossomMirrors.contains(trimmedURL) {
            configService.config.blossomMirrors.append(trimmedURL)
            configService.save()
            NostrService.shared.publishServerList()
        }

        Task {
            let blossomService = BlossomService(configService: configService, nostrService: nostrService)
            let mirroredCount = await blossomService.mirrorAllFromExternal { completed, total in
                syncedCount = completed
                totalCount = total
                progressValue = total > 0 ? Double(completed) / Double(total) : 0
                progressMessage = "Mirrored \(completed) of \(total) files..."
            }

            isSyncing = false
            syncCompleted = true
            progressMessage = "Synced \(mirroredCount) files."
        }
    }

    private func importMedia(from url: URL) {
        isSyncing = true
        guard url.startAccessingSecurityScopedResource() else {
            syncError = "Permission denied to access the file."
            showSyncError = true
            isSyncing = false
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try FileManager.default.removeItem(at: tempFile)
            }
            try FileManager.default.copyItem(at: url, to: tempFile)
        } catch {
            syncError = "Failed to copy media archive: \(error.localizedDescription)"
            showSyncError = true
            isSyncing = false
            return
        }

        RelayProcessManager.shared.runBlossomImportStrippingExtensions(config: configService.config, inputPath: tempFile.path) { success in
            try? FileManager.default.removeItem(at: tempFile)
            Task { @MainActor in
                isSyncing = false
                if success {
                    syncCompleted = true
                } else {
                    syncError = "Failed to import media. Check logs for details."
                    showSyncError = true
                }
            }
        }
    }
}

// MARK: - Step 6: Wallet Setup

private struct WalletSetupStep: View {
    @Binding var nwcURI: String
    @Binding var cashuMintURL: String
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var lightningExpanded = false
    @State private var cashuExpanded = false
    @State private var nwcStatus: ConnectionStatus = .idle

    enum ConnectionStatus {
        case idle, testing, connected, failed
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(String(localized: "setup.wallet.title"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            Text(String(localized: "setup.wallet.subtitle"))
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            // Lightning (NWC) section
            VStack(spacing: 0) {
                Button(action: { withAnimation(WizardAnimations.springEnter) { lightningExpanded.toggle() } }) {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 18))
                            .foregroundColor(WizardColors.accentPrimary)
                        Text(String(localized: "setup.wallet.lightning.title"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)
                        Spacer()
                        Image(systemName: lightningExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)

                if lightningExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider().background(WizardColors.borderSubtle)

                        WizardInputField(label: String(localized: "setup.wallet.lightning.label"), text: $nwcURI, placeholder: "nostr+walletconnect://...")

                        Text(String(localized: "setup.wallet.lightning.hint"))
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)

                        // Connection status
                        if nwcStatus == .testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).tint(WizardColors.accentPrimary)
                                Text(String(localized: "setup.wallet.lightning.connecting"))
                                    .font(.system(size: 13))
                                    .foregroundColor(WizardColors.textSecondary)
                            }
                        } else if nwcStatus == .connected {
                            HStack(spacing: 6) {
                                Circle().fill(WizardColors.success).frame(width: 8, height: 8)
                                Text(String(localized: "setup.wallet.lightning.connected"))
                                    .font(.system(size: 13))
                                    .foregroundColor(WizardColors.success)
                            }
                        } else if nwcStatus == .failed {
                            HStack(spacing: 6) {
                                Circle().fill(WizardColors.error).frame(width: 8, height: 8)
                                Text(String(localized: "setup.wallet.lightning.failed"))
                                    .font(.system(size: 13))
                                    .foregroundColor(WizardColors.error)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.springEnter.delay(0.3), value: appeared)

            // Cashu Ecash section
            VStack(spacing: 0) {
                Button(action: { withAnimation(WizardAnimations.springEnter) { cashuExpanded.toggle() } }) {
                    HStack {
                        Image(systemName: "centsign.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(WizardColors.accentPrimary)
                        Text(String(localized: "setup.wallet.cashu.title"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)
                        Spacer()
                        Image(systemName: cashuExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)

                if cashuExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider().background(WizardColors.borderSubtle)

                        WizardInputField(label: String(localized: "setup.wallet.cashu.label"), text: $cashuMintURL, placeholder: "https://mint.example.com")

                        Text(String(localized: "setup.wallet.cashu.hint"))
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.springEnter.delay(0.38), value: appeared)

            WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)

            WizardSkipLink(title: String(localized: "setup.wallet.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Step 6b: Push Notifications (iOS only)

private struct PushNotificationStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void
    @State private var appeared = false
    @State private var dmEnabled = true
    @State private var zapEnabled = true
    @State private var mentionEnabled = true

    var body: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 40)

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56))
                .foregroundColor(WizardColors.accentPrimary)
                .scaleEffect(appeared ? 1.0 : 0.3)
                .offset(y: appeared ? 0 : -20)
                .animation(WizardAnimations.springBounce.delay(0.1), value: appeared)

            Text(String(localized: "setup.notifications.title"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            Text(String(localized: "setup.notifications.subtitle"))
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.4), value: appeared)

            // Toggle cards
            VStack(spacing: 0) {
                notificationToggle(icon: "bubble.left.fill", label: String(localized: "setup.notifications.directMessages"), isOn: $dmEnabled)
                Divider().background(WizardColors.borderSubtle).padding(.horizontal, 16)
                notificationToggle(icon: "bolt.fill", label: String(localized: "setup.notifications.zaps"), isOn: $zapEnabled)
                Divider().background(WizardColors.borderSubtle).padding(.horizontal, 16)
                notificationToggle(icon: "at", label: String(localized: "setup.notifications.mentions"), isOn: $mentionEnabled)
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.springEnter.delay(0.5), value: appeared)

            WizardPrimaryButton(title: String(localized: "setup.notifications.enable"), action: onContinue)

            WizardSkipLink(title: String(localized: "setup.notifications.skip")) { onSkip() }

            Spacer()
        }
        .onAppear { appeared = true }
    }

    private func notificationToggle(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(WizardColors.accentPrimary)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .tint(WizardColors.accentPrimary)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Step 7: Complete

private struct CompleteStep: View {
    let isBrowseMode: Bool
    let onLaunch: () -> Void
    @State private var showContent = false
    @State private var ringScale: CGFloat = 0
    @State private var ringOpacity: Double = 1
    @State private var ring2Scale: CGFloat = 0
    @State private var ring2Opacity: Double = 1
    @State private var ring3Scale: CGFloat = 0
    @State private var ring3Opacity: Double = 1
    @State private var buttonPulse: Bool = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 40)

            // Celebration animation
            ZStack {
                // Expanding rings
                Circle()
                    .stroke(WizardColors.accentPrimary, lineWidth: 2)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                    .frame(width: 120, height: 120)

                Circle()
                    .stroke(WizardColors.accentPrimary.opacity(0.6), lineWidth: 1.5)
                    .scaleEffect(ring2Scale)
                    .opacity(ring2Opacity)
                    .frame(width: 120, height: 120)

                Circle()
                    .stroke(WizardColors.accentPrimary.opacity(0.3), lineWidth: 1)
                    .scaleEffect(ring3Scale)
                    .opacity(ring3Opacity)
                    .frame(width: 120, height: 120)

                // Checkmark seal
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(WizardColors.accentGradient)
                    .scaleEffect(showContent ? 1.0 : 0)
                    .animation(WizardAnimations.springBounce.delay(0.5), value: showContent)
            }

            // Title
            Text(isBrowseMode ? String(localized: "setup.complete.title.browse") : String(localized: "setup.complete.title.full"))
                .font(.system(size: isIOSDevice ? 28 : 32, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 15)
                .animation(WizardAnimations.springEnter.delay(0.8), value: showContent)

            // Summary bullets
            VStack(alignment: .leading, spacing: 14) {
                if isBrowseMode {
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.browse.connected"), color: WizardColors.success, delay: 1.0)
                    completeBullet(icon: "info.circle.fill", text: String(localized: "setup.complete.browse.upgradeHint"), color: WizardColors.accentPrimary, delay: 1.1)
                } else {
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.relayRunning"), color: WizardColors.success, delay: 1.0)
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.dmsEnabled"), color: WizardColors.success, delay: 1.1)
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.blossomActive"), color: WizardColors.success, delay: 1.2)
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.postsBroadcast"), color: WizardColors.success, delay: 1.3)
                }
            }

            Spacer()

            #if os(macOS)
            Text(String(localized: "setup.complete.menuBarHint"))
                .font(.system(size: 14))
                .foregroundColor(WizardColors.accentPrimary.opacity(0.8))
                .opacity(showContent ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(1.5), value: showContent)
            #endif

            // Launch button with pulse
            WizardPrimaryButton(title: String(localized: "setup.complete.launch"), action: onLaunch)
                .shadow(color: buttonPulse ? WizardColors.accentGlow : .clear, radius: buttonPulse ? 16 : 8)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(1.6), value: showContent)

            Spacer().frame(height: 16)
        }
        .onAppear {
            showContent = true

            // Ring 1
            withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                ringScale = 2.0
                ringOpacity = 0
            }
            // Ring 2
            withAnimation(.easeOut(duration: 0.8).delay(0.35)) {
                ring2Scale = 2.0
                ring2Opacity = 0
            }
            // Ring 3
            withAnimation(.easeOut(duration: 0.8).delay(0.5)) {
                ring3Scale = 2.0
                ring3Opacity = 0
            }

            // Button pulse loop
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    buttonPulse = true
                }
            }

            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                FloatingArrowController.shared.show()
            }
            #endif
        }
    }

    private func completeBullet(icon: String, text: String, color: Color, delay: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 18))
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textPrimary)
        }
        .opacity(showContent ? 1 : 0)
        .offset(x: showContent ? 0 : -20)
        .animation(WizardAnimations.springEnter.delay(delay), value: showContent)
    }
}

// MARK: - Shared Tab Pill

private func tabPill(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(isActive ? WizardColors.textPrimary : WizardColors.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isActive ? WizardColors.accentPrimary : Color.clear)
            .cornerRadius(8)
    }
    .buttonStyle(.plain)
}

// MARK: - Legacy Components (kept for compatibility)

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.havenPurple)
                .frame(width: 40)
                .scaleEffect(isHovered ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Text(description)
                    .font(.caption)
                    .foregroundColor(isHovered ? .primary : .secondary)
            }

            Spacer()
        }
        .padding()
        .background(isHovered ? Color.havenPurplePale : Color.platformControlBackground)
        .cornerRadius(12)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct SuccessBullet: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.havenPurple)
            Text(text)
                .font(.subheadline)
        }
    }
}

struct DatabaseOption: View {
    @Binding var selected: String
    let value: String
    let title: String
    let description: String
    @State private var isHovered = false

    var body: some View {
        Button(action: { selected = value }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.headline, design: .rounded))
                    Text(description)
                        .font(.caption)
                        .foregroundColor(selected == value ? .primary : .secondary)
                }
                Spacer()
                Image(systemName: selected == value ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected == value ? .havenPurple : (isHovered ? .primary : .secondary))
                    .scaleEffect(selected == value ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
            }
            .padding()
            .background(selected == value ? Color.havenPurplePale.opacity(0.5) : (isHovered ? Color.platformControlBackground.opacity(0.8) : Color.platformControlBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected == value ? Color.havenPurple : (isHovered ? Color.gray.opacity(0.5) : Color.clear), lineWidth: 2)
            )
            .scaleEffect(isHovered && selected != value ? 1.01 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
