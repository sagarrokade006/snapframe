import Foundation

public struct CaptureItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: String
    public var createdAt: Date
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var formatTitle: String
    public var byteCount: Int
    public var savedPath: String?
    public var tags: [String]
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: String,
        createdAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double,
        formatTitle: String,
        byteCount: Int,
        savedPath: String?,
        tags: [String] = [],
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.formatTitle = formatTitle
        self.byteCount = byteCount
        self.savedPath = savedPath
        self.tags = tags
        self.isPinned = isPinned
    }
}

/// The library's contents, newest first. Files on disk are handled by the app layer.
public enum SavedFile {
    /// True only when a saved file is really gone. An unplugged drive or a blocked folder does not count.
    public static func isDeleted(atPath path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) != 0, errno == ENOENT || errno == ENOTDIR else { return false }
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0] == "Volumes" {
            return FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
        }
        return true
    }
}

public struct LibraryIndex: Codable, Equatable, Sendable {
    public var items: [CaptureItem]

    public init(items: [CaptureItem] = []) {
        self.items = items
    }

    public mutating func add(_ item: CaptureItem) {
        items.insert(item, at: 0)
    }

    public mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func togglePinned(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
    }

    public mutating func addTag(_ rawTag: String, to id: UUID) {
        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, let index = items.firstIndex(where: { $0.id == id }),
              !items[index].tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
        else { return }
        items[index].tags.append(tag)
    }

    public mutating func removeTag(_ tag: String, from id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].tags.removeAll { $0 == tag }
    }

    public var allTags: [String] {
        var seen = Set<String>()
        return items.flatMap(\.tags).filter { seen.insert($0.lowercased()).inserted }.sorted()
    }

    public func filtered(kind: String?, tag: String?, query: String, pinnedOnly: Bool) -> [CaptureItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            if pinnedOnly, !item.isPinned { return false }
            if let kind, item.kind != kind { return false }
            if let tag, !item.tags.contains(tag) { return false }
            if search.isEmpty { return true }
            return item.name.localizedCaseInsensitiveContains(search)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    /// Removes unpinned items older than `days` and returns them. Zero days means keep forever.
    public mutating func purge(olderThanDays days: Int, now: Date) -> [CaptureItem] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let expired = items.filter { !$0.isPinned && !$0.isStudio && $0.createdAt < cutoff }
        let ids = Set(expired.map(\.id))
        items.removeAll { ids.contains($0.id) }
        return expired
    }
}

public enum CaptureAspect: String, CaseIterable, Sendable {
    case free, square, fourThree, threeTwo, sixteenNine

    public var title: String {
        switch self {
        case .free: return "Free"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        }
    }

    /// Width divided by height. Nil means unconstrained.
    public var value: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        }
    }
}

public struct ChangelogEntry: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case new = "New", better = "Better", fixed = "Fixed", note = "Note"
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Turns GitHub release notes into labelled lines for the update window.
public enum Changelog {
    public static func parse(_ markdown: String) -> [ChangelogEntry] {
        let lines = markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let bullets = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
        let source = bullets.isEmpty ? lines : bullets.map { String($0.dropFirst(2)) }
        return source.map(entry)
    }

    private static func entry(_ line: String) -> ChangelogEntry {
        let prefixes: [(String, ChangelogEntry.Kind)] = [
            ("fixed", .fixed), ("fix", .fixed),
            ("new", .new), ("added", .new), ("add", .new),
            ("improved", .better), ("better", .better), ("faster", .better),
        ]
        let lower = line.lowercased()

        for (prefix, kind) in prefixes where lower.hasPrefix(prefix + ":") {
            let text = line.dropFirst(prefix.count + 1).trimmingCharacters(in: .whitespaces)
            return ChangelogEntry(kind: kind, text: text.prefix(1).uppercased() + text.dropFirst())
        }
        for (prefix, kind) in prefixes where lower.hasPrefix(prefix + " ") {
            return ChangelogEntry(kind: kind, text: line)
        }
        return ChangelogEntry(kind: .note, text: line)
    }
}
