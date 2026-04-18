import SwiftUI
import SwiftData
import CopiedKit

/// Full management window — three-column layout: Sidebar | Clippings | Detail.
struct MainWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService
    @Environment(AppState.self) private var appState

    @Query(sort: \ClipList.sortOrder) private var lists: [ClipList]

    @State private var selectedClipping: Clipping?
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var state = appState
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            ClippingListBySelection(
                selection: appState.sidebarSelection,
                searchText: searchText,
                selectedClipping: $selectedClipping
            )
            .onChange(of: appState.sidebarSelection) { _, _ in
                selectedClipping = nil
            }
            .onChange(of: searchText) { _, _ in
                selectedClipping = nil
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 500)
        } detail: {
            detailView
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search all clippings…")
        .toolbar { toolbar }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        @Bindable var state = appState
        return List(selection: $state.sidebarSelection) {
            Section("Library") {
                Label("All Clippings", systemImage: "tray.full")
                    .tag(SidebarItem.all)

                Label("Favorites", systemImage: "star")
                    .tag(SidebarItem.favorites)

                Label("Trash", systemImage: "trash")
                    .tag(SidebarItem.trash)
            }

            Section("Lists") {
                ForEach(lists) { list in
                    HStack {
                        Circle()
                            .fill(Color(hex: list.colorHex))
                            .frame(width: 10, height: 10)
                        Text(list.name)
                        Spacer()
                        Text("\(list.clippingCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .tag(SidebarItem.list(list))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Copied")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createList()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if let clipping = selectedClipping {
            ClippingDetail(clipping: clipping)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Select a clipping to view its contents")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 4) {
                Circle()
                    .fill(clipboardService.isMonitoring ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(clipboardService.isMonitoring ? "Monitoring" : "Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                clipboardService.isMonitoring ? clipboardService.stop() : clipboardService.start()
            } label: {
                Image(systemName: clipboardService.isMonitoring ? "pause.circle" : "play.circle")
            }
        }
    }

    private func createList() {
        let list = ClipList(name: "New List")
        list.sortOrder = lists.count
        modelContext.insert(list)
    }
}

// MARK: - Clipping List filtered by sidebar selection

struct ClippingListBySelection: View {
    let selection: SidebarItem
    let searchText: String
    @Binding var selectedClipping: Clipping?

    var body: some View {
        switch selection {
        case .all:
            AllClippingsList(searchText: searchText, selectedClipping: $selectedClipping)
        case .favorites:
            FavoritesClippingsList(searchText: searchText, selectedClipping: $selectedClipping)
        case .trash:
            TrashClippingsList(searchText: searchText, selectedClipping: $selectedClipping)
        case .list(let list):
            ListClippingsList(list: list, searchText: searchText, selectedClipping: $selectedClipping)
        }
    }
}

// MARK: - All Clippings

private struct AllClippingsList: View {
    let searchText: String
    @Binding var selectedClipping: Clipping?

    @Query(
        filter: #Predicate<Clipping> { $0.deleteDate == nil },
        sort: \Clipping.addDate,
        order: .reverse
    )
    private var allClippings: [Clipping]

    // Limit to 200 items to prevent materializing thousands of model objects
    private var clippings: ArraySlice<Clipping> { allClippings.prefix(200) }

    var body: some View {
        clippingList(Array(clippings), emptyTitle: "No Clippings", emptyIcon: "clipboard")
    }

    private func clippingList(_ items: [Clipping], emptyTitle: String, emptyIcon: String) -> some View {
        let filtered = searchText.isEmpty ? items : items.filter {
            $0.text?.localizedCaseInsensitiveContains(searchText) == true ||
            $0.title?.localizedCaseInsensitiveContains(searchText) == true ||
            $0.url?.localizedCaseInsensitiveContains(searchText) == true
        }
        return List(filtered, selection: $selectedClipping) { clipping in
            ClippingRow(clipping: clipping)
                .tag(clipping)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
            }
        }
    }
}

// MARK: - Favorites

private struct FavoritesClippingsList: View {
    let searchText: String
    @Binding var selectedClipping: Clipping?

    @Query(
        filter: #Predicate<Clipping> { $0.isFavorite && $0.deleteDate == nil },
        sort: \Clipping.addDate,
        order: .reverse
    )
    private var clippings: [Clipping]

    var body: some View {
        let filtered = searchText.isEmpty ? clippings : clippings.filter {
            $0.text?.localizedCaseInsensitiveContains(searchText) == true ||
            $0.title?.localizedCaseInsensitiveContains(searchText) == true
        }
        List(filtered, selection: $selectedClipping) { clipping in
            ClippingRow(clipping: clipping)
                .tag(clipping)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("No Favorites", systemImage: "star",
                    description: Text("Right-click a clipping and choose Favorite"))
            }
        }
    }
}

// MARK: - Trash

private struct TrashClippingsList: View {
    let searchText: String
    @Binding var selectedClipping: Clipping?
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<Clipping> { $0.deleteDate != nil },
        sort: \Clipping.deleteDate,
        order: .reverse
    )
    private var clippings: [Clipping]

    var body: some View {
        let filtered = searchText.isEmpty ? clippings : clippings.filter {
            $0.text?.localizedCaseInsensitiveContains(searchText) == true
        }
        List(filtered, selection: $selectedClipping) { clipping in
            HStack {
                ClippingRow(clipping: clipping)
                Spacer()
                Button("Restore") {
                    clipping.restore()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .tag(clipping)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Empty Trash", role: .destructive) {
                    for clip in clippings {
                        modelContext.delete(clip)
                    }
                }
                .disabled(clippings.isEmpty)
            }
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("Trash is Empty", systemImage: "trash")
            }
        }
    }
}

// MARK: - List-specific

private struct ListClippingsList: View {
    let list: ClipList
    let searchText: String
    @Binding var selectedClipping: Clipping?

    var body: some View {
        let all = (list.clippings ?? []).filter { $0.deleteDate == nil }
        let items = searchText.isEmpty ? all : all.filter {
            $0.text?.localizedCaseInsensitiveContains(searchText) == true
        }
        let sorted = items.sorted { $0.addDate > $1.addDate }
        List(sorted, selection: $selectedClipping) { clipping in
            ClippingRow(clipping: clipping)
                .tag(clipping)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if sorted.isEmpty {
                ContentUnavailableView("Empty List", systemImage: "folder",
                    description: Text("Drag clippings here to organize them"))
            }
        }
    }
}

// MARK: - Color Helper

extension Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}
