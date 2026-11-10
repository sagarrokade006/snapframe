import AppKit
import Combine
import ImageIO
import SnapframeCore
import UniformTypeIdentifiers

enum AnnotateTool: String, CaseIterable, Identifiable {
    case select, crop, arrow, line, rectangle, filled, ellipse, draw, marker, text, counter, spotlight, redact, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .crop: return "Crop"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rect"
        case .filled: return "Filled"
        case .ellipse: return "Ellipse"
        case .draw: return "Draw"
        case .marker: return "Marker"
        case .text: return "Text"
        case .counter: return "Count"
        case .spotlight: return "Spot"
        case .redact: return "Redact"
        case .image: return "Image"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .filled: return "rectangle.fill"
        case .ellipse: return "circle"
        case .draw: return "scribble"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .spotlight: return "circle.dashed"
        case .redact: return "checkerboard.rectangle"
        case .image: return "photo"
        }
    }

    var hint: String {
        switch self {
        case .select: return "Move, resize or delete any object."
        case .crop: return "Drag an area, then apply the crop."
        case .arrow: return "Drag to draw. Hold Shift to snap the angle."
        case .line: return "Drag to draw. Hold Shift to snap the angle."
        case .rectangle: return "Drag to outline. Hold Shift for a square."
        case .filled: return "Drag to cover an area with solid color."
        case .ellipse: return "Drag to circle something."
        case .draw: return "Draw freehand."
        case .marker: return "Drag across text to highlight it."
        case .text: return "Click to type. Press Return to finish."
        case .counter: return "Each click adds the next number."
        case .spotlight: return "Dims everything outside the shape."
        case .redact: return "Original pixels are removed when you save."
        case .image: return "Add a picture from a file or the clipboard."
        }
    }

    var usesColor: Bool {
        switch self {
        case .crop, .redact, .spotlight, .image: return false
        default: return true
        }
    }

    var usesLineWidth: Bool {
        switch self {
        case .select, .crop, .filled, .counter, .spotlight, .redact, .image: return false
        default: return true
        }
    }
}

@MainActor
final class AnnotateSession: ObservableObject {
    static let palette: [(name: String, hex: UInt32)] = [
        ("Orange", 0xFF6B3D), ("Yellow", 0xFFD60A), ("Teal", 0x2FB5A6),
        ("Blue", 0x3D8BFF), ("Black", 0x17181A), ("White", 0xFFFFFF),
    ]

    @Published var document: AnnotateDocument
    @Published var tool = AnnotateTool.arrow {
        didSet {
            selectionID = nil
            pendingCrop = nil
            draft = nil
        }
    }
    @Published var color: UInt32 = 0xFF6B3D {
        didSet { updateSelection { $0.color = color } }
    }
    @Published var lineWidth: CGFloat = 4 {
        didSet { updateSelection { $0.lineWidth = lineWidth } }
    }
    @Published var redactionMode = RedactionMode.secure {
        didSet {
            updateSelection { object in
                if case .redaction(let rect, _) = object.shape { object.shape = .redaction(rect, mode: redactionMode) }
            }
        }
    }
    @Published var spotlightOval = false
    @Published var selectionID: UUID?
    @Published var draft: Annotation?
    @Published var pendingCrop: CGRect?
    @Published var message: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isDirty = false

    private(set) var renderer: AnnotationRenderer
    let itemID: UUID?
    var close: () -> Void = {}

    private var history: EditHistory<AnnotateDocument>

    init(base: CGImage, scale: CGFloat, document: AnnotateDocument, itemID: UUID?) {
        renderer = AnnotationRenderer(base: base, scale: scale)
        self.document = document
        self.itemID = itemID
        history = EditHistory(document)
    }

    var selected: Annotation? {
        document.objects.first { $0.id == selectionID }
    }

    /// Call when a gesture ends, so one drag counts as one undo step.
    func commit() {
        history.record(document)
        refreshState()
    }

