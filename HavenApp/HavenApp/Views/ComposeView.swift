import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation

/// Imports a PhotosPickerItem video as a file URL on disk, avoiding loading the
/// entire video into memory. The system writes the picked file into our app's
/// temp area; we copy it to a known location we can clean up later.
struct ImportedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return ImportedVideoFile(url: dest)
        }
    }
}

struct ComposeView: View {
    @Environment(\.dismiss) var dismiss
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager

    @State private var content: String = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var attachments: [Attachment] = []
    @State private var isUploading = false
    @State private var isPosting = false
    @State private var error: String?
    @FocusState private var isTextEditorFocused: Bool
    
    @StateObject private var uploadInfoProvider = MediaUploadsIndicatorInfoProvider()

    // Blossom media picker state
    @State private var showBlossomPicker = false
    @State private var blossomMedia: [MediaItem] = []
    @State private var isLoadingBlossomMedia = false

    // @mention state
    @State private var mentionQuery: String? = nil          // nil = popup hidden
    @State private var mentionResults: [FeedProfile] = []
    @State private var taggedPubkeys: [String] = []         // hex pubkeys of tagged users

    // Draft auto-save state
    @State private var draftId: String? = nil
    @State private var autoSaveTask: Task<Void, Never>? = nil
    @State private var lastSavedContent: String = ""
    @State private var showingDraftPicker = false
    @StateObject private var draftService = DraftService.shared

    // Draft-loaded reply/quote context (overrides init-provided values)
    @State private var draftReplyTo: FeedNote? = nil
    @State private var draftQuoteTo: FeedNote? = nil

    private var blossomService: BlossomService {
        BlossomService(configService: configService, nostrService: nostrService)
    }

    // Optional: for replies
    var replyTo: FeedNote?
    // Optional: for quote posts
    var quoteTo: FeedNote?

    /// Effective reply target: draft-loaded value takes precedence over init-provided value.
    private var effectiveReplyTo: FeedNote? { draftReplyTo ?? replyTo }
    /// Effective quote target: draft-loaded value takes precedence over init-provided value.
    private var effectiveQuoteTo: FeedNote? { draftQuoteTo ?? quoteTo }
    // Optional: pre-filled content (used when editing a pending post)
    var initialContent: String = ""
    // Optional: draft ID when restoring a saved draft
    var restoredDraftId: String? = nil
    
    struct Attachment: Identifiable {
        let id = UUID()
        // Exactly one of `data` or `fileURL` is set. Images use `data` (small,
        // possibly transcoded); videos use `fileURL` so they stream from disk.
        let data: Data?
        let fileURL: URL?
        var type: UTType
        var url: URL?
        var isUploaded: Bool = false
        var thumbnail: PlatformImage?
    }
    
    var body: some View {
        Group {
            #if os(macOS)
            composeContent
                .frame(minWidth: 500, idealWidth: 500, minHeight: 400, idealHeight: 450)
            #else
            NavigationView {
                composeContent
            }
            #endif
        }
    }

    private var composeContent: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            header
            #endif

