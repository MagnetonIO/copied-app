import SwiftUI
import SwiftData
import CopiedKit
import OSLog

/// Full management window — three-column layout: Sidebar | Clippings | Detail.
struct MainWindowView: View {
    private let syncProfileLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Copied",
        category: "SyncProfile"
    )
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ClipboardService.self) private var clipboardService
    @Environment(AppState.self) private var appState
    @Environment(SyncMonitor.self) private var syncMonitor
    @Environment(SyncTicker.self) private var syncTicker

    @Query(sort: \ClipList.sortOrder) private var lists: [ClipList]

    // Sidebar counts — mirror the trailing-gray-count treatment used on
    // each user list row so All Clippings, Favorites, and Trash read the
    // same way. Three separate @Query predicates keep SwiftData's
    // observability narrow (no need to refetch the full Clipping array
    // just to count).
    @Query(filter: #Predicate<Clipping> { $0.deleteDate == nil })
    private var activeClippings: [Clipping]
    @Query(filter: #Predicate<Clipping> { $0.deleteDate == nil && $0.isFavorite })
    private var favoriteClippings: [Clipping]
    @Query(filter: #Predicate<Clipping> { $0.deleteDate != nil })
    private var trashedClippings: [Clipping]

    /// Multi-selection set — `List` uses `Set<Element>` to enable
    /// shift-click range-select and ⌘-click multi-select. Detail view
    /// binds to the first element of the set (showing the most recent
    /// focus target); destructive actions operate on the whole set.
    @State private var selectedClippings: Set<Clipping> = []
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Sidebar list management state. We reuse the same "name draft" for
    /// both create and rename flows — only one alert is visible at a time.
    @State private var isNamingNewList = false
    @State private var newListNameDraft = ""
    @State private var renamingList: ClipList?
    @State private var pendingDeleteList: ClipList?
    @State private var hoveringListsHeader = false

    var body: some View {
        let _ = syncTicker.tick
        @Bindable var state = appState
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            ClippingListBySelection(
                selection: appState.sidebarSelection,
                searchText: searchText,
                selectedClippings: $selectedClippings
            )
            .onChange(of: appState.sidebarSelection) { _, _ in
                selectedClippings.removeAll()
            }
            .onChange(of: searchText) { _, _ in
                selectedClippings.removeAll()
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 500)
        } detail: {
            detailView
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search all clippings…")
        .toolbar { toolbar }
        .onAppear {
            syncProfileLogger.log("trigger mainWindow.onAppear")
            // Pick up a pre-seeded query from the URL scheme (copied://search?q=…).
            if !appState.searchText.isEmpty && searchText.isEmpty {
                searchText = appState.searchText
            }
            // Explicit pull on window open — Apple-recommended pattern
            // for "give me current data before continuing."
            Task.detached { await CopiedSyncEngine.shared.fetchChanges(source: "mac.mainWindow.onAppear") }
        }
        .onChange(of: appState.searchText) { _, newValue in
            if newValue != searchText {
                searchText = newValue
            }
        }
        .onChange(of: scenePhase) { _, phase in
            syncProfileLogger.log("trigger mainWindow.scenePhase phase=\(String(describing: phase), privacy: .public)")
            // Window transitioning to active (user clicked back into it
            // from another app) → fetch latest. CKSyncEngine handles
            // its own background cadence; this is the UI-driven nudge.
            if phase == .active {
                Task.detached { await CopiedSyncEngine.shared.fetchChanges(source: "mac.mainWindow.sceneActive") }
            }
        }
        // Release in-memory caches when the main window closes. Without
        // this, every blob field (image / rich-text / HTML) read while the
        // window was open stays pinned in the shared mainContext row cache
        // for the rest of the app's lifetime.
        .onDisappear {
            ThumbnailCache.shared.purge()
            AppIconCache.shared.purge()
            SharedData.container.mainContext.rollback()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        @Bindable var state = appState
        return List(selection: $state.sidebarSelection) {
            Section("Library") {
                sidebarRow(title: "All Clippings", systemImage: "tray.full", count: activeClippings.count)
                    .tag(SidebarItem.all)

                sidebarRow(title: "Favorites", systemImage: "star", count: favoriteClippings.count)
                    .tag(SidebarItem.favorites)

                sidebarRow(title: "Trash", systemImage: "trash", count: trashedClippings.count)
                    .tag(SidebarItem.trash)
            }

            Section {
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
                    .contextMenu {
                        Button("Rename") {
                            newListNameDraft = list.name
                            renamingList = list
                        }
                        Button("Delete", role: .destructive) {
                            if list.clippingCount == 0 {
                                list.deleteTrashingClippings(in: modelContext)
                            } else {
                                pendingDeleteList = list
                            }
                        }
                    }
                }
            } header: {
                // Phase 18 — Lists header with trailing "+" button so New
                // List is one click away from the sidebar. `.onHover` makes
                // the plus pop on hover as a secondary affordance.
                HStack(spacing: 4) {
                    Text("Lists")
                    Spacer()
                    Button {
                        newListNameDraft = ""
                        isNamingNewList = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(hoveringListsHeader ? Color.accentColor : .secondary)
                            .help("New List")
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onHover { hoveringListsHeader = $0 }
                .contextMenu {
                    Button("New List…") {
                        newListNameDraft = ""
                        isNamingNewList = true
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Copied")
        // Right-click anywhere in the sidebar (outside a list row) raises
        // the New List prompt. Row-specific context menus (Rename / Delete)
        // intercept the click first because they're declared on the row.
        .contextMenu {
            Button("New List…") {
                newListNameDraft = ""
                isNamingNewList = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newListNameDraft = ""
                    isNamingNewList = true
                } label: {
                    // Label (not bare Image) so View → Customize Toolbar's
                    // "Icon and Text" mode has a string to render. `.help`
                    // adds the hover tooltip users expect on Mac toolbars.
                    Label("New List", systemImage: "folder.badge.plus")
                }
                .help("New List")
            }
        }
        .alert("New List", isPresented: $isNamingNewList) {
            TextField("List name", text: $newListNameDraft)
            Button("Create") { createList(named: newListNameDraft) }
                .disabled(newListNameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give your list a name — you can rename it later.")
        }
        .alert(
            "Rename List",
            isPresented: Binding(
                get: { renamingList != nil },
                set: { if !$0 { renamingList = nil } }
            ),
            presenting: renamingList
        ) { list in
            TextField("List name", text: $newListNameDraft)
            Button("Save") {
                let trimmed = newListNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    list.name = trimmed
                    list.modifiedDate = Date()
                    try? modelContext.save()
                }
                renamingList = nil
            }
            .disabled(newListNameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renamingList = nil }
        }
        .confirmationDialog(
            pendingDeleteList.map { "Delete “\($0.name)”?" } ?? "Delete list?",
            isPresented: Binding(
                get: { pendingDeleteList != nil },
                set: { if !$0 { pendingDeleteList = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteList
        ) { list in
            Button("Move \(list.clippingCount) to Trash & Delete", role: .destructive) {
                list.deleteTrashingClippings(in: modelContext)
                pendingDeleteList = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteList = nil }
        } message: { list in
            Text("The \(list.clippingCount) clipping\(list.clippingCount == 1 ? "" : "s") in this list will move to Trash — recoverable from the Trash section.")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if selectedClippings.count > 1 {
            ContentUnavailableView(
                "\(selectedClippings.count) Clippings Selected",
                systemImage: "square.stack",
                description: Text("Right-click to apply an action to all selected items.")
            )
        } else if let clipping = selectedClippings.first {
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

    /// Library-row layout matching the Lists rows: leading icon + title
    /// with a trailing muted count. The `Label` we were using before
    /// didn't reserve trailing space, so counts looked off-balance next
    /// to the ClipList rows.
    @ViewBuilder
    private func sidebarRow(title: String, systemImage: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func createList(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let list = ClipList(name: name)
        list.sortOrder = lists.count
        modelContext.insert(list)
        try? modelContext.save()
    }
}

// MARK: - Clipping List filtered by sidebar selection

struct ClippingListBySelection: View {
    let selection: SidebarItem
    let searchText: String
    @Binding var selectedClippings: Set<Clipping>

    var body: some View {
        switch selection {
        case .all:
            AllClippingsList(searchText: searchText, selectedClippings: $selectedClippings)
        case .favorites:
            FavoritesClippingsList(searchText: searchText, selectedClippings: $selectedClippings)
        case .trash:
            TrashClippingsList(searchText: searchText, selectedClippings: $selectedClippings)
        case .list(let list):
            ListClippingsList(list: list, searchText: searchText, selectedClippings: $selectedClippings)
        }
    }
}

// MARK: - All Clippings

private struct AllClippingsList: View {
    let searchText: String
    @Binding var selectedClippings: Set<Clipping>
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
        return List(filtered, selection: $selectedClippings) { clipping in
            ClippingRow(clipping: clipping)
                .tag(clipping)
                .contextMenu {
                    clippingContextMenuContent(
                        for: clipping,
                        clipboardService: clipboardService,
                        modelContext: modelContext,
                        inTrash: false
                    )
                    multiSelectMenuContent(
                        clickedRow: clipping,
                        selection: selectedClippings,
                        modelContext: modelContext,
                        inTrash: false
                    )
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand {
            for c in selectedClippings { c.moveToTrash() }
            selectedClippings.removeAll()
        }
        .background {
            permanentDeleteShortcut(selected: selectedClippings, modelContext: modelContext)
            selectAllShortcut(items: filtered, selection: $selectedClippings)
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
    @Binding var selectedClippings: Set<Clipping>
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
        List(filtered, selection: $selectedClippings) { clipping in
            ClippingRow(clipping: clipping)
                .tag(clipping)
                .contextMenu {
                    clippingContextMenuContent(
                        for: clipping,
                        clipboardService: clipboardService,
                        modelContext: modelContext,
                        inTrash: false
                    )
                    multiSelectMenuContent(
                        clickedRow: clipping,
                        selection: selectedClippings,
                        modelContext: modelContext,
                        inTrash: false
                    )
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand {
            for c in selectedClippings { c.moveToTrash() }
            selectedClippings.removeAll()
        }
        .background {
            permanentDeleteShortcut(selected: selectedClippings, modelContext: modelContext)
            selectAllShortcut(items: filtered, selection: $selectedClippings)
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
    @Binding var selectedClippings: Set<Clipping>
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
        List(filtered, selection: $selectedClippings) { clipping in
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
                multiSelectMenuContent(
                    clickedRow: clipping,
                    selection: selectedClippings,
                    modelContext: modelContext,
                    inTrash: true
                )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand {
            for c in selectedClippings { c.hardDelete(in: modelContext) }
            selectedClippings.removeAll()
        }
        .background {
            permanentDeleteShortcut(selected: selectedClippings, modelContext: modelContext)
            selectAllShortcut(items: filtered, selection: $selectedClippings)
        }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Empty Trash", role: .destructive) {
                    for clip in clippings { clip.hardDelete(in: modelContext) }
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
    @Binding var selectedClippings: Set<Clipping>
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService

    @Query private var clippings: [Clipping]

    init(list: ClipList, searchText: String, selectedClippings: Binding<Set<Clipping>>) {
        self.list = list
        self.searchText = searchText
        self._selectedClippings = selectedClippings

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
        List(filtered, selection: $selectedClippings) { clipping in
            ClippingRow(clipping: clipping)
                .tag(clipping)
                .contextMenu {
                    clippingContextMenuContent(
                        for: clipping,
                        clipboardService: clipboardService,
                        modelContext: modelContext,
                        inTrash: false
                    )
                    multiSelectMenuContent(
                        clickedRow: clipping,
                        selection: selectedClippings,
                        modelContext: modelContext,
                        inTrash: false
                    )
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand {
            for c in selectedClippings { c.moveToTrash() }
            selectedClippings.removeAll()
        }
        .background {
            permanentDeleteShortcut(selected: selectedClippings, modelContext: modelContext)
            selectAllShortcut(items: filtered, selection: $selectedClippings)
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
    // Blob fields go through ephemeral contexts so the bytes don't pin in
    // the main window's mainContext row cache after the pasteboard write.
    let id = clipping.clippingID
    if clipping.hasImage,
       let imageData = ClipboardService.readBlob(
           in: SharedData.container, clippingID: id, key: \Clipping.imageData
       ) {
        let type: NSPasteboard.PasteboardType = clipping.imageFormat == "png" ? .png : .tiff
        pb.setData(imageData, forType: type)
    }
    if clipping.hasRichText,
       let rtfData = ClipboardService.readBlob(
           in: SharedData.container, clippingID: id, key: \Clipping.richTextData
       ) {
        pb.setData(rtfData, forType: clipping.richTextPasteboardType)
    }
    if clipping.hasHTML,
       let htmlData = ClipboardService.readBlob(
           in: SharedData.container, clippingID: id, key: \Clipping.htmlData
       ) {
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
    // Gate on `hasRichText` only — the actual blob is read on click via
    // an ephemeral context so the bytes don't pin in the mainContext row
    // cache just because the menu was instantiated.
    if clipping.hasRichText {
        Button("Copy as Rich Text") {
            guard let rtf = ClipboardService.readBlob(
                in: SharedData.container,
                clippingID: clipping.clippingID,
                key: \Clipping.richTextData
            ) else { return }
            clipboardService.skipNextCapture = true
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(rtf, forType: clipping.richTextPasteboardType)
            clipping.markUsed()
        }
    }
    if clipping.hasHTML {
        Button("Copy as HTML") {
            guard let html = ClipboardService.readBlob(
                in: SharedData.container,
                clippingID: clipping.clippingID,
                key: \Clipping.htmlData
            ) else { return }
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
        clipping.persist()
    }
    Button(clipping.isPinned ? "Unpin" : "Pin") {
        clipping.isPinned.toggle()
        clipping.persist()
    }
    Divider()
    if inTrash {
        Button("Restore") { clipping.restore() }
        Button("Delete Permanently", role: .destructive) {
            clipping.hardDelete(in: modelContext)
        }
    } else {
        Button("Move to Trash", role: .destructive) { clipping.moveToTrash() }
        Button("Delete Permanently", role: .destructive) {
            clipping.hardDelete(in: modelContext)
        }
    }
}

/// Extra menu items that only appear when the user has a multi-
/// selection and right-clicks on one of the selected rows. Lets you
/// right-click any row in a ⌘/⇧-selected set to trash / delete the
/// whole set in one go, matching Finder / Mail semantics.
@MainActor
@ViewBuilder
private func multiSelectMenuContent(
    clickedRow: Clipping,
    selection: Set<Clipping>,
    modelContext: ModelContext,
    inTrash: Bool
) -> some View {
    if selection.count > 1, selection.contains(clickedRow) {
        Divider()
        // Single bulk action per Finder/Mail conventions:
        // - In Trash view: permanent delete (the only valid destructive
        //   action on already-trashed rows).
        // - Elsewhere: move-to-trash (the ⌫ standard; hard delete stays
        //   reserved for individual rows via ⌃⌫ or per-row context menu).
        //
        // Snapshot selection into an Array first so the @Query re-fetch
        // after the first mutation can't shrink the set mid-loop. For
        // hard-delete, capture clippingIDs before ctx.delete() since the
        // model reference becomes invalid after.
        if inTrash {
            Button("Delete \(selection.count) Clippings", role: .destructive) {
                let items = Array(selection)
                let ids = items.map(\.clippingID)
                for c in items { modelContext.delete(c) }
                try? modelContext.save()
                for id in ids {
                    CopiedSyncEngine.shared.enqueueDelete(
                        recordID: CopiedSyncEngine.clippingRecordID(id)
                    )
                }
            }
        } else {
            Button("Delete \(selection.count) Clippings", role: .destructive) {
                let items = Array(selection)
                let now = Date()
                for c in items {
                    c.deleteDate = now
                    c.modifiedDate = now
                }
                try? modelContext.save()
                for c in items {
                    CopiedSyncEngine.shared.enqueueChange(
                        recordID: CopiedSyncEngine.clippingRecordID(c.clippingID)
                    )
                }
            }
        }
    }
}

/// Hidden focusable button that claims the ⌃⌫ shortcut for the List it's backgrounded on.
/// `.onDeleteCommand` on the List handles plain ⌫; this covers the ⌃⌫ variant (permanent delete).
@MainActor
@ViewBuilder
private func permanentDeleteShortcut(
    selected: Set<Clipping>,
    modelContext: ModelContext
) -> some View {
    Button("") {
        for c in selected { c.hardDelete(in: modelContext) }
    }
    .keyboardShortcut(.delete, modifiers: .control)
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
    .disabled(selected.isEmpty)
}

/// Hidden focusable button that claims ⌘A and selects every visible
/// row. SwiftUI's `List(selection:)` with `Set<Element>` does NOT
/// implement ⌘A natively (unlike AppKit's NSTableView), so we inject
/// it with a zero-size button whose keyboardShortcut is picked up by
/// the responder chain. Placed inside each list's `.background { ... }`.
@MainActor
@ViewBuilder
private func selectAllShortcut(
    items: [Clipping],
    selection: Binding<Set<Clipping>>
) -> some View {
    Button("") {
        selection.wrappedValue = Set(items)
    }
    .keyboardShortcut("a", modifiers: .command)
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
    .disabled(items.isEmpty)
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
