import SwiftUI
import SwiftData
import CopiedKit

/// iOS edit sheet — mirrors the Mac `ClippingEditSheet` shape. Edits title +
/// text; saving updates `modifiedDate`. Images / rich text / other kinds edit
/// only the title today. Phase 9 follow-up: also lets the user assign the
/// clipping to a user-created `ClipList` (or keep it unfiled). Needed so
/// "Hide List Clippings" on the main Copied view actually has list-assigned
/// clippings to filter.
struct ClippingEditSheet: View {
    @Bindable var clipping: Clipping
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \ClipList.sortOrder) private var lists: [ClipList]
    @State private var titleDraft: String = ""
    @State private var textDraft: String = ""
    @State private var selectedListID: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Optional title", text: $titleDraft)
                        .textInputAutocapitalization(.sentences)
                }
                if clipping.text != nil {
                    Section("Text") {
                        TextEditor(text: $textDraft)
                            .frame(minHeight: 180)
                            .font(.body.monospaced())
                    }
                }
                Section {
                    Picker("List", selection: $selectedListID) {
                        Text("No list").tag("")
                        ForEach(lists) { list in
                            Text(list.name).tag(list.listID)
                        }
                    }
                } header: {
                    Text("List")
                } footer: {
                    Text("Assign this clipping to one of your custom lists, or keep it unfiled.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.copiedCanvas)
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.copiedTeal)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.copiedTeal)
                }
            }
            .tint(.copiedTeal)
            .preferredColorScheme(.dark)
        }
        .onAppear {
            titleDraft = clipping.title ?? ""
            textDraft = clipping.text ?? ""
            selectedListID = clipping.list?.listID ?? ""
        }
    }

    @Environment(\.modelContext) private var modelContext

    private func save() {
        clipping.title = titleDraft.isEmpty ? nil : titleDraft
        if clipping.text != nil { clipping.text = textDraft }
        if selectedListID.isEmpty {
            clipping.list = nil
        } else if clipping.list?.listID != selectedListID {
            clipping.list = lists.first { $0.listID == selectedListID }
        }
        clipping.modifiedDate = Date()
        // Explicit save — autosave is periodic and CloudKit mirror only
        // pushes on save commits, so without this the edit can take
        // multiple seconds to reach other devices (or be lost entirely
        // if the user backgrounds the app immediately after tapping Save).
        try? modelContext.save()
        dismiss()
    }
}
