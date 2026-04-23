import Foundation

/// User-defined automation rules that run against every incoming
/// `Clipping` right before it's saved to SwiftData. Each rule pairs a
/// condition (predicate on the captured payload) with an action (a
/// mutation applied to the clipping, or a veto that skips the save
/// entirely).
///
/// Storage lives in the App-Group UserDefaults under `rules.v1` as JSON,
/// so it's legible to both the iOS host and share-extension pipelines
/// once they start evaluating rules at capture time.
public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var condition: Condition
    public var action: Action
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        condition: Condition,
        action: Action,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.condition = condition
        self.action = action
        self.isEnabled = isEnabled
    }

    /// Predicates evaluated against the captured clipping. Kept small and
    /// well-typed — a free-form regex/AST would be more expressive but
    /// would also invite bad user input, so the MVP is a closed enum.
    public enum Condition: Codable, Hashable, Sendable {
        case textContains(String)
        case textLengthOver(Int)
        case hasURL
        case hasImage

        public var humanLabel: String {
            switch self {
            case .textContains(let s): return "Text contains “\(s)”"
            case .textLengthOver(let n): return "Text longer than \(n) chars"
            case .hasURL: return "Has URL"
            case .hasImage: return "Has image"
            }
        }

        func matches(text: String?, url: String?, imageData: Data?) -> Bool {
            switch self {
            case .textContains(let needle):
                guard let text, !needle.isEmpty else { return false }
                return text.localizedCaseInsensitiveContains(needle)
            case .textLengthOver(let n):
                return (text?.count ?? 0) > n
            case .hasURL:
                return url?.isEmpty == false
            case .hasImage:
                return imageData?.isEmpty == false
            }
        }
    }

    /// Actions the engine can take on a matching clipping. `skip` is a
    /// soft reject — the host treats it as "don't save this capture at
    /// all," useful for blocklist rules.
    public enum Action: Codable, Hashable, Sendable {
        case markFavorite
        case routeToList(String)   // ClipList.listID
        case skip

        public var humanLabel: String {
            switch self {
            case .markFavorite: return "Mark favorite"
            case .routeToList(let id): return "Route to list \(id)"
            case .skip: return "Skip (don't save)"
            }
        }
    }
}

/// Decision returned from `RuleEngine.evaluate`. Callers use this to
/// decide whether to persist the clipping, what flags to set, and which
/// list it should belong to — keeping the rule application logic in one
/// place instead of smeared across the capture pipelines.
public struct RuleOutcome: Sendable {
    public var shouldSave: Bool
    public var markFavorite: Bool
    public var routeToListID: String?
    public var matchedRuleIDs: [String]

    public static let allow = RuleOutcome(
        shouldSave: true,
        markFavorite: false,
        routeToListID: nil,
        matchedRuleIDs: []
    )
}

/// Stateless engine + persisted ruleset. All rules are loaded once at
/// evaluate time — fine for user-sized lists (expected under 50 rules).
public enum RuleEngine {
    public static let storageKey = "rules.v1"

    /// Load from App-Group UserDefaults so both the iOS app and the
    /// share extension see the same ruleset.
    public static func load() -> [Rule] {
        guard let data = SharedStore.defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Rule].self, from: data)) ?? []
    }

    public static func save(_ rules: [Rule]) {
        let data = (try? JSONEncoder().encode(rules)) ?? Data()
        SharedStore.defaults.set(data, forKey: storageKey)
    }

    /// Apply every enabled rule to the captured payload. Actions stack —
    /// if one rule marks favorite and another routes to a list, both
    /// flags land on the final clipping. `skip` short-circuits.
    public static func evaluate(
        text: String?,
        url: String?,
        imageData: Data?,
        rules: [Rule]? = nil
    ) -> RuleOutcome {
        var outcome = RuleOutcome.allow
        let active = (rules ?? load()).filter { $0.isEnabled }
        for rule in active where rule.condition.matches(text: text, url: url, imageData: imageData) {
            outcome.matchedRuleIDs.append(rule.id)
            switch rule.action {
            case .markFavorite:
                outcome.markFavorite = true
            case .routeToList(let listID):
                outcome.routeToListID = listID
            case .skip:
                outcome.shouldSave = false
                return outcome
            }
        }
        return outcome
    }
}
