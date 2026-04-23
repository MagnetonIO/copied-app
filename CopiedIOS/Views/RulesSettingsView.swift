import SwiftUI
import SwiftData
import CopiedKit

/// Settings surface for the user's automation rules. Lists the current
/// ruleset, lets the user toggle, edit, add, or delete rules. The
/// ruleset is stored in the App-Group UserDefaults via `RuleEngine` so
/// the host and the share extension evaluate the same rules.
struct RulesSettingsView: View {
    @State private var rules: [Rule] = []
    @State private var editing: RuleDraft?

    var body: some View {
        List {
            Section {
                if rules.isEmpty {
                    Text("No rules yet. Tap + to create one.")
                        .foregroundStyle(Color.copiedSecondaryLabel)
                } else {
                    ForEach(rules) { rule in
                        Button { editing = RuleDraft(rule: rule) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(rule.isEnabled ? Color.copiedTeal : Color.copiedSecondaryLabel)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.name)
                                        .font(.body)
                                        .foregroundStyle(Color.primary)
                                    Text("\(rule.condition.humanLabel) → \(rule.action.humanLabel)")
                                        .font(.caption)
                                        .foregroundStyle(Color.copiedSecondaryLabel)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { delete(rule) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } footer: {
                Text("Rules run on every captured clipping before it's saved. Tap a rule to edit, or swipe left to delete.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.copiedCanvas)
        .navigationTitle("Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = RuleDraft(rule: Rule(
                        name: "New Rule",
                        condition: .textContains(""),
                        action: .markFavorite
                    ))
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.copiedTeal)
                }
            }
        }
        .sheet(item: $editing) { draft in
            RuleEditor(draft: draft, onSave: save, onCancel: { editing = nil })
        }
        .onAppear { rules = RuleEngine.load() }
        .tint(.copiedTeal)
        .preferredColorScheme(.dark)
    }

    private func save(_ draft: RuleDraft) {
        var next = rules
        if let idx = next.firstIndex(where: { $0.id == draft.id }) {
            next[idx] = draft.asRule
        } else {
            next.append(draft.asRule)
        }
        rules = next
        RuleEngine.save(next)
        editing = nil
    }

    private func delete(_ rule: Rule) {
        let next = rules.filter { $0.id != rule.id }
        rules = next
        RuleEngine.save(next)
    }
}

/// Editor-friendly mirror of `Rule`. We keep the condition/action value
/// types split into independent `@State` fields so the form can bind to
/// a `TextField` for the string payload and a `Picker` for the list id
/// without wrestling with enum-associated-value bindings.
struct RuleDraft: Identifiable {
    let id: String
    var name: String
    var conditionKind: ConditionKind
    var textContainsValue: String
    var textLengthValue: Int
    var actionKind: ActionKind
    var routeListID: String
    var isEnabled: Bool

    enum ConditionKind: String, CaseIterable, Identifiable {
        case textContains, textLengthOver, hasURL, hasImage
        var id: String { rawValue }
        var label: String {
            switch self {
            case .textContains: "Text contains"
            case .textLengthOver: "Text length over"
            case .hasURL: "Has URL"
            case .hasImage: "Has image"
            }
        }
    }

    enum ActionKind: String, CaseIterable, Identifiable {
        case markFavorite, routeToList, skip
        var id: String { rawValue }
        var label: String {
            switch self {
            case .markFavorite: "Mark favorite"
            case .routeToList: "Route to list"
            case .skip: "Skip (don't save)"
            }
        }
    }

    init(rule: Rule) {
        self.id = rule.id
        self.name = rule.name
        self.isEnabled = rule.isEnabled
        switch rule.condition {
        case .textContains(let s):
            self.conditionKind = .textContains
            self.textContainsValue = s
            self.textLengthValue = 0
        case .textLengthOver(let n):
            self.conditionKind = .textLengthOver
            self.textContainsValue = ""
            self.textLengthValue = n
        case .hasURL:
            self.conditionKind = .hasURL
            self.textContainsValue = ""
            self.textLengthValue = 0
        case .hasImage:
            self.conditionKind = .hasImage
            self.textContainsValue = ""
            self.textLengthValue = 0
        }
        switch rule.action {
        case .markFavorite:
            self.actionKind = .markFavorite
            self.routeListID = ""
        case .routeToList(let id):
            self.actionKind = .routeToList
            self.routeListID = id
        case .skip:
            self.actionKind = .skip
            self.routeListID = ""
        }
    }

