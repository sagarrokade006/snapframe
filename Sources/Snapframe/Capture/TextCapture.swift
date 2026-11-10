import AppKit
import SnapframeCore
import SwiftUI
import Vision

struct RecognizedContent: Sendable {
    var fragments: [TextFragment] = []
    var codes: [String] = []
}

/// Reads text and QR codes on this Mac with Apple's Vision framework.
enum TextCapture {
    static func recognize(_ image: CGImage, detectLanguage: Bool) async -> RecognizedContent {
        await Task.detached(priority: .userInitiated) {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.automaticallyDetectsLanguage = detectLanguage
            let codeRequest = VNDetectBarcodesRequest()

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([textRequest, codeRequest])

            var result = RecognizedContent()
            for observation in textRequest.results ?? [] {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                let box = observation.boundingBox
                result.fragments.append(TextFragment(text: text, x: box.minX, y: 1 - box.maxY, height: box.height))
            }

            var seen = Set<String>()
            for observation in codeRequest.results ?? [] {
                if let payload = observation.payloadStringValue, seen.insert(payload).inserted {
                    result.codes.append(payload)
                }
            }
            return result
        }.value
    }
}

/// Shows what was recognized and keeps the clipboard in step with the line-break choice.
@MainActor
final class TextResultController {
    static let shared = TextResultController()

    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    private static let size = CGSize(width: 440, height: 320)

    func show(_ content: RecognizedContent) {
        close()
        let view = TextResultCard(
            content: content,
            close: { [weak self] in self?.close() },
            hovering: { [weak self] inside in
                if inside { self?.dismissal?.cancel() } else { self?.schedule() }
            }
        )
        let panel = KeylessPanel(size: Self.size)
        panel.level = .statusBar
        panel.contentView = FirstMouseHostingView(rootView: view)

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24))
        panel.orderFrontRegardless()
        self.panel = panel
        schedule()
    }

    private func schedule() {
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    func close() {
        dismissal?.cancel()
        panel?.close()
        panel = nil
    }
}

struct TextResultCard: View {
    let content: RecognizedContent
    let close: () -> Void
    let hovering: (Bool) -> Void

    @ObservedObject private var settings = AppSettings.shared

    private var text: String {
        TextComposer.compose(content.fragments, keepLineBreaks: settings.keepLineBreaks)
    }

    private var isEmpty: Bool { content.fragments.isEmpty && content.codes.isEmpty }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: isEmpty ? "text.magnifyingglass" : "checkmark.circle.fill")
                    .foregroundStyle(isEmpty ? Color.snapMuted : Color.snapTeal)
                Text(isEmpty ? "No text found in that area" : "Copied to clipboard").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
            }

            if !content.fragments.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: .infinity)
                .snapCard(radius: 9)
            }

            ForEach(content.codes, id: \.self) { code in
                codeRow(code)
            }

            if isEmpty {
                Text("Try selecting a larger area, or text with more contrast.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.snapMuted)
                Spacer()
            } else if !content.fragments.isEmpty {
                HStack(spacing: 16) {
                    Toggle("Keep line breaks", isOn: Binding(
                        get: { settings.keepLineBreaks },
                        set: {
                            settings.keepLineBreaks = $0
                            copy(TextComposer.compose(content.fragments, keepLineBreaks: $0))
                        }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button("Copy Again") { copy(text) }.buttonStyle(QuietButtonStyle())
                }
                .font(.system(size: 13))
            }
        }
        .padding(14)
        .frame(width: 440, height: 320)
        .background(Color.snapSidebar)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.snapLine))
        .snapWindowStyle()
        .onHover(perform: hovering)
    }

    private func codeRow(_ code: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "qrcode").font(.system(size: 18)).foregroundStyle(Color.snapAccentText)
            Text(code).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Copy") { copy(code) }.buttonStyle(QuietButtonStyle())
            if let url = CapturedLink.openableURL(code) {
                Button("Open Link") {
                    NSWorkspace.shared.open(url)
                    close()
                }
                .buttonStyle(QuietButtonStyle())
                .help(url.absoluteString)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .snapCard(radius: 9)
    }
}
