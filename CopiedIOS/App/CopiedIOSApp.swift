import SwiftUI
import SwiftData
import CopiedKit

@main
struct CopiedIOSApp: App {
    @State private var clipboardService = ClipboardService()

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .environment(clipboardService)
        }
        .modelContainer(for: CopiedSchema.models)
    }
}
