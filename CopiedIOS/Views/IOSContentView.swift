import SwiftUI
import SwiftData
import CopiedKit

struct IOSContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService
    @State private var searchText = ""
    @State private var selectedClipping: Clipping?
    @State private var showingLists = false

    var body: some View {
        NavigationSplitView {
            clippingList
                .navigationTitle("Copied")
                .toolbar { iosToolbar }
                .searchable(text: $searchText, prompt: "Search clippings…")
        } detail: {
            if let clipping = selectedClipping {
                ClippingDetail(clipping: clipping)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "clipboard",
                    description: Text("Select a clipping or tap + to save your clipboard")
                )
            }
        }
        .onAppear {
            clipboardService.configure(modelContext: modelContext)
        }
    }

    // MARK: - Clipping List

    private var clippingList: some View {
        ClippingQueryList(
            searchText: searchText,
            selectedClipping: $selectedClipping
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                clipboardService.saveCurrentClipboard()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .help("Save clipboard")
        }

        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingLists = true
            } label: {
                Image(systemName: "folder")
            }
        }
    }
}

// MARK: - Query List (iOS)

private struct ClippingQueryList: View {
    let searchText: String
    @Binding var selectedClipping: Clipping?

    @Query(
        filter: #Predicate<Clipping> { $0.deleteDate == nil },
        sort: \Clipping.addDate,
        order: .reverse
    )
    private var clippings: [Clipping]

    private var filtered: [Clipping] {
        guard !searchText.isEmpty else { return clippings }
        let query = searchText.lowercased()
        return clippings.filter { clip in
            clip.text?.localizedCaseInsensitiveContains(query) == true ||
            clip.title?.localizedCaseInsensitiveContains(query) == true ||
            clip.url?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        List(filtered, selection: $selectedClipping) { clipping in
            ClippingRow(clipping: clipping)
                .tag(clipping)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        clipping.moveToTrash()
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        clipping.isFavorite.toggle()
                    } label: {
                        Label(
                            clipping.isFavorite ? "Unfavorite" : "Favorite",
                            systemImage: clipping.isFavorite ? "star.slash" : "star.fill"
                        )
                    }
                    .tint(.yellow)

                    Button {
                        copyToClipboard(clipping)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .tint(.blue)
                }
        }
        .listStyle(.plain)
        .overlay {
            if clippings.isEmpty {
                ContentUnavailableView(
                    "No Clippings Yet",
                    systemImage: "clipboard",
                    description: Text("Tap + to save what's on your clipboard")
                )
            }
        }
    }

    private func copyToClipboard(_ clipping: Clipping) {
        #if canImport(UIKit)
        if let text = clipping.text {
            UIPasteboard.general.string = text
        } else if let url = clipping.url {
            UIPasteboard.general.url = URL(string: url)
        } else if let imageData = clipping.imageData, let image = UIImage(data: imageData) {
            UIPasteboard.general.image = image
        }
        #endif
    }
}
