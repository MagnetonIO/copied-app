import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import CopiedKit

/// The clippings list screen — matches `images/IMG_0977.png`:
/// - Large nav title (selected list's name, e.g. "Copied")
/// - Teal back chevron + teal ellipsis (opens `ClippingActionSheet`)
/// - `.searchable` search bar below title
/// - Rows render via `ClippingRow` from CopiedKit
/// - Swipe leading: favorite (yellow) + copy (teal)
/// - Swipe trailing: trash (red)
/// - Bottom toolbar: lists icon • "N Clippings" (red when over-limit) • sort icon
struct ClippingsListScreen: View {
    let selection: ListsScreen.Selection
    @Binding var presentsSettings: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selected: Clipping?
    @State private var showActionSheet = false
    @State private var showSortPicker = false
    /// Action-sheet rows that trigger follow-on presentation (sort dialog,
    /// new-clipping sheet, etc.) stash their intent here and call dismiss.
    /// `onDismiss` consumes it AFTER the sheet is fully gone, so the next
    /// presentation doesn't race the outgoing one (iOS 18 confirms only
    /// one sheet/dialog chain at a time per view).
    @State private var pendingActionSheetAction: ActionSheetFollowUp?
    @State private var editing: Clipping?
    @State private var sharing: Clipping?
    @State private var multiSelectMode = false
    @State private var selectedIDs: Set<String> = []
    /// Phase 14 — bottom-left clip icon opens an editable "Save
    /// Clipping" panel pre-filled from `UIPasteboard.general`.
    @State private var presentsSaveSheet = false

    /// Shared with `GeneralSettingsView` and Mac `SettingsView`. Default 5000
    /// matches Mac so the over-limit indicator lights up consistently across
    /// platforms.
    @AppStorage("maxHistorySize") private var historyCap: Int = 5000

    /// Per-selection sort order, Phase 9 follow-up. Different selections
    /// (Copied vs per-list) may want different sorting, so the key embeds
    /// the selection identifier.
    @AppStorage private var sortOrderRaw: String
    /// Global filter (not per-selection): when on, the main Copied view
    /// hides clippings that have been assigned to a user-created list
    /// ("New List" on the sidebar). The row action-sheet label flips
    /// between "Hide List Clippings" and "Show List Clippings". Has no
    /// effect outside the `.copied` selection.
    @AppStorage("listClippingsFilter") private var hideListClippings: Bool = false

    init(selection: ListsScreen.Selection, presentsSettings: Binding<Bool>) {
        self.selection = selection
        self._presentsSettings = presentsSettings
        let key = Self.selectionKey(for: selection)
        _sortOrderRaw = AppStorage(wrappedValue: ClippingSortOrder.dateDesc.rawValue, "sort.order.\(key)")
    }

    private static func selectionKey(for selection: ListsScreen.Selection) -> String {
        switch selection {
        case .copied: return "copied"
        case .clipboard: return "clipboard"
        case .trash: return "trash"
        case .userList(let id): return "user.\(id)"
        }
    }

    private var sortOrder: ClippingSortOrder {
        ClippingSortOrder(rawValue: sortOrderRaw) ?? .dateDesc
    }

    private var navTitle: String {
        switch selection {
        case .copied: return "Copied"
        case .clipboard: return "Clipboard"
        case .userList(let id):
            // Look up the actual list name via a quick descriptor. Falls
            // back to the generic "List" if the list was deleted while
            // the user navigated into it.
            let descriptor = FetchDescriptor<ClipList>(
                predicate: #Predicate<ClipList> { $0.listID == id }
            )
            return (try? modelContext.fetch(descriptor).first?.name) ?? "List"
        case .trash: return "Trash"
        }
    }

