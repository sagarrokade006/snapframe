import Foundation

public enum ImageFormat: String, CaseIterable, Codable, Sendable {
    case png, jpeg, heic

    public var title: String { rawValue.uppercased() }

    public var fileExtension: String {
        self == .jpeg ? "jpg" : rawValue
    }

    public var typeIdentifier: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        }
    }

    public var supportsTransparency: Bool { self != .jpeg }
    public var usesQuality: Bool { self != .png }
}

public enum AfterCapture: String, CaseIterable, Codable, Sendable {
    case saveAndCopy, save, copy, annotate

    public var title: String {
        switch self {
        case .saveAndCopy: return "Save and copy"
        case .save: return "Save to folder"
        case .copy: return "Copy to clipboard"
        case .annotate: return "Open in editor"
        }
    }

    public var shortTitle: String {
        switch self {
        case .saveAndCopy: return "Save + Copy"
        case .save: return "Save"
        case .copy: return "Copy"
        case .annotate: return "Edit"
        }
    }

    public var saves: Bool { self == .saveAndCopy || self == .save }
    public var copies: Bool { self == .saveAndCopy || self == .copy }
}