    var asRule: Rule {
        let condition: Rule.Condition
        switch conditionKind {
        case .textContains: condition = .textContains(textContainsValue)
        case .textLengthOver: condition = .textLengthOver(textLengthValue)
        case .hasURL: condition = .hasURL
        case .hasImage: condition = .hasImage
        }
        let action: Rule.Action
        switch actionKind {
        case .markFavorite: action = .markFavorite
        case .routeToList: action = .routeToList(routeListID)
        case .skip: action = .skip
        }
        return Rule(id: id, name: name, condition: condition, action: action, isEnabled: isEnabled)
    }

    /// Gating check for the Save button — prevents the user from shipping
    /// rules that can't fire (empty needle, zero-length threshold,
    /// unrouted "route to list"). Codex flagged this as MEDIUM after the
    /// Phase 8c review.
    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch conditionKind {
        case .textContains:
            guard !textContainsValue.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        case .textLengthOver:
            guard textLengthValue > 0 else { return false }
        case .hasURL, .hasImage:
            break
        }
        switch actionKind {
        case .routeToList:
            guard !routeListID.isEmpty else { return false }
        case .markFavorite, .skip:
            break
        }
        return true
    }
}

/// Modal form for adding or editing a single rule. Kept as its own sheet
/// so the list view doesn't need to juggle form state.
struct RuleEditor: View {
    @State var draft: RuleDraft
    let onSave: (RuleDraft) -> Void
    let onCancel: () -> Void

    @Query(sort: \ClipList.sortOrder) private var lists: [ClipList]
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Rule name", text: $draft.name)
                }
                Section("Enabled") {
                    Toggle("Active", isOn: $draft.isEnabled)
                        .tint(.copiedTeal)
                }
                Section("Condition") {
                    Picker("Kind", selection: $draft.conditionKind) {
                        ForEach(RuleDraft.ConditionKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    switch draft.conditionKind {
                    case .textContains:
                        TextField("Needle", text: $draft.textContainsValue)
                    case .textLengthOver:
                        Stepper("Over \(draft.textLengthValue) chars", value: $draft.textLengthValue, in: 0...10_000, step: 50)
                    case .hasURL, .hasImage:
                        EmptyView()
                    }
                }
                Section("Action") {
                    Picker("Kind", selection: $draft.actionKind) {
                        ForEach(RuleDraft.ActionKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    if draft.actionKind == .routeToList {
                        if lists.isEmpty {
                            Text("Create a custom list first.")
                                .foregroundStyle(Color.copiedSecondaryLabel)
                        } else {
                            Picker("Destination", selection: $draft.routeListID) {
                                ForEach(lists) { list in
                                    Text(list.name).tag(list.listID)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.copiedCanvas)
            .navigationTitle("Edit Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { attemptSave() }
                }
            }
            .tint(.copiedTeal)
            .preferredColorScheme(.dark)
            .alert(
                "Rule incomplete",
                isPresented: Binding(
                    get: { validationMessage != nil },
                    set: { if !$0 { validationMessage = nil } }
                ),
                presenting: validationMessage
            ) { _ in
                Button("OK", role: .cancel) { validationMessage = nil }
            } message: { msg in
                Text(msg)
            }
        }
    }

    /// Runs the same checks as `RuleDraft.isValid` but surfaces a
    /// concrete reason. Apple's toolbar `.disabled` sometimes fails to
    /// propagate to the rendered Save control on iOS 26, so we also
    /// enforce at tap time — belt and braces.
    private func attemptSave() {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            validationMessage = "Give the rule a name before saving."
            return
        }
        switch draft.conditionKind {
        case .textContains where draft.textContainsValue.trimmingCharacters(in: .whitespaces).isEmpty:
            validationMessage = "Enter some text for the condition to match."
            return
        case .textLengthOver where draft.textLengthValue <= 0:
            validationMessage = "Set a length threshold greater than zero."
            return
        default:
            break
        }
        if draft.actionKind == .routeToList && draft.routeListID.isEmpty {
            validationMessage = "Pick a destination list, or switch to a different action."
            return
        }
        onSave(draft)
    }
}
