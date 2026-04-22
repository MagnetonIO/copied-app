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
        .onAppear {
            // Pick up a pre-seeded query from the URL scheme (copied://search?q=…).
            if !appState.searchText.isEmpty && searchText.isEmpty {
                searchText = appState.searchText
            }
        }
        .onChange(of: appState.searchText) { _, newValue in
            if newValue != searchText {
                searchText = newValue
            }
        }
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
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService

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
                .contextMenu {
                    clippingContextMenuContent(
                        for: clipping,
                        clipboardService: clipboardService,
                        modelContext: modelContext,
                        inTrash: false
                    )
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand { selectedClipping?.moveToTrash() }
        .background {
            permanentDeleteShortcut(selected: selectedClipping, modelContext: modelContext)
        }
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
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService

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
                .contextMenu {
                    clippingContextMenuContent(
                        for: clipping,
                        clipboardService: clipboardService,
                        modelContext: modelContext,
                        inTrash: false
                    )
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand { selectedClipping?.moveToTrash() }
        .background {
            permanentDeleteShortcut(selected: selectedClipping, modelContext: modelContext)
        }
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
    @Environment(ClipboardService.self) private var clipboardService

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
            .contextMenu {
                clippingContextMenuContent(
                    for: clipping,
                    clipboardService: clipboardService,
                    modelContext: modelContext,
                    inTrash: true
                )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand {
            if let sel = selectedClipping { modelContext.delete(sel) }
        }
        .background {
            permanentDeleteShortcut(selected: selectedClipping, modelContext: modelContext)
        }
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
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService

    @Query private var clippings: [Clipping]

    init(list: ClipList, searchText: String, selectedClipping: Binding<Clipping?>) {
        self.list = list
        self.searchText = searchText
        self._selectedClipping = selectedClipping

        let listID = list.listID
        _clippings = Query(
            filter: #Predicate<Clipping> {
                $0.deleteDate == nil && $0.list?.listID == listID
            },
            sort: [SortDescriptor(\Clipping.addDate, order: .reverse)]
        )
    }

    var body: some View {
        let filtered = searchText.isEmpty ? clippings : clippings.filter {
            $0.text?.localizedCaseInsensitiveContains(searchText) == true
        }
        List(filtered, selection: $selectedClipping) { clipping in
            ClippingRow(clipping: clipping)
                .tag(clipping)
                .contextMenu {
                    clippingContextMenuContent(
                        for: clipping,
                        clipboardService: clipboardService,
                        modelContext: modelContext,
                        inTrash: false
                    )
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand { selectedClipping?.moveToTrash() }
        .background {
            permanentDeleteShortcut(selected: selectedClipping, modelContext: modelContext)
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("Empty List", systemImage: "folder",
                    description: Text("Drag clippings here to organize them"))
            }
        }
    }
}

// MARK: - Context menu

/// Writes `clipping` to the general pasteboard. Mirrors `PopoverView.copyToClipboard(_:)`
/// minus the popover-local bookkeeping (selectedIndex/searchResults reset, `closePopover`).
@MainActor
private func copyClippingToPasteboard(
    _ clipping: Clipping,
    clipboardService: ClipboardService
) {
    clipboardService.skipNextCapture = true
    let pb = NSPasteboard.general
    pb.clearContents()
    if let text = clipping.text { pb.setString(text, forType: .string) }
    if let url = clipping.url { pb.setString(url, forType: .URL) }
    if let imageData = clipping.imageData {
        let type: NSPasteboard.PasteboardType = clipping.imageFormat == "png" ? .png : .tiff
        pb.setData(imageData, forType: type)
    }
    if let rtfData = clipping.richTextData {
        pb.setData(rtfData, forType: clipping.richTextPasteboardType)
    }
    if let htmlData = clipping.htmlData {
        pb.setData(htmlData, forType: .html)
    }
    clipping.markUsed()
}

/// Context-menu items shared across the four main-window list views. Keyboard shortcuts
/// attached to the Buttons fire from the list even when the menu is closed, as long as
/// the List holds focus (which `List(selection:)` claims on row click).
@MainActor
@ViewBuilder
private func clippingContextMenuContent(
    for clipping: Clipping,
    clipboardService: ClipboardService,
    modelContext: ModelContext,
    inTrash: Bool
) -> some View {
    Button("Copy") {
        copyClippingToPasteboard(clipping, clipboardService: clipboardService)
    }
    if let text = clipping.text, !text.isEmpty {
        Button("Copy as Plain Text") {
            clipboardService.skipNextCapture = true
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            clipping.markUsed()
        }
    }
    if clipping.hasRichText, let rtf = clipping.richTextData {
        Button("Copy as Rich Text") {
            clipboardService.skipNextCapture = true
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(rtf, forType: clipping.richTextPasteboardType)
            clipping.markUsed()
        }
    }
    if clipping.hasHTML, let html = clipping.htmlData {
        Button("Copy as HTML") {
            clipboardService.skipNextCapture = true
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(html, forType: .html)
            clipping.markUsed()
        }
    }
    if clipping.contentKind == .link,
       let urlStr = clipping.url,
       let url = URL(string: urlStr) {
        Divider()
        Button("Open Link") { NSWorkspace.shared.open(url) }
    }
    Divider()
    Button(clipping.isFavorite ? "Unfavorite" : "Favorite") {
        clipping.isFavorite.toggle()
    }
    Button(clipping.isPinned ? "Unpin" : "Pin") {
        clipping.isPinned.toggle()
    }
    Divider()
    if inTrash {
        Button("Restore") { clipping.restore() }
        Button("Delete Permanently", role: .destructive) {
            modelContext.delete(clipping)
        }
    } else {
        Button("Move to Trash", role: .destructive) { clipping.moveToTrash() }
        Button("Delete Permanently", role: .destructive) {
            modelContext.delete(clipping)
        }
    }
}

/// Hidden focusable button that claims the ⌃⌫ shortcut for the List it's backgrounded on.
/// `.onDeleteCommand` on the List handles plain ⌫; this covers the ⌃⌫ variant (permanent delete).
@MainActor
@ViewBuilder
private func permanentDeleteShortcut(
    selected: Clipping?,
    modelContext: ModelContext
) -> some View {
    Button("") {
        if let sel = selected { modelContext.delete(sel) }
    }
    .keyboardShortcut(.delete, modifiers: .control)
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
    .disabled(selected == nil)
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
