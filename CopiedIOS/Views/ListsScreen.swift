import SwiftUI
import SwiftData
import CopiedKit

/// The root Lists screen — matches `images/IMG_0979.png`:
/// - "Copied" (all clippings, clock icon, count in red when at/over limit)
/// - "Clipboard" (system-type placeholder, teal clipboard icon)
/// - divider
/// - user `ClipList` rows with counts + "New List" (teal + icon, teal label)
/// - divider
/// - "Trash" (red trash icon + count in gray)
/// - "Settings" (sliders icon, opens modal sheet)
struct ListsScreen: View {
    enum Selection: Hashable {
        case copied        // all active clippings
        case clipboard     // live clipboard (same as copied for now)
        case favorites     // active clippings with isFavorite == true
        case userList(String)  // ClipList.listID
        case trash
    }

    @Binding var selection: Selection
    @Binding var presentsSettings: Bool
    /// When true, rows don't push their own destination — caller (iPad split
    /// view) owns destination presentation via the detail pane. Default false
    /// for iPhone NavigationStack use.
    var registersDestination: Bool = true
    var onSelect: (() -> Void)? = nil

    @State private var isNamingNewList = false
    @State private var newListNameDraft = ""
    /// Swipe-trailing Delete for user lists. Empty lists delete silently;
    /// lists with clippings raise this confirmation so the user understands
    /// the clippings move to Trash (recoverable) rather than vanishing.
    @State private var pendingDeleteList: ClipList?

    @Query(filter: #Predicate<Clipping> { $0.deleteDate == nil })
    private var activeClippings: [Clipping]
    @Query(filter: #Predicate<Clipping> { $0.deleteDate != nil })
    private var trashedClippings: [Clipping]
    @Query(filter: #Predicate<Clipping> { $0.isFavorite == true && $0.deleteDate == nil })
    private var favoriteClippings: [Clipping]
    @Query(sort: \ClipList.sortOrder)
    private var userLists: [ClipList]

    @Environment(\.modelContext) private var modelContext

    private var totalCount: Int { activeClippings.count }
    private var trashCount: Int { trashedClippings.count }
    private var favoritesCount: Int { favoriteClippings.count }

    /// Derived from the Mac default (maxHistory=500 from `ClipboardService`).
    /// When at or over this limit, the count turns red — matches the screenshot.
    private var isOverLimit: Bool { totalCount >= 500 }

    var body: some View {
        List {
            Section {
                NavigationLink(value: Selection.copied) {
                    RowLabel(
                        icon: "clock",
                        iconColor: .copiedTeal,
                        title: "Copied",
                        trailing: "\(totalCount)",
                        trailingColor: isOverLimit ? .copiedRed : .copiedSecondaryLabel
                    )
                }
                NavigationLink(value: Selection.favorites) {
                    RowLabel(
                        icon: "star.fill",
                        iconColor: .copiedTeal,
                        title: "Favorites",
                        trailing: "\(favoritesCount)",
                        trailingColor: .copiedSecondaryLabel
                    )
                }
                NavigationLink(value: Selection.clipboard) {
                    RowLabel(
                        icon: "list.clipboard",
                        iconColor: .copiedTeal,
                        title: "Clipboard"
                    )
                }
            }

            Section {
                ForEach(userLists) { list in
                    NavigationLink(value: Selection.userList(list.listID)) {
                        RowLabel(
                            icon: "folder",
                            iconColor: .copiedTeal,
                            title: list.name,
                            trailing: "\(list.clippingCount)",
                            trailingColor: .copiedSecondaryLabel
                        )
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
                    }
                }

                Button {
                    newListNameDraft = ""
                    isNamingNewList = true
                } label: {
                    RowLabel(
                        icon: "plus.circle.fill",
                        iconColor: .copiedTeal,
                        title: "New List",
                        titleColor: .copiedTeal
                    )
                }
            }

            Section {
                NavigationLink(value: Selection.trash) {
                    RowLabel(
                        icon: "trash",
                        iconColor: .copiedRed,
                        title: "Trash",
                        trailing: trashCount > 0 ? "\(trashCount)" : nil,
                        trailingColor: .copiedSecondaryLabel
                    )
                }

                Button {
                    presentsSettings = true
                } label: {
                    RowLabel(
                        icon: "slider.horizontal.3",
                        iconColor: .copiedTeal,
                        title: "Settings"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.copiedCanvas)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ConditionalDestination(enabled: registersDestination, presentsSettings: $presentsSettings))
        .preferredColorScheme(.dark)
        .alert("New List", isPresented: $isNamingNewList) {
            TextField("List name", text: $newListNameDraft)
            Button("Create") { addNewList(named: newListNameDraft) }
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
            Text("The \(list.clippingCount) clipping\(list.clippingCount == 1 ? "" : "s") in this list will move to Trash — recoverable for the next \(trashRetentionDays) days.")
        }
    }

    @AppStorage("trashRetentionDays") private var trashRetentionDays: Int = 30

    private func addNewList(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let list = ClipList(name: name)
        modelContext.insert(list)
        try? modelContext.save()
    }
}

/// `.navigationDestination(for:)` is only safe on the active stack. When the
/// parent is a NavigationSplitView, the sidebar should NOT register its own
/// destination (the detail column handles that), otherwise taps push a second
/// detail over the sidebar instead of updating the detail pane.
private struct ConditionalDestination: ViewModifier {
    let enabled: Bool
    @Binding var presentsSettings: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: ListsScreen.Selection.self) { sel in
                ListsScreen.destination(for: sel, presentsSettings: $presentsSettings)
            }
        } else {
            content
        }
    }
}

extension ListsScreen {
    /// Single source of truth for "what does each sidebar row open". The
    /// Clipboard row forks to the live-pasteboard preview; everything else
    /// keeps going to the unified list screen. The `presentsSettings`
    /// binding is threaded through so the Clippings-list bottom-right
    /// gears icon can raise the root's Settings sheet (Phase 13).
    @ViewBuilder
    static func destination(for selection: Selection, presentsSettings: Binding<Bool>) -> some View {
        switch selection {
        case .clipboard:
            ClipboardScreen()
        default:
            ClippingsListScreen(selection: selection, presentsSettings: presentsSettings)
        }
    }
}

/// Inset-grouped row with leading icon, label, and optional trailing text.
/// Mirrors the visual rhythm of `images/IMG_0979.png` — icons are always teal
/// unless overridden (trash is red), and trailing counts use the muted gray
/// except when over-limit (red).
private struct RowLabel: View {
    let icon: String
    var iconColor: Color = .copiedTeal
    let title: String
    var titleColor: Color = .primary
    var trailing: String? = nil
    var trailingColor: Color = .copiedSecondaryLabel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 26)
            Text(title)
                .font(.body)
                .foregroundStyle(titleColor)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.body)
                    .foregroundStyle(trailingColor)
            }
        }
    }
}