    var body: some View {
        QueryList(
            selection: selection,
            searchText: searchText,
            multiSelectMode: $multiSelectMode,
            selectedIDs: $selectedIDs,
            selected: $selected,
            editing: $editing,
            sharing: $sharing,
            copyToClipboard: copyToClipboard,
            historyCap: historyCap,
            sortOrder: sortOrder,
            hideListClippings: hideListClippings,
            presentsActionSheet: $showActionSheet,
            presentsSettings: $presentsSettings,
            presentsSaveSheet: $presentsSaveSheet
        )
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .automatic, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showActionSheet = true
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.copiedTeal)
                }
            }
        }
        .sheet(isPresented: $showActionSheet, onDismiss: runPendingActionSheetAction) {
            ClippingActionSheet(
                multiSelectMode: $multiSelectMode,
                selectedIDs: $selectedIDs,
                isListHidden: hideListClippings,
                showHideRow: selection == .copied,
                onNewClipping: { pendingActionSheetAction = .newClipping },
                onToggleHide: { hideListClippings.toggle() },
                onSortList: { pendingActionSheetAction = .sort }
            )
        }
        .confirmationDialog("Sort list", isPresented: $showSortPicker, titleVisibility: .visible) {
            ForEach(ClippingSortOrder.allCases) { order in
                Button(order.label) { sortOrderRaw = order.rawValue }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editing) { clip in
            ClippingEditSheet(clipping: clip)
        }
        .sheet(item: $sharing) { clip in
            ClippingShareSheet(items: ClippingShareSheet.items(for: clip))
        }
        .sheet(isPresented: $presentsSaveSheet) {
            SaveClippingSheet()
        }
        .background(Color.copiedCanvas)
        .scrollContentBackground(.hidden)
        .preferredColorScheme(.dark)
        .tint(.copiedTeal)
    }

    private enum ActionSheetFollowUp {
        case newClipping
        case sort
    }

    /// Consumed by the action-sheet's `onDismiss`. Resets the pending flag
    /// then fires the next presentation so SwiftUI sees two sequential
    /// state transitions instead of two overlapping ones.
    private func runPendingActionSheetAction() {
        guard let action = pendingActionSheetAction else { return }
        pendingActionSheetAction = nil
        switch action {
        case .newClipping:
            clipboardService.saveCurrentClipboard()
        case .sort:
            showSortPicker = true
        }
    }

    private func copyToClipboard(_ clipping: Clipping) {
        var item: [String: Any] = [:]
        if let text = clipping.text { item[UTType.utf8PlainText.identifier] = text }
        if let urlString = clipping.url, let url = URL(string: urlString) {
            item[UTType.url.identifier] = url
        }
        if let imageData = clipping.imageData {
            item[UTType.png.identifier] = imageData
        }
        // Use the service API so `lastChangeCount` advances in step with the
        // write — otherwise the next foreground tick would re-capture what
        // we just copied (see the skipNextCapture dead-flag bug).
        clipboardService.writeToPasteboard([item])
    }
}

// MARK: - Query + row rendering

/// Split into its own view so the `@Query` re-runs on selection / search change
/// without tearing down the parent's toolbar + searchable state.
private struct QueryList: View {
    let selection: ListsScreen.Selection
    let searchText: String
    @Binding var multiSelectMode: Bool
    @Binding var selectedIDs: Set<String>
    @Binding var selected: Clipping?
    @Binding var editing: Clipping?
    @Binding var sharing: Clipping?
    let copyToClipboard: (Clipping) -> Void
    let historyCap: Int
    let sortOrder: ClippingSortOrder
    let hideListClippings: Bool
    @Binding var presentsActionSheet: Bool
    @Binding var presentsSettings: Bool
    @Binding var presentsSaveSheet: Bool

    @Query private var clippings: [Clipping]
    @Query(sort: \ClipList.sortOrder) private var userLists: [ClipList]
    @State private var presentsMergePicker: Bool = false
    @State private var mergeScripts: [MergeScript] = []

    /// One-time banner prompting the user to flip iPhone Settings →
    /// Copied → Paste from Other Apps to "Allow". iOS 16+ prompts on
    /// every foreground unless that per-app preference is Allow; hiding
    /// the prompt is a real usability win. Dismiss stores a persistent
    /// AppStorage flag keyed to the app (not per-screen) so it never
    /// returns.
    @AppStorage("onboardingPasteTipDismissed") private var pasteTipDismissed: Bool = false
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext

