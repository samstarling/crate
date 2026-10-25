import Foundation

/// A smart playlist's rules, as Rekordbox stores them in `djmdPlaylist.SmartList`:
///
/// ```xml
/// <NODE Id="…" LogicalOperator="1" AutomaticUpdate="0">
///   <CONDITION PropertyName="genre" Operator="1" ValueUnit="" ValueLeft="" ValueRight=""/>
/// </NODE>
/// ```
nonisolated struct SmartRule: Hashable, Sendable {
    enum Match: Sendable {
        case all, any
    }

    struct Condition: Hashable, Sendable {
        let property: String
        let operatorCode: Int
        /// For dates: "day", "week", "month" or "year".
        let unit: String
        let left: String
        /// The upper bound, for "in range".
        let right: String
    }

    /// Thrown when a rule uses something Crate can't evaluate yet, rather than showing the wrong tracks.
    struct Unsupported: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    let match: Match
    let conditions: [Condition]
    /// Rekordbox can nest groups of conditions; Crate doesn't evaluate those yet.
    let hasNestedGroups: Bool

    init?(xml: String) {
        guard let root = (try? XMLDocument(xmlString: xml))?.rootElement(), root.name == "NODE" else { return nil }
        match = root.attribute(forName: "LogicalOperator")?.stringValue == "2" ? .any : .all
        hasNestedGroups = !root.elements(forName: "NODE").isEmpty
        conditions = root.elements(forName: "CONDITION").map { element in
            func value(_ name: String) -> String { element.attribute(forName: name)?.stringValue ?? "" }
            return Condition(
                property: value("PropertyName"),
                operatorCode: Int(value("Operator")) ?? 0,
                unit: value("ValueUnit"),
                left: value("ValueLeft"),
                right: value("ValueRight")
            )
        }
    }

    /// Compiles the rules into a test for each track.
    /// - Parameter myTags: The library's My Tag names by ID, to resolve `myTag` conditions.
    func predicate(myTags: [String: String], now: Date = .now) throws -> (Track) -> Bool {
        if hasNestedGroups {
            throw Unsupported(reason: "This smart playlist uses nested groups of conditions, which Crate can't evaluate yet.")
        }
        let tests = try conditions.map { try $0.predicate(myTags: myTags, now: now) }
        switch match {
        case .all: return { track in tests.allSatisfy { $0(track) } }
        case .any: return { track in tests.contains { $0(track) } }
        }
    }
}

nonisolated extension SmartRule.Condition {
    /// Rekordbox's operator codes.
    enum Operator: Int {
        case equal = 1, notEqual, greater, less, inRange, inLast, notInLast, contains, notContains, startsWith, endsWith
    }

    func predicate(myTags: [String: String], now: Date) throws -> (Track) -> Bool {
        guard let op = Operator(rawValue: operatorCode) else {
            throw unsupported("uses operator \(operatorCode)")
        }
        switch property {
        case "name": return try text(\.title, op)
        case "artist": return try text(\.artist, op)
        case "album": return try text(\.album, op)
        case "genre": return try text(\.genre, op)
        case "label": return try text(\.label, op)
        case "key": return try text(\.key, op)
        case "comments": return try text(\.comment, op)
        case "bpm": return try number(op) { $0.bpm }
        case "rating": return try number(op) { Double($0.rating) }
        case "counter": return try number(op) { Double($0.playCount) }
        case "stockDate": return try date(\.dateAdded, op, now: now)
        case "myTag": return try myTag(op, myTags: myTags)
        default: throw unsupported("filters on \u{201C}\(property)\u{201D}")
        }
    }

    private func unsupported(_ detail: String) -> SmartRule.Unsupported {
        SmartRule.Unsupported(reason: "One of this smart playlist's conditions \(detail), which Crate can't evaluate yet.")
    }

    private func text(_ keyPath: KeyPath<Track, String>, _ op: Operator) throws -> (Track) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let value = left
        switch op {
        case .equal: return { $0[keyPath: keyPath].compare(value, options: options) == .orderedSame }
        case .notEqual: return { $0[keyPath: keyPath].compare(value, options: options) != .orderedSame }
        case .contains: return { $0[keyPath: keyPath].range(of: value, options: options) != nil }
        case .notContains: return { $0[keyPath: keyPath].range(of: value, options: options) == nil }
        case .startsWith: return { $0[keyPath: keyPath].range(of: value, options: options.union(.anchored)) != nil }
        case .endsWith: return { $0[keyPath: keyPath].range(of: value, options: options.union([.anchored, .backwards])) != nil }
        default: throw unsupported("compares \u{201C}\(property)\u{201D} with operator \(op.rawValue)")
        }
    }

    private func number(_ op: Operator, _ value: @escaping (Track) -> Double) throws -> (Track) -> Bool {
        // An empty value means zero, e.g. "Play Count is" with no number for never-played tracks.
        let lower = Double(left) ?? 0
        let upper = Double(right) ?? 0
        switch op {
        case .equal: return { value($0) == lower }
        case .notEqual: return { value($0) != lower }
        case .greater: return { value($0) > lower }
        case .less: return { value($0) < lower }
        case .inRange: return { (min(lower, upper)...max(lower, upper)).contains(value($0)) }
        default: throw unsupported("compares \u{201C}\(property)\u{201D} with operator \(op.rawValue)")
        }
    }

    /// Dates are `yyyy-MM-dd` strings, so they can be compared as strings.
    private func date(_ keyPath: KeyPath<Track, String>, _ op: Operator, now: Date) throws -> (Track) -> Bool {
        let component: Calendar.Component? = switch unit {
        case "day": .day
        case "week": .weekOfYear
        case "month": .month
        case "year": .year
        default: nil
        }
        guard op == .inLast || op == .notInLast, let component, let amount = Int(left),
              let cutoffDate = Calendar.current.date(byAdding: component, value: -amount, to: now) else {
            throw unsupported("compares \u{201C}\(property)\u{201D} in a way Crate doesn't support yet")
        }
        let cutoff = cutoffDate.formatted(.iso8601.year().month().day())
        return op == .inLast
            ? { !$0[keyPath: keyPath].isEmpty && $0[keyPath: keyPath] >= cutoff }
            : { $0[keyPath: keyPath] < cutoff }
    }

    private func myTag(_ op: Operator, myTags: [String: String]) throws -> (Track) -> Bool {
        guard myTags[left] != nil else {
            // Libraries upgraded from Rekordbox 5 can keep old My Tag IDs in their smart playlists,
            // and nothing in the database maps them to the new ones.
            throw SmartRule.Unsupported(reason: "This smart playlist refers to a My Tag (ID \(left)) that isn\u{2019}t in this library, probably from before an upgrade from Rekordbox 5. Re-select the tag in Rekordbox\u{2019}s smart playlist editor to fix it.")
        }
        let tag = left
        switch op {
        case .contains: return { $0.myTagIDs.contains(tag) }
        case .notContains: return { !$0.myTagIDs.contains(tag) }
        default: throw unsupported("compares My Tags with operator \(op.rawValue)")
        }
    }
}