            ScrollView {
                VStack(spacing: 16) {
                    if let parent = effectiveReplyTo {
                        replyHeader(parent: parent)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(
                            url: nostrService.profiles[configService.activeAccountHexPubkey]?.pictureURL,
                            pubkey: configService.activeAccountHexPubkey
                        )
                        .frame(width: 36, height: 36)
                        .contextMenu {
                            if configService.allAccountNpubs.count > 1 {
                                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                                    let isOwner = npub == configService.config.ownerNpub
                                    let activeAccountNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let isActive = activeAccountNpub.isEmpty ? isOwner : npub == activeAccountNpub
                                    let hex = Bech32.decode(npub)?.hexString ?? ""
                                    let name = nostrService.profiles[hex]?.bestName ?? (isOwner ? "Owner" : String(npub.prefix(8)))

                                    Button {
                                        configService.switchActiveAccount(to: npub)
                                    } label: {
                                        if isActive {
                                            Label(name, systemImage: "checkmark")
                                        } else {
                                            Text(name)
                                        }
                                    }
                                }
                            } else {
                                Text("No other accounts")
                            }
                        }

                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("What's happening?")
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .padding(.top, 10)
                                    .padding(.leading, 4)
                            }

                            TextEditor(text: $content)
                                .focused($isTextEditorFocused)
                                .font(.appSystem(size: 16))
                                .frame(minHeight: 200)
                                .scrollContentBackground(.hidden)
                                .accessibilityLabel("Post content")
                                .onChange(of: content) { _, newValue in
                                    updateMentionQuery(in: newValue)
                                    scheduleAutoSave(newValue)
                                }
                        }
                    }

                    if !attachments.isEmpty {
                        attachmentGrid
                    }

                    if let quoted = effectiveQuoteTo {
                        QuotedNoteView(note: quoted)
                            .environmentObject(nostrService)
                    }
                }
                .padding(20)
            }

            // @mention popup — inline above footer so it stays visible above the keyboard
            if let _ = mentionQuery, !mentionResults.isEmpty {
                mentionPopup
            }

            footer
        }
            .background(Color.platformSecondaryGroupedBackground)
            .navigationTitle(effectiveReplyTo != nil ? "Reply" : effectiveQuoteTo != nil ? "Quote" : "New Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    HStack(spacing: 8) {
                        Button("Cancel") { performDismiss() }

                        if !draftService.draftsForActiveAccount.isEmpty && draftId == nil {
                            Button {
                                showingDraftPicker = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text")
                                        .font(.appSystem(size: 12))
                                    Text("\(draftService.draftsForActiveAccount.count)")
                                        .font(.appCaption2.bold())
                                }
                                .foregroundColor(.havenPurple)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.havenPurple.opacity(0.12))
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { postNote() }
                        .disabled((content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) || isPosting)
                        .fontWeight(.bold)
                }
                #endif
            }
            .alert("Error", isPresented: Binding<Bool>(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                if let error = error {
                    Text(error)
                }
            }
            .onAppear {
                if !initialContent.isEmpty {
                    content = initialContent
                    extractMentionsFromContent(initialContent)
                }
                if let restored = restoredDraftId {
                    draftId = restored
                    lastSavedContent = initialContent.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                Task { await draftService.fetchDrafts() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isTextEditorFocused = true
                }
            }
            .onDisappear {
                // performDismiss already handles auto-save cancellation and final save.
                cleanupAttachmentTempFiles()
            }
            .sheet(isPresented: $showBlossomPicker) {
                BlossomMediaPickerSheet(
                    blossomMedia: $blossomMedia,
                    isLoading: $isLoadingBlossomMedia,
                    onSelect: { item in
                        let url = item.shareURL(with: configService).absoluteString
                        if content.isEmpty || content.hasSuffix("\n") || content.hasSuffix(" ") {
                            content += url
                        } else {
                            content += " " + url
                        }
                        showBlossomPicker = false
                    },
                    onAppearLoad: { loadBlossomMedia() }
                )
            }
            .sheet(isPresented: $showingDraftPicker) {
                DraftPickerView(
                    onSelect: { draft in
                        loadDraft(draft)
                    },
                    onDelete: { draft in
                        Task { await DraftService.shared.deleteDraft(id: draft.id) }
                    }
                )
            }

    }

    // MARK: - @mention popup

    private var mentionPopup: some View {
        VStack(spacing: 0) {
            ForEach(mentionResults.prefix(5)) { profile in
                Button {
                    insertMention(profile)
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(url: profile.pictureURL, pubkey: profile.pubkey, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.bestName)
                                .font(.appSystem(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                            if let nip05 = profile.nip05, !nip05.isEmpty {
                                Text(nip05)
                                    .font(.appSystem(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if profile.id != mentionResults.prefix(5).last?.id {
                    Divider().padding(.horizontal, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.platformControlBackground)
                .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.havenPurple.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: mentionResults.count)
    }

    /// Called every time `content` changes — finds the @query at the cursor tail.
    private func updateMentionQuery(in text: String) {
        // Look for the last `@` that hasn't been terminated by whitespace or newline
        guard let atRange = text.range(of: "@", options: .backwards) else {
            mentionQuery = nil
            mentionResults = []
            return
        }

        let queryStart = text.index(after: atRange.lowerBound)
        let tail = String(text[queryStart...])

        // If there is whitespace or newline after the @, the mention is done
        if tail.contains(" ") || tail.contains("\n") {
            mentionQuery = nil
            mentionResults = []
            return
        }

        mentionQuery = tail
        filterMentionResults(query: tail)
    }

    private func filterMentionResults(query: String) {
        let followed = FeedService.shared.followedPubkeys
        var candidatePubkeys = Set(followed)

        // Include thread participants when replying so mentions work for
        // people in the conversation even if you don't follow them.
        if let parent = effectiveReplyTo {
            candidatePubkeys.insert(parent.pubkey)
            for tag in parent.tags where tag.count >= 2 && tag[0] == "p" {
                candidatePubkeys.insert(tag[1])
            }
        }

        // Exclude self
        candidatePubkeys.remove(nostrService.activeHexPubkey)

        let allProfiles = candidatePubkeys.compactMap { nostrService.profiles[$0] }

        if query.isEmpty {
            // Show first 5 profiles when query is empty (just typed @)
            // Prioritize thread participants for replies
            if let parent = effectiveReplyTo {
                var threadPubkeys: [String] = [parent.pubkey]
                for tag in parent.tags where tag.count >= 2 && tag[0] == "p" {
                    if !threadPubkeys.contains(tag[1]) {
                        threadPubkeys.append(tag[1])
                    }
                }
                threadPubkeys.removeAll { $0 == nostrService.activeHexPubkey }
                let threadProfiles = threadPubkeys.compactMap { nostrService.profiles[$0] }
                let followedProfiles = followed.compactMap { nostrService.profiles[$0] }
                // Thread participants first, then followed
                var combined: [FeedProfile] = threadProfiles
                for p in followedProfiles where !combined.contains(where: { $0.pubkey == p.pubkey }) {
                    combined.append(p)
                }
                mentionResults = Array(combined.prefix(5))
            } else {
                mentionResults = Array(allProfiles.prefix(5))
            }
        } else {
            let lower = query.lowercased()
            mentionResults = allProfiles.filter { profile in
                (profile.bestName.lowercased().contains(lower)) ||
                (profile.name?.lowercased().contains(lower) ?? false) ||
                (profile.nip05?.lowercased().contains(lower) ?? false)
            }
        }
    }

    /// Extracts hex pubkeys from nostr:npub1... and nostr:nprofile1... URIs in the
    /// given text and populates `taggedPubkeys` so p-tags are generated when posting.
    private func extractMentionsFromContent(_ text: String) {
        let npubPattern = try! NSRegularExpression(pattern: "nostr:(npub1[a-z0-9]+)")
        let nprofilePattern = try! NSRegularExpression(pattern: "nostr:(nprofile1[a-z0-9]+)")
        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)

        for match in npubPattern.matches(in: text, range: range) {
            let bech32 = nsString.substring(with: match.range(at: 1))
            if let decoded = Bech32.decode(bech32), !taggedPubkeys.contains(decoded.hexString) {
                taggedPubkeys.append(decoded.hexString)
            }
        }

        for match in nprofilePattern.matches(in: text, range: range) {
            let bech32 = nsString.substring(with: match.range(at: 1))
            if let decoded = Bech32.decode(bech32) {
                // TLV: type 0 = pubkey (32 bytes)
                var data = decoded.data
                while data.count >= 2 {
                    let type = data.removeFirst()
                    let length = Int(data.removeFirst())
                    if data.count >= length {
                        let value = data.prefix(length)
                        if type == 0 && length == 32 {
                            let hex = value.map { String(format: "%02x", $0) }.joined()
                            if !taggedPubkeys.contains(hex) {
                                taggedPubkeys.append(hex)
                            }
                            break
                        }
                        data.removeFirst(length)
                    } else {
                        break
                    }
                }
            }
        }
    }

    private func insertMention(_ profile: FeedProfile) {
        // Encode pubkey as npub
        guard let data = Bech32.hexToData(profile.pubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }

        // Replace the trailing `@query` with `nostr:npub1...`
        if let atRange = content.range(of: "@", options: .backwards) {
            content = String(content[content.startIndex..<atRange.lowerBound])
                + "nostr:\(npub) "
        } else {
            content += "nostr:\(npub) "
        }

        // Track the mention so we can add the `p` tag
        if !taggedPubkeys.contains(profile.pubkey) {
            taggedPubkeys.append(profile.pubkey)
        }

        withAnimation {
            mentionQuery = nil
            mentionResults = []
        }
    }

    #if os(macOS)
    private var header: some View {
        HStack {
            Button("Cancel") { performDismiss() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

            if !draftService.draftsForActiveAccount.isEmpty && draftId == nil {
                Button {
                    showingDraftPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.appSystem(size: 12))
                        Text("\(draftService.draftsForActiveAccount.count)")
                            .font(.appCaption2.bold())
                    }
                    .foregroundColor(.havenPurple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.havenPurple.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text(effectiveReplyTo != nil ? "Reply" : effectiveQuoteTo != nil ? "Quote" : "New Note")
                .font(.appHeadline)
            
            Spacer()
            
            Button("Post") { postNote() }
                .buttonStyle(.borderedProminent)
                .tint(Color.havenPurple)
                .disabled((content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) || isPosting)
        }
        .padding()
        .background(Color.platformControlBackground.opacity(0.5))
    }
    #endif

    private var footer: some View {
        let purple = Color.havenPurple
        let title3 = Font.appTitle3
        return HStack(spacing: 12) {
            PhotosPicker(selection: $selectedItems, maxSelectionCount: max(1, 4 - attachments.count), matching: .images) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(title3)
                    .foregroundColor(purple)
                    .padding(10)
                    .background(purple.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            PhotosPicker(selection: $selectedItems, maxSelectionCount: max(1, 4 - attachments.count), matching: .videos) {
                Image(systemName: "video.fill")
                    .font(title3)
                    .foregroundColor(purple)
                    .padding(10)
                    .background(purple.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button(action: handlePasteFromClipboard) {
                Image(systemName: "wand.and.stars")
                    .font(.appTitle3)
                    .foregroundColor(attachments.count >= 4 ? purple.opacity(0.3) : purple)
                    .padding(10)
                    .background(purple.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(attachments.count >= 4)

            Spacer()
            
            if isUploading, let msg = uploadInfoProvider.uploadMessage {
                Text(msg)
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
                ProgressView().controlSize(.small).padding(.trailing, 8)
            } else if isPosting {
                Text("Posting note...")
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
                ProgressView().controlSize(.small).padding(.trailing, 8)
            }
            
            Button(action: { showBlossomPicker = true }) {
                Image(systemName: "camera.macro")
                    .font(.appTitle3)
                    .foregroundColor(purple)
                    .padding(10)
                    .background(purple.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.platformControlBackground)
        .onChange(of: selectedItems) { _, _ in loadSelectedItems() }
    }
    
    private func replyHeader(parent: FeedNote) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                AvatarView(url: nostrService.profiles[parent.pubkey]?.pictureURL, pubkey: parent.pubkey)
                    .frame(width: 32, height: 32)
                
                Rectangle()
                    .fill(Color.havenPurple.opacity(0.3))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Replying to \(nostrService.profiles[parent.pubkey]?.bestName ?? String(parent.pubkey.prefix(8)))...")
                    .font(.appSystem(size: 13, weight: .bold))
                    .foregroundColor(.secondary)
                
                Text(parent.content)
                    .font(.appSystem(size: 13, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(3)
                    .padding(.bottom, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.havenPurple.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple.opacity(0.15), lineWidth: 1)
        )
    }
    
    private var attachmentGrid: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = attachment.thumbnail {
                                Image(platformImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else if let data = attachment.data, let img = PlatformImage(data: data) {
                                Image(platformImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                ZStack {
                                    Color.platformSecondaryGroupedBackground
                                    Image(systemName: attachment.type.conforms(to: .movie) || attachment.type.conforms(to: .video) ? "video.fill" : "doc.fill")
                                        .font(.appTitle)
                                        .foregroundColor(Color.havenPurple.opacity(0.8))
                                }
                                .frame(width: 100, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.havenPurple.opacity(0.3), lineWidth: 1)
                                )
                            }
                        }
                        
                        if attachment.type.conforms(to: .movie) || attachment.type.conforms(to: .video) {
                            ZStack {
                                Circle()
                                    .fill(.black.opacity(0.4))
                                    .frame(width: 32, height: 32)
                                
                                Image(systemName: "play.fill")
                                    .font(.appSystem(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .offset(x: 1)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                        Button {
                            if let fileURL = attachment.fileURL {
                                try? FileManager.default.removeItem(at: fileURL)
                            }
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .padding(4)
                    }
                }
            }
            .padding()
        }
        .frame(height: 120)
    }
    
    private func loadSelectedItems() {
        for item in selectedItems {
            // Check ALL supported content types — .first can be a non-video type
            // even for videos (e.g. HEVC, iCloud items, combined pickers).
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            let contentType = item.supportedContentTypes.first ?? .image

            if isVideo {
                loadVideoItem(item, contentType: contentType)
            } else {
                loadImageItem(item, contentType: contentType)
            }
        }
        selectedItems = []
    }

    private func loadVideoItem(_ item: PhotosPickerItem, contentType: UTType) {
        Task {
            // Try file-based ImportedVideoFile first, fall back to Data if the system
            // can't provide a .movie file representation (HEVC transcoding, iCloud, etc.).
            if let video = try? await item.loadTransferable(type: ImportedVideoFile.self) {
                let derivedType = UTType(filenameExtension: video.url.pathExtension) ?? contentType
                let videoURL = video.url
                let thumbnail = await self.generateVideoThumbnail(url: videoURL)
                await MainActor.run {
                    self.attachments.append(Attachment(
                        data: nil,
                        fileURL: videoURL,
                        type: derivedType,
                        thumbnail: thumbnail
                    ))
                }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                // Fallback: write bytes to temp file so the upload can stream from disk.
                let videoType = item.supportedContentTypes.first { $0.conforms(to: .movie) || $0.conforms(to: .video) } ?? contentType
                let ext = videoType.preferredFilenameExtension ?? "mp4"
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                    .appendingPathExtension(ext)
                do {
                    try data.write(to: dest)
                    let derivedType = UTType(filenameExtension: ext) ?? videoType
                    let thumbnail = await self.generateVideoThumbnail(url: dest)
                    await MainActor.run {
                        self.attachments.append(Attachment(
                            data: nil,
                            fileURL: dest,
                            type: derivedType,
                            thumbnail: thumbnail
                        ))
                    }
                } catch {
                    await MainActor.run {
                        self.error = "Failed to load video: \(error.localizedDescription)"
                    }
                }
            } else {
                await MainActor.run {
                    self.error = "Failed to load video file."
                }
            }
        }
    }

    private func loadImageItem(_ item: PhotosPickerItem, contentType: UTType) {
        item.loadTransferable(type: Data.self) { result in
            switch result {
            case .success(let data):
                guard let data = data else { return }
                DispatchQueue.main.async {
                    var finalData = data
                    var finalType = contentType

                    // Convert HEIC/HEIF to JPEG
                    if contentType.conforms(to: .heic) || contentType.conforms(to: .heif) {
                        #if os(iOS)
                        if let image = UIImage(data: data),
                           let jpegData = image.jpegData(compressionQuality: 0.8) {
                            finalData = jpegData
                            finalType = .jpeg
                        }
                        #elseif os(macOS)
                        if let image = NSImage(data: data),
                           let tiffData = image.tiffRepresentation,
                           let bitmapRep = NSBitmapImageRep(data: tiffData),
                           let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                            finalData = jpegData
                            finalType = .jpeg
                        }
                        #endif
                    }

                    self.attachments.append(Attachment(
                        data: finalData,
                        fileURL: nil,
                        type: finalType,
                        thumbnail: nil
                    ))
                }
            case .failure(let error):
                #if DEBUG
                print("Failed to load media: \(error)")
                #endif
                DispatchQueue.main.async {
                    self.error = "Failed to load media: \(error.localizedDescription)"
                }
            }
        }
    }
    
    /// Computes the SHA256 of a file by streaming it in 1 MB chunks so large
    /// videos don't sit fully in memory.
    nonisolated static func streamingSHA256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    private func cleanupAttachmentTempFiles() {
        for attachment in attachments {
            if let fileURL = attachment.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func generateVideoThumbnail(url: URL) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            let asset = AVAsset(url: url)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.0, preferredTimescale: 600)
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, error in
                if let cgImage = cgImage {
                    #if os(macOS)
                    continuation.resume(returning: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
                    #else
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                    #endif
                } else {
                    #if DEBUG
                    if let error = error {
                        print("Error generating video thumbnail: \(error)")
                    }
                    #endif
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    private func handlePasteFromClipboard() {
        guard attachments.count < 4 else { return }

        if PlatformClipboard.hasImage(), let imageData = PlatformClipboard.getImageData() {
            // Detect actual image format from data magic bytes
            let detectedType: UTType
            if imageData.count >= 6 {
                let gif87 = Data("GIF87a".utf8)
                let gif89 = Data("GIF89a".utf8)
                let prefix = imageData.prefix(6)
                if prefix == gif87 || prefix == gif89 {
                    detectedType = .gif
                } else if imageData.prefix(4) == Data([137, 80, 78, 71]) { // PNG magic
                    detectedType = .png
                } else {
                    detectedType = .jpeg
                }
            } else {
                detectedType = .jpeg
            }
            attachments.append(Attachment(
                data: imageData,
                fileURL: nil,
                type: detectedType
            ))
        } else if let clipboardString = PlatformClipboard.getString() {
            let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed),
               (url.scheme == "http" || url.scheme == "https") {
                let ext = url.pathExtension.lowercased()
                let hasKnownExt = SupportedMediaFormats.allExtensions.contains(ext)
                // Media URL — download and add as attachment
                Task {
                    guard let (data, response) = try? await URLSession.shared.data(from: url) else {
                        await MainActor.run { error = "Failed to download media from URL" }
                        return
                    }
                    // Determine the media type from extension, or fall back to Content-Type
                    let httpResponse = response as? HTTPURLResponse
                    let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    let resolvedExt: String
                    if hasKnownExt {
                        resolvedExt = ext
                    } else if let mimeExt = SupportedMediaFormats.extension(forMime: contentType) {
                        resolvedExt = mimeExt
                    } else if !hasKnownExt {
                        // Not a recognized media URL
                        await MainActor.run { error = "Clipboard does not contain an image or media URL" }
                        return
                    } else {
                        resolvedExt = ext
                    }
                    let isVideo = SupportedMediaFormats.videoExtensions.contains(resolvedExt)
                    if isVideo {
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("haven-paste-\(UUID().uuidString)")
                            .appendingPathExtension(resolvedExt)
                        try? data.write(to: tempURL)
                        let thumbnail = await generateVideoThumbnail(url: tempURL)
                        let derivedType = UTType(filenameExtension: resolvedExt) ?? .mpeg4Movie
                        await MainActor.run {
                            attachments.append(Attachment(
                                data: nil,
                                fileURL: tempURL,
                                type: derivedType,
                                thumbnail: thumbnail
                            ))
                        }
                    } else {
                        let derivedType = UTType(filenameExtension: resolvedExt) ?? .jpeg
                        await MainActor.run {
                            attachments.append(Attachment(
                                data: data,
                                fileURL: nil,
                                type: derivedType
                            ))
                        }
                    }
                }
            } else {
                error = "Clipboard does not contain an image or media URL"
            }
        } else {
            error = "Clipboard is empty"
        }
    }

    private func postNote() {
        isPosting = true
        autoSaveTask?.cancel()
        autoSaveTask = nil
        uploadInfoProvider.startUpload(totalCount: attachments.count)

        Task {
            // 1. Upload media to Blossom mirrors
            var finalContent = content
            isUploading = true

            // Upload all attachments and fail if any fail
            for i in attachments.indices {
                uploadInfoProvider.setCurrentIndex(i + 1, type: attachments[i].type)
                let mimeType = attachments[i].type.preferredMIMEType ?? "application/octet-stream"
                let progressHandler: (Double) -> Void = { progressFraction in
                    self.uploadInfoProvider.updateProgress(progressFraction)
                }

                let uploadedURL: URL?
                if let fileURL = attachments[i].fileURL {
                    guard let sha256 = ComposeView.streamingSHA256(of: fileURL) else {
                        DispatchQueue.main.async {
                            error = "Failed to read video file for upload."
                            isPosting = false
                            isUploading = false
                            uploadInfoProvider.reset()
                        }
                        return
                    }
                    uploadedURL = await blossomService.uploadAndMirror(
                        fileURL: fileURL,
                        sha256: sha256,
                        contentType: mimeType,
                        progress: progressHandler
                    )
                } else if let data = attachments[i].data {
                    let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    uploadedURL = await blossomService.uploadAndMirror(
                        data: data,
                        sha256: sha256,
                        contentType: mimeType,
                        progress: progressHandler
                    )
                } else {
                    uploadedURL = nil
                }

                guard let url = uploadedURL else {
                    DispatchQueue.main.async {
                        error = "Failed to upload media to Blossom mirrors. Check your connection and try again."
                        isPosting = false
                        isUploading = false
                        uploadInfoProvider.reset()
                    }
                    return
                }
                attachments[i].url = url
                attachments[i].isUploaded = true
                finalContent += "\n\(url.absoluteString)"
            }
            isUploading = false
            uploadInfoProvider.reset()
            cleanupAttachmentTempFiles()

            // 2. Build Event
            var tags: [[String]] = []
            let relayHint = ConfigService.shared.config.nostrURL

            if let parent = effectiveReplyTo {
                // NIP-10 tags — for reposts (kind 6), reply to the original note, not the repost
                let effectiveParentId: String
                let effectiveParentPubkey: String
                let effectiveParentTags: [[String]]

                if parent.kind == 6, let originalId = parent.repostedEventId {
                    effectiveParentId = originalId
                    if let original = FeedService.shared.notes.first(where: { $0.id == originalId }) {
                        effectiveParentPubkey = original.pubkey
                        effectiveParentTags = original.tags
                    } else {
                        effectiveParentPubkey = parent.pubkey
                        effectiveParentTags = parent.tags
                    }
                } else {
                    effectiveParentId = parent.id
                    effectiveParentPubkey = parent.pubkey
                    effectiveParentTags = parent.tags
                }

                // NIP-10: Determine the thread root from the parent's e-tags
                let parentETags = effectiveParentTags.filter { $0.count >= 2 && $0[0] == "e" }
                let parentNonMentionETags = parentETags.filter { tag in
                    guard tag.count >= 4 else { return true }
                    return tag[3] != "mention"
                }

                if parentNonMentionETags.isEmpty {
                    // Parent IS the root note — single e-tag with "root" marker
                    tags.append(["e", effectiveParentId, relayHint, "root"])
                } else {
                    // Parent is itself a reply — find the thread root
                    let threadRootId: String
                    if let rootTag = parentNonMentionETags.first(where: { $0.count >= 4 && $0[3] == "root" }) {
                        // Preferred: explicit "root" marker in parent's tags
                        threadRootId = rootTag[1]
                    } else {
                        // Deprecated positional: first e-tag is the root
                        threadRootId = parentNonMentionETags[0][1]
                    }
                    tags.append(["e", threadRootId, relayHint, "root"])
                    tags.append(["e", effectiveParentId, relayHint, "reply"])
                }

                // Always tag the parent author
                tags.append(["p", effectiveParentPubkey])

                // NIP-10: Accumulate p-tags from parent (thread participants), deduplicated
                var seenPubkeys = Set<String>([effectiveParentPubkey])
                for tag in effectiveParentTags where tag.count >= 2 && tag[0] == "p" {
                    let pk = tag[1]
                    if seenPubkeys.insert(pk).inserted {
                        tags.append(["p", pk])
                    }
                }
            }

            // @mention p-tags
            for mentionedPubkey in taggedPubkeys {
                // Avoid duplicating p-tags already added for reply/quote
                let alreadyTagged = tags.contains { $0.first == "p" && $0.count > 1 && $0[1] == mentionedPubkey }
                if !alreadyTagged {
                    tags.append(["p", mentionedPubkey])
                }
            }

            // Quote post: append nevent reference and q tag (NIP-18)
            if let quoted = effectiveQuoteTo {
                finalContent += "\nnostr:\(quoted.nevent)"
                tags.append(["q", quoted.id, relayHint, quoted.pubkey])
                if !tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == quoted.pubkey }) {
                    tags.append(["p", quoted.pubkey])
                }
            }

            // 3. Sign
            let isReply = effectiveReplyTo != nil
            print("ComposeView: signing \(isReply ? "reply" : "post") – mode=\(configService.config.activeSigningMode()) nip46connected=\(NIP46Service.shared.isConnected) tags=\(tags.count)")
            guard let event = await nostrService.signEventAsync(kind: 1, content: finalContent, tags: tags) else {
                await MainActor.run {
                    let signingMode = configService.config.activeSigningMode()
                    print("ComposeView: sign FAILED – signingMode=\(signingMode) activeNpub=\(configService.config.activeAccountNpub.prefix(20)) isReply=\(isReply)")
                    if signingMode == "nip46" {
                        error = "Remote signer failed to sign the event. Check that your bunker is connected."
                    } else {
                        let activeNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                        let isWhitelisted = !activeNpub.isEmpty && activeNpub != configService.config.ownerNpub
                        if isWhitelisted {
                            error = "No private key stored for this account. Add its nsec in Settings to post as this account."
                        } else {
                            error = "Failed to sign event. Do you have your private key set in Settings?"
                        }
                    }
                    isPosting = false
                }
                return
            }

            DispatchQueue.main.async {
                // Add to local feed immediately for preview
                let feedNote = FeedNote(
                    id: event.id,
                    pubkey: event.pubkey,
                    content: event.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                    tags: event.tags,
                    kind: event.kind
                )
                FeedService.shared.addNote(feedNote)

                // Hand to PendingPostManager — it will broadcast after countdown
                PendingPostManager.shared.startPost(
                    event: event,
                    content: finalContent,
                    replyTo: self.effectiveReplyTo,
                    quoteTo: self.effectiveQuoteTo,
                    nostrService: self.nostrService
                )

                // Clean up the draft now that the post is going out
                if let draftId = self.draftId {
                    Task { await DraftService.shared.deleteDraft(id: draftId) }
                }

                // Mark content as "saved" so performDismiss won't re-save the draft
                self.lastSavedContent = self.content.trimmingCharacters(in: .whitespacesAndNewlines)

                isPosting = false
                performDismiss()
            }
        }
    }

    private func loadBlossomMedia() {
        guard !isLoadingBlossomMedia else { return }
        guard relayManager.isRunning && !relayManager.isBooting else {
            blossomMedia = []
            return
        }
        isLoadingBlossomMedia = true
        let relayDataDir = configService.relayDataDir
        let blossomPath = configService.config.blossomPath
        let ownerHex = nostrService.activeHexPubkey
        let webURL = configService.config.webURL
        let rpm = relayManager

        Task {
            let result = await Task.detached(priority: .background) { () -> [MediaItem] in
                let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
                guard FileManager.default.fileExists(atPath: blossomDir.path),
                      let fileURLs = try? FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: [.creationDateKey]) else {
                    return []
                }
                return fileURLs.compactMap { fileURL -> MediaItem? in
                    let filename = fileURL.lastPathComponent
                    if filename.starts(with: ".") || filename == "LOCK" { return nil }
                    guard let serveURL = URL(string: "\(webURL)/\(filename)") else { return nil }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let date = (attributes?[.modificationDate] as? Date) ?? (attributes?[.creationDate] as? Date) ?? Date()
                    let proof = rpm.detectMimeFromBytes(for: fileURL)
                    let resolvedMime = rpm.resolveMime(claim: nil, proof: proof)
                    let mimeType = resolvedMime == "application/octet-stream" ? nil : resolvedMime
                    let mediaType: MediaItem.MediaType
                    if let mime = mimeType {
                        if mime.hasPrefix("video/") { mediaType = .video }
                        else if mime.hasPrefix("audio/") { mediaType = .audio }
                        else if mime.hasPrefix("image/") { mediaType = .image }
                        else { mediaType = .unknown }
                    } else {
                        mediaType = .unknown
                    }
                    return MediaItem(id: UUID(), url: serveURL, type: mediaType, dateAdded: date, pubkey: ownerHex, tags: nil, mimeType: mimeType)
                }.sorted { $0.dateAdded > $1.dateAdded }
            }.value

            await MainActor.run {
                blossomMedia = result
                isLoadingBlossomMedia = false
            }
        }
    }

    private func performDismiss() {
        autoSaveTask?.cancel()

        // Final save to local cache if content changed since last save
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty
            && (trimmed.contains(" ") || trimmed.count > 10)
            && trimmed != lastSavedContent {
            let id = draftId ?? UUID().uuidString
            if draftId == nil { draftId = id }

            // Fire off save — local disk write happens immediately inside saveDraft,
            // relay sync is best-effort and queued if unavailable
            Task {
                await DraftService.shared.saveDraft(
                    draftId: id,
                    content: content,
                    replyTo: effectiveReplyTo,
                    quoteTo: effectiveQuoteTo,
                    taggedPubkeys: taggedPubkeys
                )
            }
        }

        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    // MARK: - Draft Auto-Save

    private func scheduleAutoSave(_ text: String) {
        autoSaveTask?.cancel()

        // Don't schedule saves while a post is in progress
        guard !isPosting else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't save empty content or very short fragments
        guard !trimmed.isEmpty, trimmed.contains(" ") || trimmed.count > 10 else { return }
        // Don't save if nothing changed since last save
        guard trimmed != lastSavedContent else { return }

        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s debounce
            guard !Task.isCancelled else { return }
            // Re-check after waking — a post may have started during the debounce
            guard !isPosting else { return }

            let id = draftId ?? UUID().uuidString
            if draftId == nil {
                await MainActor.run { draftId = id }
            }

            await DraftService.shared.saveDraft(
                draftId: id,
                content: content,
                replyTo: effectiveReplyTo,
                quoteTo: effectiveQuoteTo,
                taggedPubkeys: taggedPubkeys
            )
            await MainActor.run { lastSavedContent = trimmed }
        }
    }

    private func loadDraft(_ draft: Draft) {
        draftId = draft.id
        content = draft.content
        lastSavedContent = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Restore reply context from saved draft
        if let replyId = draft.replyToId {
            draftReplyTo = FeedService.shared.notes.first(where: { $0.id == replyId })
                ?? FeedService.shared.parentNotesCache[replyId]
        } else {
            draftReplyTo = nil
        }

        // Restore quote context from saved draft
        if let quoteId = draft.quoteId {
            draftQuoteTo = FeedService.shared.notes.first(where: { $0.id == quoteId })
                ?? FeedService.shared.parentNotesCache[quoteId]
        } else {
            draftQuoteTo = nil
        }
    }
}

class MediaUploadsIndicatorInfoProvider: ObservableObject {
    @Published var isUploading: Bool = false
    @Published var totalCount: Int = 0
    @Published var currentIndex: Int = 0
    @Published var uploadMessage: String? = nil
    @Published var currentProgress: Double = 0.0
    private var currentType: UTType = .image
    
    func startUpload(totalCount: Int) {
        DispatchQueue.main.async {
            self.isUploading = true
            self.totalCount = totalCount
            self.currentIndex = 0
            self.currentProgress = 0.0
            self.uploadMessage = totalCount > 0 ? "Preparing uploads..." : nil
        }
    }
    
    func setCurrentIndex(_ index: Int, type: UTType) {
        DispatchQueue.main.async {
            self.currentIndex = index
            self.currentType = type
            self.currentProgress = 0.0
            self.updateMessage()
        }
    }
    
    func updateProgress(_ progress: Double) {
        DispatchQueue.main.async {
            self.currentProgress = progress
            self.updateMessage()
        }
    }
    
    private func updateMessage() {
        let isVideo = self.currentType.conforms(to: .movie) || self.currentType.conforms(to: .video)
        let mediaType = isVideo ? "video" : "image"
        let pct = Int(self.currentProgress * 100)
        if self.totalCount > 1 {
            self.uploadMessage = "Uploading \(mediaType) (\(self.currentIndex) of \(self.totalCount)) - \(pct)%..."
        } else {
            self.uploadMessage = "Uploading \(mediaType) - \(pct)%..."
        }
    }
    
    func reset() {
        DispatchQueue.main.async {
            self.isUploading = false
            self.totalCount = 0
            self.currentIndex = 0
            self.currentProgress = 0.0
            self.uploadMessage = nil
        }
    }
}

struct BlossomMediaPickerSheet: View {
    @Binding var blossomMedia: [MediaItem]
    @Binding var isLoading: Bool
    let onSelect: (MediaItem) -> Void
    let onAppearLoad: () -> Void
    @Environment(\.dismiss) var dismiss

    #if os(macOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    #else
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    #endif

    var body: some View {
        NavigationView {
            Group {
                if isLoading && blossomMedia.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Loading media...")
                            .font(.appSystem(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if blossomMedia.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.macro")
                            .font(.appSystem(size: 48, weight: .thin))
                            .foregroundColor(Color.havenPurple.opacity(0.6))
                        Text("No media on Blossom")
                            .font(.appSystem(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(blossomMedia) { item in
                                BlossomPickerGridItem(item: item)
                                    .onTapGesture { onSelect(item) }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .background(Color.platformSecondaryGroupedBackground)
            .navigationTitle("Blossom Media")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { onAppearLoad() }
    }
}

private struct BlossomPickerGridItem: View {
    let item: MediaItem

    var body: some View {
        Color.clear
            .aspectRatio(1.0, contentMode: .fit)
            .overlay(
                Group {
                    if item.type == .video {
                        VideoThumbnailView(url: item.url, mimeType: item.mimeType)
                    } else if item.type == .audio {
                        ZStack {
                            Color(red: 0.1, green: 0.1, blue: 0.14)
                            Image(systemName: "waveform")
                                .font(.appSystem(size: 28))
                                .foregroundColor(.havenPurple)
                        }
                    } else if item.isAnimatedGIF {
                        AnimatedImage(url: item.url, contentMode: .fill, shouldAnimate: false, targetSize: CGSize(width: 200, height: 200))
                    } else {
                        RetryableAsyncImage(url: item.url, contentMode: .fill, targetSize: CGSize(width: 200, height: 200))
                    }
                }
            )
            .background(Color.black.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
