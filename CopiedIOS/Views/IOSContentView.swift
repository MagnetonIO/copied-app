import SwiftUI
import CopiedKit

/// Thin delegate to `RootNavigator`. Kept as a named entry point so the app
/// scene and previews have a stable top-level type to reference.
struct IOSContentView: View {
    var body: some View {
        RootNavigator()
    }
}
