import SwiftUI
import SwiftData
import CopiedKit

/// Top-level navigation for the iOS app. iPhone uses a `NavigationStack` rooted
/// on `ListsScreen` (matching `images/IMG_0979.png`). iPad / regular-width keeps
/// a split view with Lists as the persistent sidebar. Settings is always a
/// modal sheet (matching `images/IMG_0978.png`) — never a tab, never pushed.
struct RootNavigator: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipboardService.self) private var clipboardService
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedList: ListsScreen.Selection = .copied
    @State private var presentsSettings = false
    /// Pre-seeded nav path so the iPhone opens straight into the Copied
    /// clippings view — back button still returns to ListsScreen for lists
    /// management. Previously the user had to tap Copied on every cold
    /// launch, which was an extra step for the most-used screen.
    @State private var path: [ListsScreen.Selection] = [.copied]

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    // iPad: sidebar is select-only; detail column owns destination.
                    ListsScreen(
                        selection: $selectedList,
                        presentsSettings: $presentsSettings,
                        registersDestination: false
                    )
                } detail: {
                    NavigationStack {
                        ListsScreen.destination(for: selectedList, presentsSettings: $presentsSettings)
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    ListsScreen(
                        selection: $selectedList,
                        presentsSettings: $presentsSettings
                    )
                }
            }
        }
        .sheet(isPresented: $presentsSettings) {
            SettingsSheet()
        }
        .onAppear {
            clipboardService.configure(modelContext: modelContext)
            clipboardService.start()
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS throttles pasteboard access and suspends apps, so we can't
            // poll in the background. Foreground transition is our trigger
            // for "check for a new copy that happened while we were away."
            if phase == .active {
                clipboardService.checkForPasteboardChanges()
                drainShareInbox()
            }
        }
    }

    /// Pull anything the Share Extension(s) wrote into the App Group inbox
    /// into the main SwiftData store. We only acknowledge (delete) an entry
    /// after `modelContext.save()` succeeds for that entry — so a crash
    /// between decode and save means the share survives to the next launch.
    @MainActor
    private func drainShareInbox() {
        let entries = SharedStore.readInbox()
        guard !entries.isEmpty else { return }
        for entry in entries {
            let item = entry.pending

            // Run user-defined rules before touching SwiftData — same
            // semantics as the iOS auto-capture path in `ClipboardService`.
            // `.skip` acks the inbox entry so we don't loop on it next
            // foreground without ever persisting anything.
            let outcome = RuleEngine.evaluate(
                text: item.text,
                url: item.url,
                imageData: item.imageData
            )
            guard outcome.shouldSave else {
                SharedStore.acknowledge(entry)
                continue
            }

            let clip = Clipping(
                text: item.text,
                title: item.title,
                url: item.url
            )
            if let data = item.imageData {
                clip.imageData = data
                clip.hasImage = true
                clip.imageByteCount = data.count
            }
            if outcome.markFavorite { clip.isFavorite = true }
            if let listID = outcome.routeToListID {
                var descriptor = FetchDescriptor<ClipList>(
                    predicate: #Predicate<ClipList> { $0.listID == listID }
                )
                descriptor.fetchLimit = 1
                if let list = try? modelContext.fetch(descriptor).first {
                    clip.list = list
                }
            }

            // Route through the canonical insert pipeline: it runs the
            // empty-shell guard (so a Share Extension entry that wrote
            // all-nil fields can't surface as a ghost "Empty Clipping"),
            // dedups against existing content by hash, and enqueues the
            // row for CloudKit sync. Ack the inbox entry in every
            // outcome except a pure failure — rejected/merged both
            // mean the entry was handled successfully.
            switch ClipboardService.insertOrMerge(clip, in: modelContext) {
            case .inserted, .merged:
                SharedStore.acknowledge(entry)
            case .rejected:
                NSLog("drainShareInbox: empty entry \(item.id) dropped")
                SharedStore.acknowledge(entry)
            }
        }
    }
}
