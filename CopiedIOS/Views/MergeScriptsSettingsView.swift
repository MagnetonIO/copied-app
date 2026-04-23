import SwiftUI
import CopiedKit

/// Settings surface listing user-configurable merge scripts. Each script
/// combines multiple selected clippings into one string via a template
/// + separator. Matches the style of `RulesSettingsView` for
/// consistency — tap to edit, swipe to delete, + to add.
struct MergeScriptsSettingsView: View {
    @State private var scripts: [MergeScript] = []
    @State private var editing: MergeScriptDraft?

    var body: some View {
        List {
            Section {
                if scripts.isEmpty {
                    Text("No merge scripts yet. Tap + to create one.")
                        .foregroundStyle(Color.copiedSecondaryLabel)
                } else {
                    ForEach(scripts) { script in
                        Button { editing = MergeScriptDraft(script: script) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.triangle.merge")
                                    .foregroundStyle(Color.copiedTeal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(script.name)
                                        .font(.body)
                                        .foregroundStyle(Color.primary)
                                    Text(previewLine(for: script))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Color.copiedSecondaryLabel)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { delete(script) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } footer: {
                Text("Merge scripts combine multi-selected clippings into a single string. Select clippings on the Copied screen and pick a script from the merge menu.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.copiedCanvas)
        .navigationTitle("Merge Scripts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = MergeScriptDraft(script: MergeScript(
                        name: "New Script",
                        template: "{{text}}",
                        separator: "\n"
                    ))
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.copiedTeal)
                }
            }
        }
        .sheet(item: $editing) { draft in
            MergeScriptEditor(draft: draft, onSave: save, onCancel: { editing = nil })
        }
        .onAppear { scripts = MergeScriptEngine.load() }
        .tint(.copiedTeal)
        .preferredColorScheme(.dark)
    }

    /// Render a concrete example to the user so they see the shape of
    /// the output without having to mentally template-expand.
    private func previewLine(for script: MergeScript) -> String {
        let sample: [(text: String?, url: String?, title: String?)] = [
            ("Apple", "https://apple.com", "Apple"),
            ("Example", "https://example.com", "Example")
        ]
        let rendered = MergeScriptEngine.run(script, rows: sample)
        return rendered.replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    private func save(_ draft: MergeScriptDraft) {
        var next = scripts
        if let idx = next.firstIndex(where: { $0.id == draft.id }) {
            next[idx] = draft.asScript
        } else {
            next.append(draft.asScript)
        }
        scripts = next
        MergeScriptEngine.save(next)
        editing = nil
    }

    private func delete(_ script: MergeScript) {
        let next = scripts.filter { $0.id != script.id }
        scripts = next
        MergeScriptEngine.save(next)
    }
}

struct MergeScriptDraft: Identifiable {
    let id: String
    var name: String
    var template: String
    var separator: String

    init(script: MergeScript) {
        self.id = script.id
        self.name = script.name
        self.template = script.template
        self.separator = script.separator
    }

    var asScript: MergeScript {
        MergeScript(id: id, name: name, template: template, separator: separator)
    }
}

struct MergeScriptEditor: View {
    @State var draft: MergeScriptDraft
    let onSave: (MergeScriptDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Script name", text: $draft.name)
                }
                Section {
                    TextField("Template", text: $draft.template, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.body.monospaced())
                } header: {
                    Text("Template")
                } footer: {
                    Text("Tokens: {{text}}, {{url}}, {{title}}. Everything else is literal.")
                }
                Section("Separator") {
                    Picker("Separator", selection: $draft.separator) {
                        Text("Newline").tag("\n")
                        Text("Space").tag(" ")
                        Text("Comma + space").tag(", ")
                        Text("Pipe").tag(" | ")
                        Text("None").tag("")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.copiedCanvas)
            .navigationTitle("Edit Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(draft) }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .tint(.copiedTeal)
            .preferredColorScheme(.dark)
        }
    }
}
