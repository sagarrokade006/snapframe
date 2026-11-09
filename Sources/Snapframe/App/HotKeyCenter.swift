import Carbon.HIToolbox
import Combine
import Foundation
import SnapframeCore

private let hotKeySignature: OSType = 0x534E_5046  // "SNPF"

private let hotKeyHandler: EventHandlerUPP = { _, event, _ in
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == hotKeySignature else { return status }
    let index = Int(identifier.id)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotKeyCenter.shared.fire(index: index) }
    }
    return noErr
}

@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    /// Actions whose shortcut macOS refused, usually because another app already holds it.
    @Published private(set) var failed: Set<ShortcutAction> = []

    var onAction: ((ShortcutAction) -> Void)?

    private var references: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private var current: [ShortcutAction: Shortcut] = [:]

    func register(_ shortcuts: [ShortcutAction: Shortcut]) {
        current = shortcuts
        installHandlerIfNeeded()
        unregisterAll()

        var failures = Set<ShortcutAction>()
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = shortcuts[action] else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers.rawValue,
                EventHotKeyID(signature: hotKeySignature, id: UInt32(index)),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                references.append(reference)
            } else {
                failures.insert(action)
            }
        }
        failed = failures
    }

    /// Stops shortcuts firing while the user is typing a new one.
    func suspend() {
        unregisterAll()
    }

    func resume() {
        register(current)
    }

    private func unregisterAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    fileprivate func fire(index: Int) {
        guard ShortcutAction.allCases.indices.contains(index) else { return }
        onAction?(ShortcutAction.allCases[index])
    }
}
