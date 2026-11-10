import AppKit
import Combine
import SnapframeCore

/// Keeps a private copy of every capture on this Mac, so Home works even for clipboard-only captures.
@MainActor
final class CaptureLibrary: ObservableObject {
    /// Lets debug previews use a throwaway folder. Set it before first touching `shared`.
    static var overrideDirectory: URL?
    static let shared = CaptureLibrary()

    @Published private(set) var index = LibraryIndex()
    @Published var selectedID: UUID?

    private let directory: URL
    private let thumbnails = NSCache<NSUUID, NSImage>()

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = Self.overrideDirectory ?? support.appendingPathComponent("Snapframe/Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode(LibraryIndex.self, from: data) {
            index = saved
        }
        purgeExpired()
    }

    func imageURL(id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }
    private func thumbnailURL(id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).jpg") }
    func projectURL(id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).snapframe") }

    @discardableResult
    func add(
        image: CGImage,
        scale: CGFloat,
        kind: String,
        name: String,
        formatTitle: String,
        savedURL: URL?
    ) async -> CaptureItem? {
        let id = UUID()
        let imageDestination = imageURL(id: id)
        let thumbnailDestination = thumbnailURL(id: id)

        let pngSize: Int? = await Task.detached(priority: .utility) {
            guard let png = try? OutputService.encode(image, format: .png, quality: 1, scale: scale),
                  (try? png.write(to: imageDestination, options: .atomic)) != nil
            else { return nil }
            let ratio = CGFloat(image.width) / 640
            let small = ratio > 1 ? OutputService.downscaled(image, by: ratio) : image
            if let jpeg = try? OutputService.encode(small, format: .jpeg, quality: 0.85, scale: 1) {
                try? jpeg.write(to: thumbnailDestination, options: .atomic)
            }
            return png.count
        }.value
        guard let pngSize else { return nil }

        let savedSize = savedURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int
        }
        let item = CaptureItem(
            id: id, name: name, kind: kind, createdAt: Date(),
            pixelWidth: image.width, pixelHeight: image.height, scale: Double(scale),
            formatTitle: formatTitle, byteCount: savedSize ?? pngSize, savedPath: savedURL?.path
        )
        index.add(item)
        selectedID = item.id
        save()
        return item
    }

    /// Replaces a capture with its edited version, so redacted pixels leave the library.
    func storeEdit(_ image: CGImage, scale: CGFloat, projectData: Data, itemID: UUID?) async {
        guard let itemID, let position = index.items.firstIndex(where: { $0.id == itemID }) else {
            if let item = await add(image: image, scale: scale, kind: "Edited", name: "Edited capture", formatTitle: "PNG", savedURL: nil) {
                try? projectData.write(to: projectURL(id: item.id), options: .atomic)
            }
            return
        }

        let imageDestination = imageURL(id: itemID)
        let thumbnailDestination = thumbnailURL(id: itemID)
        let projectDestination = projectURL(id: itemID)
        let pngSize: Int? = await Task.detached(priority: .userInitiated) {
            guard let png = try? OutputService.encode(image, format: .png, quality: 1, scale: scale),
                  (try? png.write(to: imageDestination, options: .atomic)) != nil
            else { return nil }
            let ratio = CGFloat(image.width) / 640
            let small = ratio > 1 ? OutputService.downscaled(image, by: ratio) : image
            if let jpeg = try? OutputService.encode(small, format: .jpeg, quality: 0.85, scale: 1) {
                try? jpeg.write(to: thumbnailDestination, options: .atomic)
            }
            try? projectData.write(to: projectDestination, options: .atomic)
            return png.count
        }.value
        guard let pngSize else { return }

        thumbnails.removeObject(forKey: itemID as NSUUID)
        index.items[position].pixelWidth = image.width
        index.items[position].pixelHeight = image.height
        index.items[position].byteCount = pngSize
        index.items[position].formatTitle = "PNG"
        index.items[position].savedPath = nil
        selectedID = itemID
        save()
    }

    func thumbnail(for item: CaptureItem) -> NSImage? {
        let key = item.id as NSUUID
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(id: item.id)) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    private func existingFile(for item: CaptureItem) -> URL {
        if let path = item.savedPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return imageURL(id: item.id)
    }

    func copy(_ item: CaptureItem) {
        guard let data = try? Data(contentsOf: imageURL(id: item.id)) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
    }

    func open(_ item: CaptureItem) {
        NSWorkspace.shared.open(existingFile(for: item))
    }

    func reveal(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([existingFile(for: item)])
    }

    /// Removes the library copy. A file already saved to the export folder is left alone.
    func delete(_ item: CaptureItem) {
        index.remove(id: item.id)
        removeFiles(of: item)
        if selectedID == item.id { selectedID = nil }
        save()
    }

    func togglePinned(_ item: CaptureItem) {
        index.togglePinned(id: item.id)
        save()
    }

    func addTag(_ tag: String, to item: CaptureItem) {
        index.addTag(tag, to: item.id)
        save()
    }

    func removeTag(_ tag: String, from item: CaptureItem) {
        index.removeTag(tag, from: item.id)
        save()
    }

    func purgeExpired() {
        let removed = index.purge(olderThanDays: AppSettings.shared.libraryRetentionDays, now: Date())
        guard !removed.isEmpty else { return }
        removed.forEach(removeFiles)
        save()
    }

    private func removeFiles(of item: CaptureItem) {
        try? FileManager.default.removeItem(at: imageURL(id: item.id))
        try? FileManager.default.removeItem(at: thumbnailURL(id: item.id))
        try? FileManager.default.removeItem(at: projectURL(id: item.id))
        thumbnails.removeObject(forKey: item.id as NSUUID)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
