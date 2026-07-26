import SwiftUI

struct DraftPickerView: View {
    @StateObject private var draftService = DraftService.shared
    let onSelect: (Draft) -> Void
    let onDelete: (Draft) -> Void
    @Environment(\.dismiss) var dismiss

    private var filteredDrafts: [Draft] {
        draftService.draftsForActiveAccount
    }

    var body: some View {
        NavigationStack {
            Group {
                if draftService.isLoading && filteredDrafts.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Loading drafts...")
                            .font(.appSystem(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredDrafts.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text")
                            .font(.appSystem(size: 48, weight: .thin))
                            .foregroundColor(Color.havenPurple.opacity(0.6))
                        Text("No drafts")
                            .font(.appSystem(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredDrafts) { draft in
                            Button {
                                onSelect(draft)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    if draft.isReply {
                                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                                            .font(.appCaption)
                                            .foregroundColor(.havenPurple)
                                    } else if draft.isQuote {
                                        Label("Quote", systemImage: "quote.bubble")
                                            .font(.appCaption)
                                            .foregroundColor(.havenPurple)
                                    } else {
                                        Label("Post", systemImage: "square.and.pencil")
                                            .font(.appCaption)
                                            .foregroundColor(.secondary)
                                    }

                                    Text(draft.preview)
                                        .font(.appSystem(size: 14))
                                        .foregroundColor(.primary)
                                        .lineLimit(2)

                                    Text(draft.updatedAt, style: .relative)
                                        .font(.appCaption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    onDelete(draft)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                }
            }
            .background(Color.platformSecondaryGroupedBackground)
            .navigationTitle("Drafts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            Task { await draftService.fetchDrafts() }
        }
    }
}
