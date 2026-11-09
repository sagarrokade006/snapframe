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
    case saveAndCopy, save, copy

    public var title: String {
        switch self {
        case .saveAndCopy: return "Save and copy"
        case .save: return "Save to folder"
        case .copy: return "Copy to clipboard"
        }
    }

    public var saves: Bool { self != .copy }
    public var copies: Bool { self != .save }
}