    // Phase 16 — create + delete lists directly from the main Copied view.
    // The sidebar's ListsScreen also offers these; duplicating them here
    // means the user never has to back out of the stream to manage lists.
    @State private var presentsNewListSheet: Bool = false
    @State private var newListNameDraft: String = ""
    @State private var pendingDeleteList: ClipList?

    // Phase 16 (iOS) — content-kind filter matching the Mac popover's
    // line.3.horizontal.decrease.circle menu. Nil = show all.
    @State private var filterKind: ContentKind?

    init(
        selection: ListsScreen.Selection,
        searchText: String,
        multiSelectMode: Binding<Bool>,
        selectedIDs: Binding<Set<String>>,
        selected: Binding<Clipping?>,
        editing: Binding<Clipping?>,
        sharing: Binding<Clipping?>,
        copyToClipboard: @escaping (Clipping) -> Void,
        historyCap: Int,
        sortOrder: ClippingSortOrder,
        hideListClippings: Bool,
        presentsActionSheet: Binding<Bool>,
        presentsSettings: Binding<Bool>,
        presentsSaveSheet: Binding<Bool>
    ) {
        self.selection = selection
        self.searchText = searchText
        self._multiSelectMode = multiSelectMode
        self._selectedIDs = selectedIDs
        self._selected = selected
        self._editing = editing
        self._sharing = sharing
        self.copyToClipboard = copyToClipboard
        self.historyCap = historyCap
        self.sortOrder = sortOrder
        self.hideListClippings = hideListClippings
        self._presentsActionSheet = presentsActionSheet
        self._presentsSettings = presentsSettings
        self._presentsSaveSheet = presentsSaveSheet

        let predicate: Predicate<Clipping>
        switch selection {
        case .copied, .clipboard, .userList:
            predicate = #Predicate<Clipping> { $0.deleteDate == nil }
        case .trash:
            predicate = #Predicate<Clipping> { $0.deleteDate != nil }
        }
        self._clippings = Query(
            filter: predicate,
            sort: \Clipping.addDate,
            order: .reverse
        )
    }

    private var filtered: [Clipping] {
        let base: [Clipping]
        if case .userList(let listID) = selection {
            base = clippings.filter { $0.list?.listID == listID }
        } else if selection == .copied && hideListClippings {
            // Filter out clippings assigned to a user-created list so the
            // main Copied view only shows "unfiled" clippings. Toggled
            // via the action sheet's Hide/Show List Clippings row.
            base = clippings.filter { $0.list == nil }
        } else {
            base = clippings
        }
        let kindFiltered: [Clipping]
        if let k = filterKind {
            kindFiltered = base.filter { $0.contentKind == k }
        } else {
            kindFiltered = base
        }
        let searched: [Clipping]
        if searchText.isEmpty {
            searched = kindFiltered
        } else {
            searched = kindFiltered.filter { clip in
                clip.text?.localizedCaseInsensitiveContains(searchText) == true ||
                clip.title?.localizedCaseInsensitiveContains(searchText) == true ||
                clip.url?.localizedCaseInsensitiveContains(searchText) == true
            }
        }
        return searched.sorted(by: sortOrder.comparator)
    }

    private var isOverLimit: Bool { clippings.count >= historyCap }

