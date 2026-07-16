import SwiftUI
import Combine

struct EventBroadcastSheet: View {
    let note: FeedNote
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) var dismiss

    @State private var fullEventDict: [String: Any]?
    @State private var isFetchingEvent = true
    @State private var isBroadcasting = false
    @State private var broadcastResult: String?
    @State private var pendingRelays = Set<String>()
    @State private var succeededRelays = Set<String>()
    @State private var failedRelays: [String: String] = [:]
    @State private var cancellables = Set<AnyCancellable>()

    private var eventJSON: String {
        let dict: [String: Any]
        if let full = fullEventDict {
            dict = full
        } else {
            dict = [
                "id": note.id,
                "pubkey": note.pubkey,
                "created_at": Int(note.createdAt.timeIntervalSince1970),
                "kind": note.kind,
                "tags": note.tags,
                "content": note.content
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    eventIdSection
                    Divider()
                    jsonSection
                    Divider()
                    broadcastSection
                }
                .padding()
            }
            .navigationTitle("Event Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .background(Color.platformControlBackground)
        .onAppear { fetchFullEvent() }
    }

    private var eventIdSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EVENT ID")
                .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .tracking(0.5)

            CopyableRow(label: "hex", value: note.id)
            CopyableRow(label: "note1", value: note.note1)
            CopyableRow(label: "nevent", value: note.nevent)
            CopyableRow(label: "share link", value: "https://mynostrspace.com/thread/\(note.nevent)")
        }
    }

    private var jsonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RAW EVENT")
                    .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .tracking(0.5)

                Spacer()

                if isFetchingEvent {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.havenPurple)
                } else {
                    Button {
                        copyToClipboard(eventJSON)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.appSystem(size: 12, weight: .medium))
                            .foregroundColor(Color.havenPurple)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(eventJSON)
                .font(.appSystem(size: 11, design: .monospaced))
                .foregroundColor(.primary.opacity(0.85))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.platformTertiaryGroupedBackground)
                .cornerRadius(8)
                .textSelection(.enabled)
        }
    }

    private var broadcastSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BROADCAST")
                .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .tracking(0.5)

            let blastrRelays = configService.config.activeBlastrRelays.isEmpty
                ? ["wss://relay.primal.net", "wss://nos.lol"]
                : configService.config.activeBlastrRelays

            VStack(alignment: .leading, spacing: 6) {
                Text("Broadcasting to \(blastrRelays.count) relay(s):")
                    .font(.appSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)

                ForEach(blastrRelays.prefix(6), id: \.self) { relay in
                    HStack(spacing: 6) {
                        Group {
                            if succeededRelays.contains(relay) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else if failedRelays[relay] != nil {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            } else if pendingRelays.contains(relay) {
                                ProgressView()
                                    .scaleEffect(0.5)
                            } else {
                                Circle()
                                    .fill(Color.havenPurple.opacity(0.5))
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .frame(width: 12, height: 12)
                        Text(relay)
                            .font(.appSystem(size: 11, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                if blastrRelays.count > 6 {
                    Text("+ \(blastrRelays.count - 6) more")
                        .font(.appSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(10)
            .background(Color.platformTertiaryGroupedBackground)
            .cornerRadius(8)

            if let result = broadcastResult {
                HStack(spacing: 6) {
                    Image(systemName: failedRelays.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(failedRelays.isEmpty ? .green : .orange)
                    Text(result)
                        .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(failedRelays.isEmpty ? .green : .orange)
                }
            }

            Button {
                broadcastNote()
            } label: {
                HStack(spacing: 8) {
                    if isBroadcasting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Text(isBroadcasting ? "Broadcasting..." : "Re-Broadcast Event")
                }
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isBroadcasting || fullEventDict == nil
                    ? Color.secondary.opacity(0.4)
                    : Color.havenPurple)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(isBroadcasting || fullEventDict == nil)
        }
    }

    private func fetchFullEvent() {
        // 1. Check FeedService's in-memory raw event cache (includes sig)
        if let cached = FeedService.shared.rawEventCache[note.id],
           let jsonData = cached.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            self.fullEventDict = dict
            self.isFetchingEvent = false
            return
        }

        // 2. Query both outbox (/) and inbox (/inbox) paths — notes from others
        //    live in inbox, own notes live in outbox.
        let subId = "broadcast-fetch-\(UUID().uuidString.prefix(8))"
        let filter: [String: Any] = ["ids": [self.note.id], "limit": 1]
        let req = ["REQ", subId, filter] as [Any]

        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            isFetchingEvent = false
            return
        }

        let baseURL = configService.config.nostrURL
        let paths = [baseURL, baseURL + "/inbox"]
        var found = false

        for path in paths {
            guard let url = URL(string: path) else { continue }
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    guard !found,
                          let msgData = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: msgData) as? [Any],
                          let type = json[0] as? String,
                          type == "EVENT", json.count >= 3,
                          let ev = json[2] as? [String: Any] else { return }
                    found = true
                    self.fullEventDict = ev
                    self.isFetchingEvent = false
                    client.disconnect()
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        client.send(text: str)
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if self.isFetchingEvent { self.isFetchingEvent = false }
        }
    }

    private func broadcastNote() {
        guard let eventDict = fullEventDict else { return }
        isBroadcasting = true
        broadcastResult = nil
        succeededRelays.removeAll()
        failedRelays.removeAll()

        let relays = configService.config.activeBlastrRelays.isEmpty
            ? ["wss://relay.primal.net", "wss://nos.lol"]
            : configService.config.activeBlastrRelays
        pendingRelays = Set(relays)
        let totalCount = relays.count

        nostrService.broadcastRawEvent(eventDict) { relay, success, message in
            pendingRelays.remove(relay)
            if success {
                succeededRelays.insert(relay)
            } else {
                failedRelays[relay] = message.isEmpty ? "failed" : message
            }

            if pendingRelays.isEmpty {
                isBroadcasting = false
                let count = succeededRelays.count
                if count == totalCount {
                    broadcastResult = "Broadcast to all \(count) relays"
                } else {
                    broadcastResult = "Broadcast to \(count)/\(totalCount) relays"
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct CopyableRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.appSystem(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.appSystem(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copy()
                withAnimation(.spring(response: 0.2)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.appSystem(size: 13))
                    .foregroundColor(copied ? .green : Color.havenPurple)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