    private func refreshState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        isDirty = canUndo
    }

    func undo() {
        guard let state = history.undo() else { return }
        document = state
        selectionID = nil
        refreshState()
    }

    func redo() {
        guard let state = history.redo() else { return }
        document = state
        selectionID = nil
        refreshState()
    }

    private func updateSelection(_ change: (inout Annotation) -> Void) {
        guard var object = selected else { return }
        change(&object)
        document.replace(object)
        commit()
    }

    func deleteSelection() {
        guard let selectionID else { return }
        document.objects.removeAll { $0.id == selectionID }
        self.selectionID = nil
        commit()
    }

    func duplicateSelection() {
        guard let selectionID, let copy = document.duplicate(id: selectionID, offset: 14) else { return }
        self.selectionID = copy
        commit()
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        updateSelection { $0 = $0.translated(dx: dx, dy: dy) }
    }

    func applyCrop() {
        guard let pendingCrop, pendingCrop.width >= 4, pendingCrop.height >= 4 else { return }
        document.crop = pendingCrop.intersection(CGRect(origin: .zero, size: document.imageSize))
        self.pendingCrop = nil
        commit()
    }

    func resetCrop() {
        pendingCrop = nil
        document.crop = nil
        commit()
    }

    func setFill(_ fill: CanvasFill) {
        document.style.fill = fill
        commit()
    }

    func useStyleAsDefault() {
        AppSettings.shared.defaultCanvasStyle = document.style
        message = "New edits will start with this background."
    }

    // MARK: Adding pictures

    func addImageFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        add(image)
    }

    func addImageFromClipboard() {
        guard let picture = NSImage(pasteboard: .general),
              let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            message = "There's no image on the clipboard."
            return
        }
        add(image)
    }

    private func add(_ image: CGImage) {
        guard let png = try? OutputService.encode(image, format: .png, quality: 1, scale: 1) else { return }
        let visible = document.visibleRect
        var size = CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
        let fit = min(visible.width * 0.5 / size.width, visible.height * 0.5 / size.height, 1)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let rect = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        let object = Annotation(shape: .image(rect, png: png), color: color, lineWidth: lineWidth)
        document.objects.append(object)
        tool = .select
        selectionID = object.id
        commit()
    }

    // MARK: Output

    private var flatImage: CGImage? { renderer.flatten(document) }

    func copyToClipboard() {
        guard let flatImage, let png = try? OutputService.encode(flatImage, format: .png, quality: 1, scale: renderer.scale) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        message = "Copied to clipboard."
    }

    func float() {
        guard let flatImage else { return }
        PinController.shared.pin(
            image: NSImage(cgImage: flatImage, size: .zero),
            pointSize: CGSize(width: CGFloat(flatImage.width) / renderer.scale, height: CGFloat(flatImage.height) / renderer.scale)
        )
    }

    func share() {
        guard let flatImage, let png = try? OutputService.encode(flatImage, format: .png, quality: 1, scale: renderer.scale) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Snapframe \(UUID().uuidString.prefix(6)).png")
        guard (try? png.write(to: url)) != nil else { return }
        ShareSheet.show(url)
    }

    func saveAs() {
        guard let flatImage else { return }
        let settings = AppSettings.shared
        let panel = NSSavePanel()
        panel.allowedContentTypes = ImageFormat.allCases.compactMap { UTType($0.typeIdentifier) }
        panel.nameFieldStringValue = NameTemplate(pattern: settings.namePattern).render(date: Date(), mode: "Edited") + "." + settings.format.fileExtension
        panel.directoryURL = settings.exportDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format = ImageFormat.allCases.first { $0.fileExtension == url.pathExtension.lowercased() } ?? settings.format
        do {
            try OutputService.encode(flatImage, format: format, quality: settings.quality, scale: renderer.scale).write(to: url)
            message = "Saved \(url.lastPathComponent)."
        } catch {
            message = error.localizedDescription
        }
    }

    func exportProtectedPDF(password: String) {
        guard let flatImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Protected capture.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProtectedPDF.data(image: flatImage, scale: renderer.scale, password: password).write(to: url)
            message = "Saved a password-protected PDF."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Redactions become part of the image here, so a saved project can't reveal them.
    private func makeProject() -> SnapframeProject? {
        guard let burned = renderer.burningRedactions(document),
              let png = try? OutputService.encode(burned.image, format: .png, quality: 1, scale: renderer.scale)
        else { return nil }
        renderer = AnnotationRenderer(base: burned.image, scale: renderer.scale)
        document = burned.document
        selectionID = nil
        history = EditHistory(document)
        refreshState()
        return SnapframeProject(document: document, scale: Double(renderer.scale), basePNG: png)
    }

    func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SnapframeProject.fileExtension) ?? .data]
        panel.nameFieldStringValue = "Snapframe project.\(SnapframeProject.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url, let project = makeProject() else { return }
        do {
            try project.encoded().write(to: url, options: .atomic)
            message = "Project saved. Redactions are now permanent."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Stores the finished image in the library, replacing the original capture's copy.
    func finish() {
        guard let flat = flatImage, let project = makeProject(), let data = try? project.encoded() else {
            message = "The image could not be saved."
            return
        }
        let scale = renderer.scale
        let library = CaptureLibrary.shared
        Task {
            await library.storeEdit(flat, scale: scale, projectData: data, itemID: itemID)
            close()
        }
    }
}

enum ShareSheet {
    @MainActor
    static func show(_ url: URL) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let location = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [url]).show(
            relativeTo: CGRect(origin: location, size: CGSize(width: 1, height: 1)),
            of: view,
            preferredEdge: .maxY
        )
    }
}