    var body: some View {
        VStack(spacing: 0) {
            if filtered.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Clippings" : "No Results",
                    systemImage: "clipboard",
                    description: Text(searchText.isEmpty
                        ? "Tap the ⋯ menu to save what's on your clipboard"
                        : "No clippings match \"\(searchText)\"")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    // Phase 15 — when on the main Copied view and the
                    // user has created lists, surface them at the top so
                    // navigation doesn't require backing out to the
                    // sidebar. Each row routes via the same
                    // NavigationLink(value:) mechanism the sidebar uses,
                    // so the destination rebuilds cleanly (new @Query
                    // scope, proper nav title).
                    if selection == .copied && !pasteTipDismissed {
                        pasteTipSection
                    }
                    if selection == .copied {
                        Section("Your Lists") {
                            ForEach(userLists) { list in
                                NavigationLink(value: ListsScreen.Selection.userList(list.listID)) {
                                    HStack(spacing: 14) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(Color.copiedTeal)
                                            .font(.system(size: 20, weight: .medium))
                                            .frame(width: 26)
                                        Text(list.name)
                                            .font(.body)
                                        Spacer(minLength: 0)
                                        Text("\(list.clippingCount)")
                                            .foregroundStyle(Color.copiedSecondaryLabel)
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        if list.clippingCount == 0 {
                                            list.deleteTrashingClippings(in: modelContext)
                                        } else {
                                            pendingDeleteList = list
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    // The parent `.tint(.copiedTeal)` bleeds
                                    // into swipe actions and overrides the
                                    // destructive role color. Force red here
                                    // so "Delete" reads as destructive.
                                    .tint(.red)
                                }
                            }
                            Button {
                                newListNameDraft = ""
                                presentsNewListSheet = true
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color.copiedTeal)
                                        .font(.system(size: 20, weight: .medium))
                                        .frame(width: 26)
                                    Text("New List")
                                        .font(.body)
                                        .foregroundStyle(Color.copiedTeal)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    ForEach(filtered, id: \.clippingID) { clip in
                        HStack {
                            if multiSelectMode {
                                Image(systemName: selectedIDs.contains(clip.clippingID) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(clip.clippingID) ? Color.copiedTeal : Color.copiedSecondaryLabel)
                                    .onTapGesture {
                                        if selectedIDs.contains(clip.clippingID) {
                                            selectedIDs.remove(clip.clippingID)
                                        } else {
                                            selectedIDs.insert(clip.clippingID)
                                        }
                                    }
                            }
                            ClippingRow(clipping: clip)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if multiSelectMode {
                                        if selectedIDs.contains(clip.clippingID) {
                                            selectedIDs.remove(clip.clippingID)
                                        } else {
                                            selectedIDs.insert(clip.clippingID)
                                        }
                                    } else {
                                        selected = clip
                                    }
                                }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                let ctx = clip.modelContext
                                if clip.deleteDate != nil {
                                    // hard-delete from trash
                                    ctx?.delete(clip)
                                } else {
                                    clip.moveToTrash()
                                }
                                // SwiftData autosave is periodic, not immediate —
                                // without an explicit save the CloudKit mirror
                                // doesn't flush until the next autosave tick,
                                // which is why deletes weren't propagating to
                                // the Mac even when the user force-synced.
                                try? ctx?.save()
                            } label: {
                                Label(clip.deleteDate != nil ? "Delete" : "Trash", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if clip.deleteDate == nil {
                                Button {
                                    clip.isFavorite.toggle()
                                    try? clip.modelContext?.save()
                                } label: {
                                    Label(
                                        clip.isFavorite ? "Unfavorite" : "Favorite",
                                        systemImage: clip.isFavorite ? "star.slash" : "star.fill"
                                    )
                                }
                                .tint(.yellow)

                                Button {
                                    copyToClipboard(clip)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .tint(.copiedTeal)

                                Button {
                                    sharing = clip
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.copiedTeal)
                            } else {
                                Button {
                                    clip.restore()
                                    try? clip.modelContext?.save()
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.copiedTeal)
                            }
                        }
                        .contextMenu {
                            Button { editing = clip } label: { Label("Edit", systemImage: "pencil") }
                            Button { copyToClipboard(clip) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        }
                    }
                }
                .listStyle(.plain)
            }

            // Bottom utility bar — matches IMG_0977 layout, but swaps to a
            // Merge CTA when multi-select has 2+ rows so the Phase 8d
            // MergeScript feature is actually reachable.
            HStack {
                // Phase 14 — clip icon opens the Save Clipping panel
                // (editable preview of whatever is currently on the iOS
                // pasteboard). The row action sheet still lives on the
                // top-right ellipsis.
                Button {
                    presentsSaveSheet = true
                } label: {
                    Image(systemName: "list.clipboard")
                        .foregroundStyle(Color.copiedTeal)
                        .font(.system(size: 22, weight: .medium))
                }
                Spacer()
                if multiSelectMode && selectedIDs.count >= 2 {
                    Button {
                        presentsMergePicker = true
                    } label: {
                        Label("Merge \(selectedIDs.count)", systemImage: "arrow.triangle.merge")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.copiedTeal)
                    }
                } else {
                    Text("\(clippings.count) Clipping\(clippings.count == 1 ? "" : "s")")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isOverLimit ? Color.copiedRed : Color.primary)
                }
                Spacer()
                Button {
                    // User directive (Phase 13): the bottom-right gears
                    // icon should open Settings, not the action sheet.
                    // The action sheet is already reachable from the
                    // top-right ellipsis.
                    presentsSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Color.copiedTeal)
                        .font(.system(size: 22, weight: .medium))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.copiedCanvas.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Color.copiedSeparator.frame(height: 1) }
        }
        .navigationDestination(item: $selected) { clip in
            ClippingDetailScreen(clipping: clip)
        }
        .confirmationDialog("Merge into one clipping", isPresented: $presentsMergePicker) {
            ForEach(mergeScripts) { script in
                Button(script.name) { runMerge(with: script) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pick a template. The merged result is copied to your clipboard and saved as a new clipping.")
        }
        .alert("New List", isPresented: $presentsNewListSheet) {
            TextField("List name", text: $newListNameDraft)
            Button("Create") { createNewList(named: newListNameDraft) }
                .disabled(newListNameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give your list a name — you can rename it later.")
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
        .onAppear { mergeScripts = MergeScriptEngine.load() }
        .toolbar {
            // Content-kind filter matching the Mac popover's
            // line.3.horizontal.decrease.circle menu. SwiftUI merges
            // this toolbar with the parent's ellipsis button, so both
            // land on the top-trailing of the navigation bar.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        filterKind = nil
                    } label: {
                        HStack {
                            Text("All Types")
                            if filterKind == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach([ContentKind.text, .richText, .image, .video, .link, .code, .file, .html], id: \.self) { kind in
                        Button {
                            filterKind = kind
                        } label: {
                            HStack {
                                Text(kind.rawValue.capitalized)
                                if filterKind == kind { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: filterKind == nil
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(Color.copiedTeal)
                }
            }
        }
    }

    private func createNewList(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let list = ClipList(name: name)
        modelContext.insert(list)
        try? modelContext.save()
    }

    @ViewBuilder
    private var pasteTipSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.copiedTeal)
                    Text("Stop the Paste prompt")
                        .font(.subheadline.weight(.semibold))
                }
                Text("iOS asks \"Allow Paste?\" every time Copied reads the clipboard. Set it to Allow once, never prompt again.")
                    .font(.caption)
                    .foregroundStyle(Color.copiedSecondaryLabel)
                HStack {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Text("Open Settings")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.copiedTeal, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Dismiss") { pasteTipDismissed = true }
                        .font(.footnote)
                        .foregroundStyle(Color.copiedSecondaryLabel)
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// Run the picked merge script on the currently-selected clippings,
    /// save the rendered output as a new clipping, push it to the
    /// pasteboard, and leave multi-select mode.
    private func runMerge(with script: MergeScript) {
        // Selection order isn't tracked, so we use the list's own
        // reverse-chronological order (which is what the user sees on
        // screen). Preserves the visual top-to-bottom expectation.
        let selected = clippings.filter { selectedIDs.contains($0.clippingID) }
        guard !selected.isEmpty else { return }

        let rows = selected.map { (text: $0.text, url: $0.url, title: $0.title) }
        let output = MergeScriptEngine.run(script, rows: rows)

        let clip = Clipping(text: output, title: "Merged (\(selected.count))", url: nil)
        if let modelContext = selected.first?.modelContext {
            modelContext.insert(clip)
            try? modelContext.save()
        }

        // Push onto the system pasteboard so the user can paste it
        // immediately. UIPasteboard is used directly here because the
        // ClipboardService is an environment object on the parent view
        // and we don't thread it through the QueryList init; the auto-
        // capture path dedups against this via `isDuplicateOfLast`.
        UIPasteboard.general.string = output

        // Exit multi-select so the next interaction feels clean.
        selectedIDs.removeAll()
        multiSelectMode = false
    }
}

