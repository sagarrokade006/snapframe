import AppKit
import ImageIO
import SnapframeCore
import SwiftUI
import UniformTypeIdentifiers

/// Owns the single Annotate window.
@MainActor
final class AnnotateController: NSObject, NSWindowDelegate {
    static let shared = AnnotateController()

    private var window: NSWindow?
    private var session: AnnotateSession?

    func open(_ item: CaptureItem) {
        let library = CaptureLibrary.shared
        if let data = try? Data(contentsOf: library.projectURL(id: item.id)),
           let project = try? SnapframeProject.decode(data),
           let base = Self.image(from: project.basePNG) {
            present(base: base, scale: CGFloat(project.scale), document: project.document, itemID: item.id)
            return
        }
        guard let data = try? Data(contentsOf: library.imageURL(id: item.id)), let base = Self.image(from: data) else { return }
        let scale = CGFloat(max(item.scale, 1))
        let document = AnnotateDocument(
            imageSize: CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale),
            style: AppSettings.shared.defaultCanvasStyle
        )
        present(base: base, scale: scale, document: document, itemID: item.id)
    }

    /// Opens a `.snapframe` project, or brings an ordinary image into the library first.
    func open(fileURL url: URL) {
        if url.pathExtension.lowercased() == SnapframeProject.fileExtension {
            guard let data = try? Data(contentsOf: url),
                  let project = try? SnapframeProject.decode(data),
                  let base = Self.image(from: project.basePNG)
            else {
                show("This Snapframe project could not be opened.")
                return
            }
            present(base: base, scale: CGFloat(project.scale), document: project.document, itemID: nil)
            return
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            show("This image could not be opened.")
            return
        }
        Task {
            let name = url.deletingPathExtension().lastPathComponent
            if let item = await CaptureLibrary.shared.add(image: image, scale: 1, kind: "Imported", name: name, formatTitle: "PNG", savedURL: nil) {
                open(item)
            }
        }
    }

    func chooseFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, UTType(filenameExtension: SnapframeProject.fileExtension) ?? .data]
        if panel.runModal() == .OK, let url = panel.url { open(fileURL: url) }
    }

    private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func show(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }

    private func present(base: CGImage, scale: CGFloat, document: AnnotateDocument, itemID: UUID?) {
        window?.delegate = nil
        window?.close()

        let session = AnnotateSession(base: base, scale: scale, document: document, itemID: itemID)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Annotate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let host = NSHostingView(rootView: AnnotateView(session: session))
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.setContentSize(CGSize(width: 1280, height: 800))
        window.center()

        session.close = { [weak self] in self?.closeWithoutAsking() }
        self.window = window
        self.session = session

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWithoutAsking() {
        window?.delegate = nil
        window?.close()
        window = nil
        session = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session, session.isDirty else {
            closeWithoutAsking()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Keep your changes?"
        alert.informativeText = "Your markup will be lost if you discard it."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            session.finish()
        case .alertSecondButtonReturn:
            closeWithoutAsking()
        default:
            break
        }
        return false
    }
}
